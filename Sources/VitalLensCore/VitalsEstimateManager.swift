import Foundation

/// Defines how the manager should format the output waveforms.
public enum WaveformMode: Sendable {
    /// Returns only the new data points generated since the last call.
    ///
    /// Ideal for highly efficient, append-only real-time graphing where you maintain your own history buffer.
    case incremental
    
    /// Returns a fixed-duration sliding window (e.g., last 10 seconds).
    ///
    /// Ideal for UI components that simply render whatever data array they are given (e.g., a rolling chart).
    case windowed(seconds: Double)
    
    /// Returns the entire accumulated history of the session.
    ///
    /// Ideal for file processing or saving comprehensive results at the end of a measurement session.
    case complete
}

/// Internal helper to manage Sum/Count aggregation for seamless signal stitching.
///
/// This buffer averages overlapping segments of data (e.g., when the API returns updated estimates for recent frames)
/// to reduce jitter and discontinuities at chunk boundaries.
struct SignalBuffer {
    var sum: [Float] = []
    var count: [Int] = []
    
    /// Merges new data into the buffer, averaging overlapping segments.
    ///
    /// - Parameters:
    ///   - data: The new signal data to merge.
    ///   - overlapCount: The number of frames at the start of `data` that overlap with the tail of the existing buffer.
    mutating func merge(data: [Float], overlapCount: Int) {
        let newCount = data.count
        guard newCount > 0 else { return }
        
        // 1. Handle Overlap (Average with existing data)
        let validOverlap = min(overlapCount, sum.count, newCount)
        
        if validOverlap > 0 {
            let startIdx = sum.count - validOverlap
            
            for i in 0..<validOverlap {
                let newVal = data[i]
                // Ignore NaNs to prevent corrupting the valid history
                if !newVal.isNaN {
                    sum[startIdx + i] += newVal
                    count[startIdx + i] += 1
                }
            }
        }
        
        // 2. Handle New Data (Append)
        if newCount > validOverlap {
            let newSlice = data[validOverlap...]
            
            // Treat NaN as 0.0 for sum, but count it to maintain array alignment.
            // Downstream processing (SignalOps) handles flatlines/zeros robustly.
            let safeSlice = newSlice.map { $0.isNaN ? 0.0 : $0 }
            
            sum.append(contentsOf: safeSlice)
            count.append(contentsOf: Array(repeating: 1, count: newSlice.count))
        }
    }
    
    /// Computes the final averaged signal.
    ///
    /// - Returns: An array of floats where each value is `sum / count`.
    func computeAverage() -> [Float] {
        return zip(sum, count).map { $0 / Float($1) }
    }
    
    /// Removes the oldest data points to maintain a fixed buffer size.
    ///
    /// - Parameter countToKeep: The maximum number of recent frames to retain.
    mutating func prune(keepingLast countToKeep: Int) {
        if sum.count > countToKeep {
            let removeCount = sum.count - countToKeep
            sum.removeFirst(removeCount)
            count.removeFirst(removeCount)
        }
    }
    
    /// Clears all data.
    mutating func removeAll() {
        sum.removeAll()
        count.removeAll()
    }
}

