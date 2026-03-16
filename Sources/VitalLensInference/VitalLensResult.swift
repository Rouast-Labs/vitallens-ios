import Foundation
import CoreGraphics

/// A marker protocol for auxiliary data attached to a result.
public protocol ResultAuxiliaryData: Sendable {}

/// The comprehensive output from an inference strategy (API or CoreML).
/// All physiological data is represented as time-series arrays or aggregated scalar values
/// corresponding to the processed video frames.
public struct VitalLensResult: Codable, Sendable {
    
    /// The face tracking data for the processed frames.
    public let face: FaceData
    
    /// A dictionary of aggregated physiological vital signs (e.g., heart rate, respiratory rate).
    public let vitals: [String: Vital]
    
    /// A dictionary of time-series physiological signals (e.g., PPG, respiration waveforms).
    public let waveforms: [String: Waveform]
    
    /// The array of timestamps corresponding to each frame in the result.
    public let time: [Double]
    
    /// The target frames per second used during this inference pass.
    public let fps: Double?
    
    /// The identifier of the specific model that generated this result.
    public let modelUsed: String?
    
    /// The opaque recurrent state to be passed into the next sequential inference request.
    public let state: StateData?
    
    /// An optional status or informational message from the inference engine.
    public let message: String?
    
    /// The total number of frames processed in this result batch.
    public let sampleCount: Int?

    /// Optional auxiliary data attached by the host application.
    public var auxiliary: (any ResultAuxiliaryData)?

    /// A dictionary of time-series rolling vital sign estimates.
    public let rollingVitals: [String: Waveform]?

    /// Convenience accessors
    public var ppg: Waveform? { waveforms["ppg_waveform"] }
    public var resp: Waveform? { waveforms["respiratory_waveform"] }
    public var heartRate: Vital? { vitals["heart_rate"] }
    public var respiratoryRate: Vital? { vitals["respiratory_rate"] }
    public var hrvSdnn: Vital? { vitals["hrv_sdnn"] }
    public var hrvRmssd: Vital? { vitals["hrv_rmssd"] }
    public var sbp: Vital? { vitals["sbp"] }
    public var dbp: Vital? { vitals["dbp"] }
    public var spo2: Vital? { vitals["spo2"] }

    /// Initializes a new VitalLensResult manually.
    ///
    /// - Parameters:
    ///   - face: The tracking data for the face.
    ///   - vitals: The dictionary of computed vital signs.
    ///   - waveforms: The dictionary of computed waveforms.
    ///   - time: The array of timestamps.
    ///   - fps: The frame rate.
    ///   - modelUsed: The model identifier.
    ///   - state: The opaque recurrent state.
    ///   - message: An optional status message.
    ///   - sampleCount: The number of frames processed.
    ///   - auxiliary: Optional app-specific auxiliary data.
    ///   - rollingVitals: Optional dict of rolling vitals.
    public init(
        face: FaceData,
        vitals: [String: Vital],
        waveforms: [String: Waveform],
        time: [Double],
        fps: Double? = nil,
        modelUsed: String? = nil,
        state: StateData? = nil,
        message: String? = nil,
        sampleCount: Int? = nil,
        auxiliary: (any ResultAuxiliaryData)? = nil,
        rollingVitals: [String: Waveform]? = nil
    ) {
        self.face = face
        self.vitals = vitals
        self.waveforms = waveforms
        self.time = time
        self.fps = fps
        self.modelUsed = modelUsed
        self.state = state
        self.message = message
        self.sampleCount = sampleCount
        self.auxiliary = auxiliary
        self.rollingVitals = rollingVitals
    }
    
    struct DynamicKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { return nil }
        init?(intValue: Int) { return nil }
    }

    enum CodingKeys: String, CodingKey {
        case face, waveforms, vitals, time, fps, modelUsed, state, message, sampleCount
        case rollingVitals = "rolling_vitals"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        
        self.face = try container.decodeIfPresent(FaceData.self, forKey: DynamicKey(stringValue: "face")!) 
                    ?? FaceData(coordinates: [], confidence: [], note: nil)
        
        self.time = []
        self.fps = try container.decodeIfPresent(Double.self, forKey: DynamicKey(stringValue: "fps")!)
        
        self.modelUsed = try container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "model_used")!)
        self.state = try container.decodeIfPresent(StateData.self, forKey: DynamicKey(stringValue: "state")!)
        self.message = try container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "message")!)
        self.sampleCount = try container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "n")!)
        self.rollingVitals = try container.decodeIfPresent([String: Waveform].self, forKey: DynamicKey(stringValue: "rolling_vitals")!)

        var tempWaveforms = [String: Waveform]()
        var tempVitals = [String: Vital]()

        if let waveContainer = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey(stringValue: "waveforms")!) {
            for key in waveContainer.allKeys {
                if let wave = try? waveContainer.decode(Waveform.self, forKey: key) {
                    tempWaveforms[key.stringValue] = wave
                }
            }
        }
        
        if let newVitalsContainer = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey(stringValue: "vitals")!) {
            for key in newVitalsContainer.allKeys {
                if let vital = try? newVitalsContainer.decode(Vital.self, forKey: key) {
                    tempVitals[key.stringValue] = vital
                }
            }
        }
        
        self.waveforms = tempWaveforms
        self.vitals = tempVitals
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(face, forKey: .face)
        try container.encode(time, forKey: .time)
        try container.encodeIfPresent(fps, forKey: .fps)
        try container.encodeIfPresent(modelUsed, forKey: .modelUsed)
        try container.encodeIfPresent(state, forKey: .state)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(sampleCount, forKey: .sampleCount)
        try container.encode(waveforms, forKey: .waveforms)
        try container.encode(vitals, forKey: .vitals)
        try container.encodeIfPresent(rollingVitals, forKey: .rollingVitals)
    }
}

