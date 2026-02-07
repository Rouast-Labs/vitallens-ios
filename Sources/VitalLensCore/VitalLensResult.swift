import Foundation
import CoreGraphics

// MARK: - Top Level Result

/// The primary response object returned by the VitalLens API.
///
/// This structure contains all estimation data for a processed video chunk, including
/// face detection results, vital sign estimates, and temporal information.
public struct VitalLensResult: Codable, Sendable {
    
    /// Face detection metadata for the processed video frames.
    public let face: FaceData
    
    /// A collection of estimated vital signs, including both scalar metrics and waveforms.
    public let vitalSigns: VitalSigns
    
    /// The timestamps corresponding to each processed frame (in seconds).
    public let time: [Double]
    
    /// A suggested display timestamp for synchronization in real-time UI applications.
    public let displayTime: Double?
    
    /// The detected frame rate of the input video.
    public let fps: Double?
    
    /// The effective frame rate used for inference (estimation FPS).
    public let estFps: Double?
    
    /// The identifier of the specific model version used for inference (e.g., "vitallens-2.0").
    public let modelUsed: String?
    
    /// The internal Recurrent Neural Network (RNN) state.
    /// This property is populated during streaming to allow state continuity between API calls.
    public let state: StateData?
    
    /// Additional informational messages or warnings from the API.
    public let message: String?

    public init(
        face: FaceData,
        vitalSigns: VitalSigns,
        time: [Double],
        displayTime: Double? = nil,
        fps: Double? = nil,
        estFps: Double? = nil,
        modelUsed: String? = nil,
        state: StateData? = nil,
        message: String? = nil
    ) {
        self.face = face
        self.vitalSigns = vitalSigns
        self.time = time
        self.displayTime = displayTime
        self.fps = fps
        self.estFps = estFps
        self.modelUsed = modelUsed
        self.state = state
        self.message = message
    }
    
    enum CodingKeys: String, CodingKey {
        case face
        case vitalSigns = "vital_signs"
        case time
        case displayTime
        case fps
        case estFps
        case modelUsed = "model_used"
        case state
        case message
    }
}

// MARK: - Face Data

/// detailed information about the face detection process.
public struct FaceData: Codable, Sendable {
    
    /// A list of bounding boxes for the detected face in each frame.
    /// Format: `[[x, y, x2, y2], ...]` (normalized 0.0 - 1.0).
    public let coordinates: [[Double]]?
    
    /// A list of confidence scores for the face detection in each frame (0.0 - 1.0).
    public let confidence: [Double]?
    
    /// An explanatory note regarding the face detection status.
    public let note: String?

    public init(coordinates: [[Double]]?, confidence: [Double]?, note: String?) {
        self.coordinates = coordinates
        self.confidence = confidence
        self.note = note
    }
    
    /// A helper property that converts the raw coordinate arrays into `CGRect` objects.
    /// Returns normalized rectangles (0.0 - 1.0).
    public var boundingBoxes: [CGRect] {
        guard let coords = coordinates else { return [] }
        return coords.map { c in
            guard c.count == 4 else { return .zero }
            return CGRect(x: c[0], y: c[1], width: c[2] - c[0], height: c[3] - c[1])
        }
    }
}

// MARK: - Vital Signs

/// A container for all physiological metrics estimated by the model.
public struct VitalSigns: Codable, Sendable {
    
    // MARK: Scalar Metrics
    
    /// The estimated heart rate in beats per minute (BPM).
    public let heartRate: ScalarMetric?
    
    /// The estimated respiratory rate in breaths per minute (RPM).
    public let respiratoryRate: ScalarMetric?
    
    // MARK: HRV Metrics
    
    /// Heart Rate Variability: Standard Deviation of NN intervals (SDNN).
    public let hrvSdnn: ScalarMetric?
    
    /// Heart Rate Variability: Root Mean Square of Successive Differences (RMSSD).
    public let hrvRmssd: ScalarMetric?
    
    /// Heart Rate Variability: Ratio of Low Frequency to High Frequency power (LF/HF).
    public let hrvLfhf: ScalarMetric?
    
    // MARK: Waveforms
    
    /// The photoplethysmogram (PPG) signal waveform.
    public let ppgWaveform: WaveformMetric?
    
    /// The respiratory signal waveform.
    public let respiratoryWaveform: WaveformMetric?

    public init(
        heartRate: ScalarMetric?,
        respiratoryRate: ScalarMetric?,
        hrvSdnn: ScalarMetric?,
        hrvRmssd: ScalarMetric?,
        hrvLfhf: ScalarMetric?,
        ppgWaveform: WaveformMetric?,
        respiratoryWaveform: WaveformMetric?
    ) {
        self.heartRate = heartRate
        self.respiratoryRate = respiratoryRate
        self.hrvSdnn = hrvSdnn
        self.hrvRmssd = hrvRmssd
        self.hrvLfhf = hrvLfhf
        self.ppgWaveform = ppgWaveform
        self.respiratoryWaveform = respiratoryWaveform
    }
    
    enum CodingKeys: String, CodingKey {
        case heartRate = "heart_rate"
        case respiratoryRate = "respiratory_rate"
        case hrvSdnn = "hrv_sdnn"
        case hrvRmssd = "hrv_rmssd"
        case hrvLfhf = "hrv_lfhf"
        case ppgWaveform = "ppg_waveform"
        case respiratoryWaveform = "respiratory_waveform"
    }
}

// MARK: - Helper Types

/// Encapsulates the Recurrent Neural Network (RNN) state.
///
/// This opaque data blob is required for continuity when performing streaming inference.
/// Clients must persist this object and include it in the subsequent API request.
public struct StateData: Codable, Sendable {
    
    /// Base64 encoded string representing the flattened RNN state tensors.
    public let data: String
    
    /// Optional metadata regarding the state.
    public let note: String?
    
    public init(data: String, note: String?) {
        self.data = data
        self.note = note
    }
}

/// Represents a single scalar value measurement (e.g., Heart Rate).
public struct ScalarMetric: Codable, Sendable {
    
    /// The numeric value of the metric.
    public let value: Double?
    
    /// The unit of measurement (e.g., "bpm", "ms").
    public let unit: String
    
    /// The confidence score of the estimation (0.0 - 1.0).
    public let confidence: Double?
    
    /// Additional context or warnings about the measurement.
    public let note: String?
    
    public init(value: Double?, unit: String, confidence: Double?, note: String?) {
        self.value = value
        self.unit = unit
        self.confidence = confidence
        self.note = note
    }
}

/// Represents a time-series waveform measurement (e.g., PPG signal).
public struct WaveformMetric: Codable, Sendable {
    
    /// The array of signal values.
    public let data: [Double]
    
    /// The unit of measurement (usually "unitless" for normalized signals).
    public let unit: String
    
    /// The confidence score for each data point in the waveform.
    public let confidence: [Double]
    
    /// Additional context about the waveform.
    public let note: String?
    
    public init(data: [Double], unit: String, confidence: [Double], note: String?) {
        self.data = data
        self.unit = unit
        self.confidence = confidence
        self.note = note
    }
}