/// Manages the stateful accumulation of vital sign waveforms and computes real-time estimates.
///
/// This actor is the "brain" of the client-side processing pipeline. It:
/// 1. Stitches incoming API result chunks into a continuous timeline.
/// 2. Handles overlap averaging to smooth out transitions.
/// 3. Computes real-time vitals (HR, RR, HRV) locally using `SignalOps`.
/// 4. Formats the output based on the requested `WaveformMode`.
public actor VitalsEstimateManager {
    
    // MARK: - Configuration
    
    /// Maximum history to keep internally (approx 60s @ 30fps).
    /// Required to support long-window metrics like HRV (SDNN).
    private let maxInternalHistory: Int = 1800
    
    /// Minimum samples required to attempt Heart Rate estimation (~4 seconds).
    private let minEstimationWindow: Int = 120
    
    /// Minimum samples required to attempt HRV estimation (~20 seconds).
    private let minHRVWindow: Int = 600
    
    // MARK: - State Buffers
    
    /// The "Master Clock" for alignment. Stores the timestamp of each frame.
    private var timestamps: [Double] = []
    
    // Signal Buffers (Data + Confidence)
    private var ppgData = SignalBuffer()
    private var ppgConf = SignalBuffer()
    private var respData = SignalBuffer()
    private var respConf = SignalBuffer()
    
    // Face Buffers (Simple append strategy; first valid detection wins for a given timestamp)
    private var faceCoordinates: [[Double]] = []
    private var faceConfidence: [Double] = []
    
    /// Tracks the last timestamp emitted in `incremental` mode.
    private var lastEmittedTimestamp: Double = -1.0
    
    // MARK: - Initialization
    public init() {}
    
    // MARK: - Public API
    
    /// Resets all internal state and history.
    public func reset() {
        timestamps.removeAll()
        ppgData.removeAll()
        ppgConf.removeAll()
        respData.removeAll()
        respConf.removeAll()
        faceCoordinates.removeAll()
        faceConfidence.removeAll()
        lastEmittedTimestamp = -1.0
    }
    
    /// Processes a new chunk of data from the API, aggregating it with history and returning the refined result.
    ///
    /// - Parameters:
    ///   - chunk: The raw result chunk from the API.
    ///   - mode: The desired output format for waveforms.
    ///   - config: The model configuration (used for FPS fallback).
    /// - Returns: A `VitalLensResult` containing the stitched waveforms and locally computed vital signs.
    public func process(
        chunk: VitalLensResult,
        mode: WaveformMode = .windowed(seconds: 10),
        config: ModelConfig?
    ) -> VitalLensResult {
        
        // 1. Calculate Overlap based on Time
        let overlapCount = mergeTimestamps(newTimes: chunk.time)
        
        // 2. Merge Signals ("Soft Stitching")
        if let ppg = chunk.vitalSigns.ppgWaveform {
            ppgData.merge(data: ppg.data.map { Float($0) }, overlapCount: overlapCount)
            ppgConf.merge(data: ppg.confidence.map { Float($0) }, overlapCount: overlapCount)
        }
        if let resp = chunk.vitalSigns.respiratoryWaveform {
            respData.merge(data: resp.data.map { Float($0) }, overlapCount: overlapCount)
            respConf.merge(data: resp.confidence.map { Float($0) }, overlapCount: overlapCount)
        }
        
        // 3. Merge Face Data
        if let coords = chunk.face.coordinates, let conf = chunk.face.confidence {
            let safeOverlap = min(overlapCount, coords.count)
            if coords.count > safeOverlap {
                faceCoordinates.append(contentsOf: coords[safeOverlap...])
                faceConfidence.append(contentsOf: conf[safeOverlap...])
            }
        } else {
            // Pad if face data is missing but signal data exists (e.g., lost tracking)
            let newFrames = chunk.time.count - overlapCount
            if newFrames > 0 {
                faceCoordinates.append(contentsOf: Array(repeating: [], count: newFrames))
                faceConfidence.append(contentsOf: Array(repeating: 0.0, count: newFrames))
            }
        }
        
        // 4. Prune Internal History
        pruneInternalState(keeping: maxInternalHistory)
        
        // 5. Calculate Effective FPS
        // Must happen AFTER merge/prune to accurately reflect the current data window.
        let fps = calculateEffectiveFPS() ?? Float(config?.fpsTarget ?? 30.0)
        
        // 6. Estimate Vitals
        let computedVitals = estimateVitals(fps: fps)
        
        // 7. Construct Output
        return constructOutput(
            originalResult: chunk,
            computedVitals: computedVitals,
            mode: mode,
            fps: Double(fps)
        )
    }
    
    // MARK: - Core Logic
    
    /// Updates `timestamps` array and returns the number of frames in `newTimes` that overlap with existing history.
    ///
    /// - Parameter newTimes: The array of timestamps from the new API chunk.
    /// - Returns: The number of frames at the start of `newTimes` that are already present in the history.
    private func mergeTimestamps(newTimes: [Double]) -> Int {
        guard !newTimes.isEmpty else { return 0 }
        
        guard let lastTime = timestamps.last else {
            timestamps = newTimes
            return 0
        }
        
        // Use an epsilon to prevent float equality issues (e.g. 1.0000001 vs 1.0)
        // 0.005 is safe for FPS up to ~200 (frame time 0.005s)
        let epsilon = 0.005
        
        if let firstNewIndex = newTimes.firstIndex(where: { $0 > (lastTime + epsilon) }) {
            let overlapCount = firstNewIndex
            let newSlice = newTimes[firstNewIndex...]
            timestamps.append(contentsOf: newSlice)
            return overlapCount
        } else {
            // If all new times are effectively <= lastTime, it's all overlap
            return newTimes.count
        }
    }
    
    /// Removes the oldest frames from all internal buffers to enforce the memory limit.
    ///
    /// - Parameter count: The maximum number of frames to retain.
    private func pruneInternalState(keeping count: Int) {
        if timestamps.count > count {
            let removeCount = timestamps.count - count
            timestamps.removeFirst(removeCount)
            ppgData.prune(keepingLast: count)
            ppgConf.prune(keepingLast: count)
            respData.prune(keepingLast: count)
            respConf.prune(keepingLast: count)
            
            if faceCoordinates.count > count {
                faceCoordinates.removeFirst(faceCoordinates.count - count)
                faceConfidence.removeFirst(faceConfidence.count - count)
            }
        }
    }
    
    /// Calculates the effective frame rate based on the timestamps in the current history window.
    ///
    /// - Returns: The calculated FPS, or `nil` if insufficient history is available.
    private func calculateEffectiveFPS() -> Float? {
        guard timestamps.count >= 2 else { return nil }
        // Use last ~2 seconds (60 frames) for FPS calculation to be responsive to recent drifts
        let window = min(timestamps.count, 60)
        let slice = timestamps.suffix(window)
        guard let first = slice.first, let last = slice.last, last > first else { return nil }
        let duration = last - first
        let frames = Double(slice.count - 1)
        return Float(frames / duration)
    }
    
    // MARK: - Estimation
    
    /// Computes vital signs from the current internal signal history.
    ///
    /// - Parameter fps: The sampling frequency to use for FFT and time-domain calculations.
    /// - Returns: A `VitalSigns` struct containing the computed metrics.
    private func estimateVitals(fps: Float) -> VitalSigns {
        let currentPPG = ppgData.computeAverage()
        let currentResp = respData.computeAverage()
        
        var hrMetric: ScalarMetric?
        var rrMetric: ScalarMetric?
        var sdnnMetric: ScalarMetric?
        var rmssdMetric: ScalarMetric?
        
        // --- Heart Rate ---
        if currentPPG.count >= minEstimationWindow {
            let clean = SignalOps.detrend(currentPPG, fs: fps)
            let std = SignalOps.standardize(clean)
            
            if let hr = SignalOps.estimateRate(from: std, fs: fps, minRate: 40, maxRate: 240) {
                let conf = averageConfidence(ppgConf.computeAverage())
                hrMetric = ScalarMetric(value: Double(hr), unit: "bpm", confidence: Double(conf), note: nil)
                
                // --- HRV ---
                if currentPPG.count >= minHRVWindow {
                    let peaks = SignalOps.findPeaks(in: std, fs: fps, hr: hr)
                    if let sdnn = SignalOps.calculateSDNN(peaks: peaks, fs: fps) {
                        sdnnMetric = ScalarMetric(value: sdnn, unit: "ms", confidence: Double(conf), note: nil)
                    }
                    if let rmssd = SignalOps.calculateRMSSD(peaks: peaks, fs: fps) {
                        rmssdMetric = ScalarMetric(value: rmssd, unit: "ms", confidence: Double(conf), note: nil)
                    }
                }
            }
        }
        
        // --- Respiratory Rate ---
        if currentResp.count >= minEstimationWindow {
            let clean = SignalOps.detrend(currentResp, fs: fps, cutoff: 0.1)
            let std = SignalOps.standardize(clean)
            
            if let rr = SignalOps.estimateRate(from: std, fs: fps, minRate: 6, maxRate: 60) {
                let conf = averageConfidence(respConf.computeAverage())
                rrMetric = ScalarMetric(value: Double(rr), unit: "rpm", confidence: Double(conf), note: nil)
            }
        }
        
        // Note: Waveforms are filled in `constructOutput`, not here.
        return VitalSigns(
            heartRate: hrMetric,
            respiratoryRate: rrMetric,
            hrvSdnn: sdnnMetric,
            hrvRmssd: rmssdMetric,
            hrvLfhf: nil,
            ppgWaveform: nil,
            respiratoryWaveform: nil
        )
    }
    
    /// Computes the arithmetic mean of a confidence array.
    ///
    /// - Parameter confs: An array of confidence scores.
    /// - Returns: The average confidence (0.0 if empty).
    private func averageConfidence(_ confs: [Float]) -> Float {
        guard !confs.isEmpty else { return 0 }
        return confs.reduce(0, +) / Float(confs.count)
    }
    
    // MARK: - Output Construction
    
    /// Builds the final `VitalLensResult` by slicing the internal buffers according to the requested mode.
    ///
    /// - Parameters:
    ///   - originalResult: The result received from the API (used for metadata).
    ///   - computedVitals: The vital signs calculated locally.
    ///   - mode: The waveform output mode requested by the caller.
    ///   - fps: The effective FPS used for calculations.
    /// - Returns: The fully assembled result object.
    private func constructOutput(
        originalResult: VitalLensResult,
        computedVitals: VitalSigns,
        mode: WaveformMode,
        fps: Double
    ) -> VitalLensResult {
        
        // 1. Determine Output Range based on Mode
        let totalFrames = timestamps.count
        var startIndex: Int = 0
        
        switch mode {
        case .complete:
            startIndex = 0
            
        case .windowed(let seconds):
            let windowFrames = Int(seconds * fps)
            startIndex = max(0, totalFrames - windowFrames)
            
        case .incremental:
            // Find the first index where timestamp > lastEmitted
            if let idx = timestamps.firstIndex(where: { $0 > lastEmittedTimestamp }) {
                startIndex = idx
            } else {
                startIndex = totalFrames // No new data
            }
            // Update cursor
            if let last = timestamps.last {
                lastEmittedTimestamp = last
            }
        }
        
        // 2. Slice Data
        let sliceRange = startIndex..<totalFrames
        let sliceTime = Array(timestamps[sliceRange])
        
        // Get aggregated signals
        let fullPPG = ppgData.computeAverage()
        let fullResp = respData.computeAverage()
        let fullPPGConf = ppgConf.computeAverage()
        let fullRespConf = respConf.computeAverage()
        
        func safeSlice(_ array: [Float]) -> [Double] {
            guard startIndex < array.count else { return [] }
            let end = min(array.count, totalFrames)
            guard startIndex < end else { return [] }
            return array[startIndex..<end].map { Double($0) }
        }
        
        let slicePPGData = safeSlice(fullPPG)
        let slicePPGConf = safeSlice(fullPPGConf)
        let sliceRespData = safeSlice(fullResp)
        let sliceRespConf = safeSlice(fullRespConf)
        
        func safeSliceCoords(_ array: [[Double]]) -> [[Double]] {
            guard startIndex < array.count else { return [] }
            let end = min(array.count, totalFrames)
            guard startIndex < end else { return [] }
            return Array(array[startIndex..<end])
        }
        
        func safeSliceFaceConf(_ array: [Double]) -> [Double] {
            guard startIndex < array.count else { return [] }
            let end = min(array.count, totalFrames)
            guard startIndex < end else { return [] }
            return Array(array[startIndex..<end])
        }
        
        let sliceFaceCoords = safeSliceCoords(faceCoordinates)
        let sliceFaceConf = safeSliceFaceConf(faceConfidence)
        
        // 3. Assemble Final Result
        let finalPPG = WaveformMetric(
            data: slicePPGData,
            unit: "unitless",
            confidence: slicePPGConf,
            note: originalResult.vitalSigns.ppgWaveform?.note
        )
        
        let finalResp = WaveformMetric(
            data: sliceRespData,
            unit: "unitless",
            confidence: sliceRespConf,
            note: originalResult.vitalSigns.respiratoryWaveform?.note
        )
        
        let finalVitals = VitalSigns(
            heartRate: computedVitals.heartRate,
            respiratoryRate: computedVitals.respiratoryRate,
            hrvSdnn: computedVitals.hrvSdnn,
            hrvRmssd: computedVitals.hrvRmssd,
            hrvLfhf: computedVitals.hrvLfhf,
            ppgWaveform: finalPPG,
            respiratoryWaveform: finalResp
        )
        
        let finalFace = FaceData(
            coordinates: sliceFaceCoords,
            confidence: sliceFaceConf,
            note: originalResult.face.note
        )
        
        return VitalLensResult(
            face: finalFace,
            vitalSigns: finalVitals,
            time: sliceTime,
            displayTime: originalResult.displayTime,
            fps: fps,
            estFps: originalResult.estFps,
            modelUsed: originalResult.modelUsed,
            state: originalResult.state,
            message: originalResult.message
        )
    }
}