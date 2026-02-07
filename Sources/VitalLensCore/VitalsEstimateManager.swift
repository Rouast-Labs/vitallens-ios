import Foundation

/// Defines how the manager should format the output waveforms.
public enum WaveformMode: Sendable {
    /// Returns only the new data points generated since the last call.
    case incremental
    /// Returns a fixed-duration sliding window (e.g., last 10 seconds).
    case windowed(seconds: Double)
    /// Returns the entire accumulated history of the session.
    case complete
}

/// Internal helper to manage Sum/Count aggregation for seamless signal stitching.
struct SignalBuffer {
    var sum: [Float] = []
    var count: [Int] = []
    var unit: String?
    
    mutating func merge(data: [Float], overlapCount: Int, unit: String?) {
        if self.unit == nil { self.unit = unit }
        
        let newCount = data.count
        guard newCount > 0 else { return }
        
        // Handle overlap averaging
        let validOverlap = min(overlapCount, sum.count, newCount)
        if validOverlap > 0 {
            let startIdx = sum.count - validOverlap
            for i in 0..<validOverlap {
                let newVal = data[i]
                if !newVal.isNaN {
                    sum[startIdx + i] += newVal
                    count[startIdx + i] += 1
                }
            }
        }
        
        // Append new data
        if newCount > validOverlap {
            let newSlice = data[validOverlap...]
            let safeSlice = newSlice.map { $0.isNaN ? 0.0 : $0 }
            sum.append(contentsOf: safeSlice)
            count.append(contentsOf: Array(repeating: 1, count: newSlice.count))
        }
    }
    
    func computeAverage() -> [Float] {
        return zip(sum, count).map { $0 / Float($1) }
    }
    
    mutating func prune(keepingLast countToKeep: Int) {
        if sum.count > countToKeep {
            let removeCount = sum.count - countToKeep
            sum.removeFirst(removeCount)
            count.removeFirst(removeCount)
        }
    }
    
    mutating func removeAll() {
        sum.removeAll()
        count.removeAll()
        unit = nil
    }
}

