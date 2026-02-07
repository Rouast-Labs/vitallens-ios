import Foundation

/// Defines how the manager should format the output waveforms.
public enum WaveformMode: Sendable {
    /// Returns only the new data points generated since the last call.
    /// Useful for efficient real-time graphing where you append data.
    case incremental
    
    /// Returns a fixed-duration sliding window (e.g., last 10 seconds).
    /// Useful for UI components that display a rolling chart.
    case windowed(seconds: Double)
    
    /// Returns the entire accumulated history.
    /// Useful for file processing or saving results at the end of a session.
    case complete
}

/// Internal helper to manage Sum/Count aggregation for smooth stitching.
struct SignalBuffer {
    var sum: [Float] = []
    var count: [Int] = []
    
    /// Merges new data into the buffer, averaging overlapping segments.
    mutating func merge(data: [Float], overlapCount: Int) {
        let newCount = data.count
        guard newCount > 0 else { return }
        
        // 1. Handle Overlap (Average with existing data)
        // We only merge if we actually have data to merge against
        let validOverlap = min(overlapCount, sum.count, newCount)
        
        if validOverlap > 0 {
            let startIdx = sum.count - validOverlap // Backtrack from the end
            
            for i in 0..<validOverlap {
                // Determine the alignment:
                // The first element of 'data' corresponds to sum[startIdx]
                // The overlap logic assumes the input 'data' starts exactly where the buffer tail starts.
                // In standard stitching, 'overlapCount' is how many frames at the START of 'data' are repeats.
                
                // Note: The caller (Manager) calculates overlapCount based on Time.
                // data[0...overlapCount-1] are the frames to merge.
                
                sum[startIdx + i] += data[i]
                count[startIdx + i] += 1
            }
        }
        
        // 2. Handle New Data (Append)
        if newCount > validOverlap {
            let newSlice = data[validOverlap...]
            sum.append(contentsOf: newSlice)
            count.append(contentsOf: Array(repeating: 1, count: newSlice.count))
        }
    }
    
    /// Returns the averaged signal.
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
    }
}

