import Foundation
import CoreGraphics

// MARK: - Top Level Result

// TODO: Adopt dynamic model/vital agnostic structure with vital registry

/// The result returned by the VitalLens API.
public struct VitalLensResult: Codable, Sendable {
    
    /// Face detection data for the processed video.
    public let face: FaceData
    
    /// The estimated vital signs and waveforms.
    public let vitalSigns: VitalSigns
    
    /// The timestamps for each processed frame (in seconds).
    public let time: [Double]
    
    /// Recommended display time for synchronization (used in live streams).
    public let displayTime: Double?
    
    /// The input video's frame rate.
    public let fps: Double?
    
    /// The effective frame rate used for inference (estimation FPS).
    public let estFps: Double?
    
    /// The name of the model actually used by the API (e.g., "vitallens-2.0").
    public let modelUsed: String?
    
    /// The internal recurrent state of the model.
    /// Only populated if the API returns state data.
    public let state: StateData?
    
    /// Additional information or warnings from the API.
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

public struct FaceData: Codable, Sendable {
    /// Raw coordinates from JSON: [[x0, y0, x1, y1], ...]
    public let coordinates: [[Double]]?
    
    /// Confidence values for the face detection per frame (0.0 - 1.0).
    public let confidence: [Double]?
    
    /// Explanatory note regarding face detection.
    public let note: String?

    public init(coordinates: [[Double]]?, confidence: [Double]?, note: String?) {
        self.coordinates = coordinates
        self.confidence = confidence
        self.note = note
    }
    
    /// Computed property to get coordinates as clean CGRects.
    public var boundingBoxes: [CGRect] {
        guard let coords = coordinates else { return [] }
        return coords.map { c in
            guard c.count == 4 else { return .zero }
            return CGRect(x: c[0], y: c[1], width: c[2] - c[0], height: c[3] - c[1])
        }
    }
}

// MARK: - Vital Signs

public struct VitalSigns: Codable, Sendable {
    
    // MARK: Scalar Metrics
    public let heartRate: ScalarMetric?
    public let respiratoryRate: ScalarMetric?
    
    // MARK: HRV Metrics
    public let hrvSdnn: ScalarMetric?
    public let hrvRmssd: ScalarMetric?
    public let hrvLfhf: ScalarMetric?
    
    // MARK: Waveforms
    public let ppgWaveform: WaveformMetric?
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

/// Represents the Recurrent Neural Network (RNN) state returned by the API.
/// This must be persisted and sent back in the next request for streaming.
public struct StateData: Codable, Sendable {
    public let data: String
    public let note: String?
    
    public init(data: String, note: String?) {
        self.data = data
        self.note = note
    }
}

/// Represents a single scalar vital sign value (e.g., Heart Rate: 72 bpm).
public struct ScalarMetric: Codable, Sendable {
    public let value: Double?
    public let unit: String
    public let confidence: Double?
    public let note: String?
    
    public init(value: Double?, unit: String, confidence: Double?, note: String?) {
        self.value = value
        self.unit = unit
        self.confidence = confidence
        self.note = note
    }
}

/// Represents a waveform series (e.g. PPG signal).
public struct WaveformMetric: Codable, Sendable {
    public let data: [Double]
    public let unit: String
    public let confidence: [Double]
    public let note: String?
    
    public init(data: [Double], unit: String, confidence: [Double], note: String?) {
        self.data = data
        self.unit = unit
        self.confidence = confidence
        self.note = note
    }
}
