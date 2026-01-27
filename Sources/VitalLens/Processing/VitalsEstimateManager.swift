import Foundation

/// Manages the stateful accumulation of vital sign waveforms and computes real-time estimates.
///
/// This actor acts as the "State Machine" for the library:
/// 1. It receives chunked results from the API.
/// 2. It stitches them into a continuous history buffer (handling overlaps).
/// 3. It uses `SignalOps` to compute physiological metrics (HR, RR, HRV) on the aggregated window.
actor VitalsEstimateManager {

  // MARK: - Configuration

  /// Maximum history to keep (in frames).
  /// ~60 seconds at 30fps = 1800 frames.
  private let maxHistoryLength: Int = 1800

  /// Minimum frames required to start producing HR/RR estimates.
  /// ~4 seconds at 30fps.
  private let minEstimationWindow: Int = 120

  /// Minimum frames required to start producing HRV estimates.
  /// ~20 seconds at 30fps.
  private let minHRVWindow: Int = 600

  // MARK: - State Buffers

  // We store raw data arrays.
  private var timestamps: [Double] = []
  private var ppgData: [Float] = []
  private var ppgConfidence: [Float] = []
  private var respData: [Float] = []
  private var respConfidence: [Float] = []

  // Last calculated values (for smoothing or fallback)
  private var lastHR: Double?
  private var lastRR: Double?

  // MARK: - Initialization

  init() {}

  // MARK: - Public API

  /// Resets all buffers and state. Call this when the stream stops or restarts.
  func reset() {
      timestamps.removeAll()
      ppgData.removeAll()
      ppgConfidence.removeAll()
      respData.removeAll()
      respConfidence.removeAll()
      lastHR = nil
      lastRR = nil
  }

  /// Processes a new chunk of data from the API, updates history, and returns a refined result.
  ///
  /// - Parameters:
  ///   - result: The raw result chunk from the API.
  ///   - config: The model configuration (used for FPS).
  /// - Returns: A new `VitalLensResult` containing the aggregated estimates.
  func process(chunk: VitalLensResult, config: ModelConfig?) -> VitalLensResult {
      // 1. Stitch Data (Handle Overlaps)
      stitchBuffers(from: chunk)
      
      // 2. Prune Old Data (Sliding Window)
      pruneBuffers()
      
      // 3. Estimate Vitals (Run Math)
      let computedVitals = estimateVitals(config: config)
      
      // 4. Return Merged Result
      // We return the *incoming* face/time data (incremental) but the *computed* vital signs (windowed).
      return VitalLensResult(
          face: chunk.face,
          vitalSigns: computedVitals,
          time: chunk.time,
          displayTime: chunk.displayTime,
          fps: chunk.fps,
          estFps: chunk.estFps,
          modelUsed: chunk.modelUsed,
          state: chunk.state,
          message: chunk.message
      )
  }

  // MARK: - Buffer Management

  /// Appends new data to the buffers, ignoring overlapping timestamps.
  private func stitchBuffers(from chunk: VitalLensResult) {
      guard let chunkTimes = chunk.time as? [Double], !chunkTimes.isEmpty else { return }
      
      // Find the index in the NEW chunk where data becomes "new" (time > last buffer time)
      // This is a simplified stitching strategy: We trust the timestamp monotonicity.
      var startIndex = 0
      if let lastBufferTime = timestamps.last {
          // Find the first index in the new chunk that is strictly greater than our last stored time
          if let firstNewIndex = chunkTimes.firstIndex(where: { $0 > lastBufferTime }) {
              startIndex = firstNewIndex
          } else {
              // All new times are old? Ignore this chunk entirely.
              return
          }
      }
      
      // Extract new slices
      let newTimes = Array(chunkTimes[startIndex...])
      
      // Helper to safely extract float array from chunk data
      func extractFloats(_ source: [Double]?) -> [Float] {
          guard let src = source else { return [] }
          let slice = src[startIndex...]
          return slice.map { Float($0) }
      }
      
      // Append
      timestamps.append(contentsOf: newTimes)
      ppgData.append(contentsOf: extractFloats(chunk.vitalSigns.ppgWaveform?.data))
      ppgConfidence.append(contentsOf: extractFloats(chunk.vitalSigns.ppgWaveform?.confidence))
      respData.append(contentsOf: extractFloats(chunk.vitalSigns.respiratoryWaveform?.data))
      respConfidence.append(contentsOf: extractFloats(chunk.vitalSigns.respiratoryWaveform?.confidence))
  }

  /// Trims buffers to the maximum defined history length.
  private func pruneBuffers() {
      if timestamps.count > maxHistoryLength {
          let dropCount = timestamps.count - maxHistoryLength
          
          timestamps.removeFirst(dropCount)
          // Safety check to ensure all arrays stay synced even if data was missing
          if ppgData.count > maxHistoryLength { ppgData.removeFirst(ppgData.count - maxHistoryLength) }
          if ppgConfidence.count > maxHistoryLength { ppgConfidence.removeFirst(ppgConfidence.count - maxHistoryLength) }
          if respData.count > maxHistoryLength { respData.removeFirst(respData.count - maxHistoryLength) }
          if respConfidence.count > maxHistoryLength { respConfidence.removeFirst(respConfidence.count - maxHistoryLength) }
      }
  }

  // MARK: - Estimation Logic

  private func estimateVitals(config: ModelConfig?) -> VitalSigns {
      // Calculate effective FPS from timestamps (robust to jitter)
      let fs = calculateEffectiveFPS() ?? Float(config?.fpsTarget ?? 30.0)
      
      var hrMetric: ScalarMetric?
      var rrMetric: ScalarMetric?
      var sdnnMetric: ScalarMetric?
      var rmssdMetric: ScalarMetric?
      
      // --- 1. Heart Rate ---
      if ppgData.count >= minEstimationWindow {
          // Preprocess
          let cleanPPG = SignalOps.detrend(ppgData, fs: fs)
          let standardizedPPG = SignalOps.standardize(cleanPPG)
          
          // Estimate Rate
          if let hr = SignalOps.estimateRate(from: standardizedPPG, fs: fs, minRate: 40, maxRate: 240) {
              // Calculate average confidence for the window
              let conf = calculateAverageConfidence(ppgConfidence)
              
              hrMetric = ScalarMetric(value: Double(hr), unit: "bpm", confidence: Double(conf), note: nil)
              lastHR = Double(hr)
              
              // --- 3. HRV (Dependent on valid HR) ---
              if ppgData.count >= minHRVWindow {
                  let peaks = SignalOps.findPeaks(in: standardizedPPG, fs: fs, hr: hr)
                  
                  if let sdnn = SignalOps.calculateSDNN(peaks: peaks, fs: fs) {
                      sdnnMetric = ScalarMetric(value: sdnn, unit: "ms", confidence: Double(conf), note: nil)
                  }
                  
                  if let rmssd = SignalOps.calculateRMSSD(peaks: peaks, fs: fs) {
                      rmssdMetric = ScalarMetric(value: rmssd, unit: "ms", confidence: Double(conf), note: nil)
                  }
              }
          }
      }
      
      // --- 2. Respiratory Rate ---
      if respData.count >= minEstimationWindow {
          let cleanResp = SignalOps.detrend(respData, fs: fs, cutoff: 0.1) // Lower cutoff for breathing
          let standardizedResp = SignalOps.standardize(cleanResp)
          
          if let rr = SignalOps.estimateRate(from: standardizedResp, fs: fs, minRate: 6, maxRate: 60) {
              let conf = calculateAverageConfidence(respConfidence)
              rrMetric = ScalarMetric(value: Double(rr), unit: "rpm", confidence: Double(conf), note: nil)
              lastRR = Double(rr)
          }
      }
      
      // --- Construct Output ---
      // Note: We pass back the *full* stitched waveform in the result for UI visualization graphs
      // Converting Float arrays back to Double for the API model contract
      let ppgOut = WaveformMetric(
          data: ppgData.map { Double($0) },
          unit: "unitless",
          confidence: ppgConfidence.map { Double($0) },
          note: nil
      )
      
      let respOut = WaveformMetric(
          data: respData.map { Double($0) },
          unit: "unitless",
          confidence: respConfidence.map { Double($0) },
          note: nil
      )
      
      return VitalSigns(
          heartRate: hrMetric,
          respiratoryRate: rrMetric,
          hrvSdnn: sdnnMetric,
          hrvRmssd: rmssdMetric,
          hrvLfhf: nil, // Not implemented yet
          ppgWaveform: ppgOut,
          respiratoryWaveform: respOut
      )
  }

  // MARK: - Helpers

  private func calculateEffectiveFPS() -> Float? {
      guard timestamps.count >= 2 else { return nil }
      
      // Use the last N frames to estimate current FPS
      let window = min(timestamps.count, 60)
      let slice = timestamps.suffix(window)
      
      guard let first = slice.first, let last = slice.last, last > first else { return nil }
      
      let duration = last - first
      let frames = Double(slice.count - 1)
      
      return Float(frames / duration)
  }

  private func calculateAverageConfidence(_ conf: [Float]) -> Float {
      guard !conf.isEmpty else { return 0.0 }
      // Simple mean
      let sum = conf.reduce(0, +)
      return sum / Float(conf.count)
  }

}