/// Manages the stateful accumulation of vital sign waveforms and computes real-time estimates.
public actor VitalsEstimateManager {
    
    // MARK: - Configuration
    
    /// Maximum history to keep internally (approx 60s @ 30fps).
    private let maxInternalHistory: Int = 1800
    
    /// Minimum samples required to attempt frequency estimation (~4 seconds).
    private let minEstimationWindow: Int = 120
    
    /// Minimum samples required to attempt HRV estimation (~20 seconds).
    private let minHRVWindow: Int = 600
    
    // MARK: - State
    
    /// The "Master Clock" for alignment. Stores the timestamp of each frame.
    private var timestamps: [Double] = []
    
    /// Dynamic storage for all signal buffers. Key is the signal ID (e.g., "ppg_waveform", "sbp").
    private var signalBuffers: [String: SignalBuffer] = [:]
    private var signalConfidences: [String: SignalBuffer] = [:]
    
    /// Face data tracking
    private var faceCoordinates: [[Double]] = []
    private var faceConfidence: [Double] = []
    private var faceNote: String?
    
    /// Tracks the last timestamp emitted in `incremental` mode.
    private var lastEmittedTimestamp: Double = -1.0
    
    public init() {}
    
    public func reset() {
        timestamps.removeAll()
        signalBuffers.removeAll()
        signalConfidences.removeAll()
        faceCoordinates.removeAll()
        faceConfidence.removeAll()
        faceNote = nil
        lastEmittedTimestamp = -1.0
    }
    
    /// Processes a new chunk of data, aggregating it with history and deriving new vitals.
    public func process(
        chunk: VitalLensResult,
        mode: WaveformMode = .windowed(seconds: 10),
        config: ModelConfig?
    ) -> VitalLensResult {
        
        // 1. Merge Time & Calculate Overlap
        let overlapCount = mergeTimestamps(newTimes: chunk.time)
        
        // 2. Merge Face Data
        if let coords = chunk.face.coordinates, let conf = chunk.face.confidence {
            faceNote = chunk.face.note
            let safeOverlap = min(overlapCount, coords.count)
            if coords.count > safeOverlap {
                faceCoordinates.append(contentsOf: coords[safeOverlap...])
                faceConfidence.append(contentsOf: conf[safeOverlap...])
            }
        } else {
            // Pad if missing (e.g. pure signal model)
            let newFrames = chunk.time.count - overlapCount
            if newFrames > 0 {
                faceCoordinates.append(contentsOf: Array(repeating: [], count: newFrames))
                faceConfidence.append(contentsOf: Array(repeating: 0.0, count: newFrames))
            }
        }
        
        // 3. Merge All Signals (Dynamic)
        for (key, series) in chunk.signals {
            // Ensure buffers exist
            if signalBuffers[key] == nil {
                signalBuffers[key] = SignalBuffer()
                signalConfidences[key] = SignalBuffer()
            }
            
            // Merge Data
            signalBuffers[key]?.merge(data: series.data, overlapCount: overlapCount, unit: series.unit)
            
            // Merge Confidence
            signalConfidences[key]?.merge(data: series.confidence, overlapCount: overlapCount, unit: nil)
        }
        
        // 4. Prune History
        pruneInternalState(keeping: maxInternalHistory)
        
        // 5. Calculate FPS
        let fps = calculateEffectiveFPS() ?? Float(config?.fpsTarget ?? 30.0)
        
        // 6. Derive Vitals (Logic Engine)
        let derivedSignals = performDerivations(fps: fps)
        
        // 7. Construct Final Output
        return constructOutput(
            originalResult: chunk,
            derivedSignals: derivedSignals,
            mode: mode,
            fps: Double(fps)
        )
    }
    
    // MARK: - Derivation Logic
    
    private func performDerivations(fps: Float) -> [String: TimeSeries] {
        var results = [String: TimeSeries]()
        
        // We iterate through our buffers to see what source data we have
        for (key, buffer) in signalBuffers {
            let meta = VitalRegistry.shared.getMeta(for: key)
            let data = buffer.computeAverage()
            let conf = signalConfidences[key]?.computeAverage() ?? Array(repeating: 1.0, count: data.count)
            
            // 1. Always include the source waveform in the output
            results[key] = TimeSeries(data: data, confidence: conf, unit: buffer.unit ?? meta.unit, note: nil)
            
            // 2. Perform Derivation based on Registry
            switch meta.derivation {
                
            case .rateFromFFT:
                // e.g. ppg_waveform -> heart_rate
                // e.g. respiratory_waveform -> respiratory_rate
                
                if data.count >= minEstimationWindow,
                   let bounds = meta.frequencyBounds,
                   let rate = SignalOps.estimateRate(from: SignalOps.standardize(SignalOps.detrend(data, fs: fps)),
                                                     fs: fps,
                                                     minRate: Float(bounds.lowerBound),
                                                     maxRate: Float(bounds.upperBound)) {
                    
                    let targetKey = key == "ppg_waveform" ? "heart_rate" : "respiratory_rate"
                    let targetMeta = VitalRegistry.shared.getMeta(for: targetKey)
                    let scalarConf = averageConfidence(conf)
                    
                    results[targetKey] = createScalarTimeSeries(value: rate, conf: scalarConf, count: data.count, unit: targetMeta.unit)
                    
                    // Special Case: HRV (only if source was PPG)
                    if key == "ppg_waveform" && data.count >= minHRVWindow {
                        calculateHRV(ppg: data, fps: fps, hr: rate, conf: scalarConf, count: data.count, into: &results)
                    }
                }
                
            case .average:
                // e.g. sbp array -> sbp scalar (averaged over window)
                if !data.isEmpty {
                    let meanVal = data.reduce(0, +) / Float(data.count)
                    let meanConf = averageConfidence(conf)
                    
                    // We overwrite the raw array with a "constant" array of the mean value.
                    // This allows the UI to simply grab .latest.value and get the stable average,
                    // while maintaining the TimeSeries contract.
                    results[key] = createScalarTimeSeries(
                        value: meanVal,
                        conf: meanConf,
                        count: data.count,
                        unit: buffer.unit ?? meta.unit
                    )
                }
                
            case .latest, .none, .hrvStatistics:
                break // Already handled or pass-through
            }
        }
        
        return results
    }
    
    private func calculateHRV(ppg: [Float], fps: Float, hr: Float, conf: Float, count: Int, into results: inout [String: TimeSeries]) {
        let clean = SignalOps.standardize(SignalOps.detrend(ppg, fs: fps))
        let peaks = SignalOps.findPeaks(in: clean, fs: fps, hr: hr)
        
        if let sdnn = SignalOps.calculateSDNN(peaks: peaks, fs: fps) {
            let meta = VitalRegistry.shared.getMeta(for: "hrv_sdnn")
            results["hrv_sdnn"] = createScalarTimeSeries(value: Float(sdnn), conf: conf, count: count, unit: meta.unit)
        }
        
        if let rmssd = SignalOps.calculateRMSSD(peaks: peaks, fs: fps) {
            let meta = VitalRegistry.shared.getMeta(for: "hrv_rmssd")
            results["hrv_rmssd"] = createScalarTimeSeries(value: Float(rmssd), conf: conf, count: count, unit: meta.unit)
        }
    }
    
    // Helper to create a TimeSeries that represents a single scalar value repeated across the timeline
    // This maintains the "Everything is an array" contract while providing a value for every frame.
    private func createScalarTimeSeries(value: Float, conf: Float, count: Int, unit: String) -> TimeSeries {
        return TimeSeries(
            data: Array(repeating: value, count: count),
            confidence: Array(repeating: conf, count: count),
            unit: unit,
            note: "Derived locally"
        )
    }
    
    // MARK: - Helpers
    
    private func mergeTimestamps(newTimes: [Double]) -> Int {
        guard !newTimes.isEmpty else { return 0 }
        guard let lastTime = timestamps.last else {
            timestamps = newTimes
            return 0
        }
        
        let epsilon = 0.005
        if let firstNewIndex = newTimes.firstIndex(where: { $0 > (lastTime + epsilon) }) {
            let overlapCount = firstNewIndex
            let newSlice = newTimes[firstNewIndex...]
            timestamps.append(contentsOf: newSlice)
            return overlapCount
        } else {
            return newTimes.count
        }
    }
    
    private func pruneInternalState(keeping count: Int) {
        if timestamps.count > count {
            let removeCount = timestamps.count - count
            timestamps.removeFirst(removeCount)
            
            // Prune all dynamic buffers
            for key in signalBuffers.keys {
                signalBuffers[key]?.prune(keepingLast: count)
                signalConfidences[key]?.prune(keepingLast: count)
            }
            
            if faceCoordinates.count > count {
                faceCoordinates.removeFirst(faceCoordinates.count - count)
                faceConfidence.removeFirst(faceConfidence.count - count)
            }
        }
    }
    
    private func calculateEffectiveFPS() -> Float? {
        guard timestamps.count >= 2 else { return nil }
        let window = min(timestamps.count, 60)
        let slice = timestamps.suffix(window)
        guard let first = slice.first, let last = slice.last, last > first else { return nil }
        let duration = last - first
        let frames = Double(slice.count - 1)
        return Float(frames / duration)
    }
    
    private func averageConfidence(_ confs: [Float]) -> Float {
        guard !confs.isEmpty else { return 0 }
        return confs.reduce(0, +) / Float(confs.count)
    }
    
    // MARK: - Output Construction
    
    private func constructOutput(
        originalResult: VitalLensResult,
        derivedSignals: [String: TimeSeries],
        mode: WaveformMode,
        fps: Double
    ) -> VitalLensResult {
        
        let totalFrames = timestamps.count
        var startIndex: Int = 0
        
        // Calculate Slicing Index
        switch mode {
        case .complete:
            startIndex = 0
        case .windowed(let seconds):
            let windowFrames = Int(seconds * fps)
            startIndex = max(0, totalFrames - windowFrames)
        case .incremental:
            if let idx = timestamps.firstIndex(where: { $0 > lastEmittedTimestamp }) {
                startIndex = idx
            } else {
                startIndex = totalFrames
            }
            if let last = timestamps.last {
                lastEmittedTimestamp = last
            }
        }
        
        // Helper Slicers
        func sliceDouble(_ array: [Double]) -> [Double] {
            guard startIndex < array.count else { return [] }
            return Array(array[startIndex...])
        }
        
        func sliceFloat(_ array: [Float]) -> [Float] {
            guard startIndex < array.count else { return [] }
            return Array(array[startIndex...])
        }
        
        func sliceCoords(_ array: [[Double]]) -> [[Double]] {
            guard startIndex < array.count else { return [] }
            return Array(array[startIndex...])
        }
        
        // Slice Metadata
        let sliceTime = sliceDouble(timestamps)
        let sliceFaceCoords = sliceCoords(faceCoordinates)
        let sliceFaceConf = sliceDouble(faceConfidence)
        
        // Slice Signals
        var finalSignals = [String: TimeSeries]()
        
        for (key, series) in derivedSignals {
            let slicedData = sliceFloat(series.data)
            let slicedConf = sliceFloat(series.confidence)
            
            if !slicedData.isEmpty {
                finalSignals[key] = TimeSeries(
                    data: slicedData,
                    confidence: slicedConf,
                    unit: series.unit,
                    note: series.note
                )
            }
        }
        
        return VitalLensResult(
            face: FaceData(coordinates: sliceFaceCoords, confidence: sliceFaceConf, note: faceNote),
            signals: finalSignals,
            time: sliceTime,
            fps: fps,
            modelUsed: originalResult.modelUsed,
            state: originalResult.state,
            message: originalResult.message
        )
    }
}