/// Represents an aggregated scalar physiological value.
public struct Vital: Codable, Sendable {
    
    /// The estimated value of the vital sign.
    public let value: Double
    
    /// The confidence score of the estimation (0.0 to 1.0).
    public let confidence: Double
    
    /// The unit of measurement for this vital sign (e.g., "bpm", "mmHg").
    public let unit: String
    
    /// An optional informational note regarding the calculation.
    public let note: String?
    
    /// Initializes a new Vital instance.
    ///
    /// - Parameters:
    ///   - value: The estimated scalar value.
    ///   - confidence: The confidence of the estimation.
    ///   - unit: The unit of measurement.
    ///   - note: An optional descriptive note.
    public init(value: Double, confidence: Double, unit: String, note: String? = nil) {
        self.value = value
        self.confidence = confidence
        self.unit = unit
        self.note = note
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.value = try container.decodeIfPresent(Double.self, forKey: .value) ?? 0.0
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.0
        self.unit = try container.decodeIfPresent(String.self, forKey: .unit) ?? ""
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

/// Represents a time-series physiological signal.
public struct Waveform: Codable, Sendable {
    
    /// The raw time-series data points of the waveform.
    public let data: [Float]
    
    /// The confidence scores for each data point in the waveform.
    public let confidence: [Float]
    
    /// The unit of measurement, if applicable.
    public let unit: String?
    
    /// An optional informational note.
    public let note: String?
    
    /// Initializes a new Waveform instance.
    ///
    /// - Parameters:
    ///   - data: The time-series data points.
    ///   - confidence: The confidence scores matching the data points.
    ///   - unit: The unit of measurement.
    ///   - note: An optional descriptive note.
    public init(data: [Float], confidence: [Float], unit: String?, note: String?) {
        self.data = data
        self.confidence = confidence
        self.unit = unit
        self.note = note
    }
}

/// Detailed information about the face detection process over the processed window.
public struct FaceData: Codable, Sendable {
    
    /// A list of bounding boxes for the detected face in each frame.
    /// Format: `[[minX, minY, maxX, maxY], ...]` (normalized 0.0 - 1.0).
    public let coordinates: [[Double]]?
    
    /// A list of confidence scores for the face detection in each frame (0.0 - 1.0).
    public let confidence: [Double]?
    
    /// An explanatory note regarding the face detection status.
    public let note: String?

    /// Initializes a new FaceData instance.
    ///
    /// - Parameters:
    ///   - coordinates: The array of normalized bounding boxes.
    ///   - confidence: The array of confidence scores.
    ///   - note: An optional descriptive note.
    public init(coordinates: [[Double]]?, confidence: [Double]?, note: String?) {
        self.coordinates = coordinates
        self.confidence = confidence
        self.note = note
    }
    
    /// A helper property that converts the raw coordinate arrays into `CGRect` objects.
    ///
    /// - Returns: An array of normalized rectangles (0.0 - 1.0).
    public var boundingBoxes: [CGRect] {
        guard let coords = coordinates else { return [] }
        return coords.map { c in
            guard c.count == 4 else { return .zero }
            return CGRect(x: c[0], y: c[1], width: c[2] - c[0], height: c[3] - c[1])
        }
    }
}

/// Encapsulates the state.
///
/// This opaque data blob is required for continuity when performing real-time streaming inference.
/// Clients must persist this object and include it in the subsequent API request.
public struct StateData: Codable, Sendable {
    
    /// The base64 encoded string representing the flattened state tensors.
    public let data: String
    
    /// Optional metadata regarding the state.
    public let note: String?

    /// Initializes a new StateData instance.
    ///
    /// - Parameters:
    ///   - data: The base64 encoded state data.
    ///   - note: An optional note regarding the state.
    public init(data: String, note: String?) {
        self.data = data
        self.note = note
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
        
        if let stringData = try? container.decode(String.self, forKey: .data) {
            self.data = stringData
        } else if let floatArray = try? container.decode([Float].self, forKey: .data) {
            let rawData = floatArray.withUnsafeBufferPointer { Data(buffer: $0) }
            self.data = rawData.base64EncodedString()
        } else {
            throw DecodingError.typeMismatch(String.self, DecodingError.Context(codingPath: container.codingPath, debugDescription: "State data expected to be String or [Float]"))
        }
    }
}