/// Manages the stateful accumulation of vital sign waveforms and computes real-time estimates.
public actor VitalsEstimateManager {
    
    // MARK: - Configuration
    
    // Maximum history to keep internally (approx 60s @ 30fps) to support HRV calc.
    private let maxInternalHistory: Int = 1800
    private let minEstimationWindow: Int = 120
    private let minHRVWindow: Int = 600
    
    // MARK: - State Buffers
    
    // Time is the "Master Key" for alignment
    private var timestamps: [Double] = []
    
    // Signal Buffers (Data + Confidence)
    private var ppgData = SignalBuffer()
    private var ppgConf = SignalBuffer()
    private var respData = SignalBuffer()
    private var respConf = SignalBuffer()
    
    // Face Buffers (We use "First Writer Wins" logic for metadata, simpler than averaging rects)
    private var faceCoordinates: [[Double]] = []
    private var faceConfidence: [Double] = []
    
    // Incremental Mode State
    private var lastEmittedTimestamp: Double = -1.0
    
    // MARK: - Initialization
    public init() {}
    
    // MARK: - Public API
    
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
    
    /// Processes a new chunk of data, aggregating it with history and returning the result.
    public func process(
        chunk: VitalLensResult,
        mode: WaveformMode = .windowed(seconds: 10),
        config: ModelConfig?
    ) -> VitalLensResult {
        
        let fps = calculateEffectiveFPS() ?? Float(config?.fpsTarget ?? 30.0)
        
        // 1. Calculate Overlap based on Time
        // This tells us how many frames at the START of 'chunk' are historical.
        let overlapCount = mergeTimestamps(newTimes: chunk.time)
        
        // 2. Merge Signals ("Soft Stitching" / Averaging)
        if let ppg = chunk.vitalSigns.ppgWaveform {
            ppgData.merge(data: ppg.data.map { Float($0) }, overlapCount: overlapCount)
            ppgConf.merge(data: ppg.confidence.map { Float($0) }, overlapCount: overlapCount)
        }
        if let resp = chunk.vitalSigns.respiratoryWaveform {
            respData.merge(data: resp.data.map { Float($0) }, overlapCount: overlapCount)
            respConf.merge(data: resp.confidence.map { Float($0) }, overlapCount: overlapCount)
        }
        
        // 3. Merge Face Data ("Hard Stitching" / First Writer Wins)
        // We only append the NEW data (indices >= overlapCount). We do not change existing history.
        if let coords = chunk.face.coordinates, let conf = chunk.face.confidence {
            let safeOverlap = min(overlapCount, coords.count)
            if coords.count > safeOverlap {
                faceCoordinates.append(contentsOf: coords[safeOverlap...])
                faceConfidence.append(contentsOf: conf[safeOverlap...])
            }
        } else {
            // Pad if face data is missing but time advanced
            let newFrames = chunk.time.count - overlapCount
            if newFrames > 0 {
                faceCoordinates.append(contentsOf: Array(repeating: [], count: newFrames))
                faceConfidence.append(contentsOf: Array(repeating: 0.0, count: newFrames))
            }
        }
        
        // 4. Prune Internal History
        // We must keep enough data for HRV (60s), regardless of the requested output mode.
        pruneInternalState(keeping: maxInternalHistory)
        
        // 5. Estimate Vitals
        // Note: We use the full averaged internal buffer for estimation to maximize accuracy.
        let computedVitals = estimateVitals(fps: fps)
        
        // 6. Construct Output
        return constructOutput(
            originalResult: chunk,
            computedVitals: computedVitals,
            mode: mode,
            fps: Double(fps)
        )
    }
    
    // MARK: - Core Logic
    
    /// Updates `timestamps` array and returns the number of frames in `newTimes` that overlap with existing history.
    private func mergeTimestamps(newTimes: [Double]) -> Int {
        guard !newTimes.isEmpty else { return 0 }
        
        guard let lastTime = timestamps.last else {
            // First chunk ever
            timestamps = newTimes
            return 0
        }
        
        // Find where the new chunk actually provides *new* data (time > lastTime)
        if let firstNewIndex = newTimes.firstIndex(where: { $0 > lastTime }) {
            let overlapCount = firstNewIndex
            let newSlice = newTimes[firstNewIndex...]
            timestamps.append(contentsOf: newSlice)
            return overlapCount
        } else {
            // Corner Case: All new times are older or equal to lastTime?
            // This implies the entire chunk is "Overlap".
            return newTimes.count
        }
    }
    
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
    
    private func calculateEffectiveFPS() -> Float? {
        guard timestamps.count >= 2 else { return nil }
        // Use last ~2 seconds for FPS calculation to be responsive to drifts
        let window = min(timestamps.count, 60)
        let slice = timestamps.suffix(window)
        guard let first = slice.first, let last = slice.last, last > first else { return nil }
        let duration = last - first
        let frames = Double(slice.count - 1)
        return Float(frames / duration)
    }
    
    // MARK: - Estimation
    
    private func estimateVitals(fps: Float) -> VitalSigns {
        // 1. Get Averaged Signals
        let currentPPG = ppgData.computeAverage()
        let currentResp = respData.computeAverage()
        
        // 2. Prepare Metrics
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
    
    private func averageConfidence(_ confs: [Float]) -> Float {
        guard !confs.isEmpty else { return 0 }
        return confs.reduce(0, +) / Float(confs.count)
    }
    
    // MARK: - Output Construction
    
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
        // If startIndex >= totalFrames, we return empty arrays (common in incremental mode if no new frames)
        let sliceRange = startIndex..<totalFrames
        let sliceTime = Array(timestamps[sliceRange])
        
        // Get aggregated signals
        let fullPPG = ppgData.computeAverage()
        let fullResp = respData.computeAverage()
        let fullPPGConf = ppgConf.computeAverage()
        let fullRespConf = respConf.computeAverage()
        
        // Helper: Safely slice an array using the start index, capped by the array's own count and totalFrames.
        // This prevents crashes if one signal (e.g. Resp) is empty or shorter than another (e.g. PPG).
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
        
        // Helper: Safely slice Face Coordinates
        func safeSliceCoords(_ array: [[Double]]) -> [[Double]] {
            guard startIndex < array.count else { return [] }
            let end = min(array.count, totalFrames)
            guard startIndex < end else { return [] }
            return Array(array[startIndex..<end])
        }
        
        // Helper: Safely slice Face Confidence
        func safeSliceFaceConf(_ array: [Double]) -> [Double] {
            guard startIndex < array.count else { return [] }
            let end = min(array.count, totalFrames)
            guard startIndex < end else { return [] }
            return Array(array[startIndex..<end])
        }
        
        let sliceFaceCoords = safeSliceCoords(faceCoordinates)
        let sliceFaceConf = safeSliceFaceConf(faceConfidence)
        
        // 3. Assemble Vitals
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