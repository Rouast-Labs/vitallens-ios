import Foundation
import CoreGraphics

/// A marker protocol for auxiliary data attached to a result.
/// Implement this in the host app to attach custom data (e.g. debug images, attention masks).
public protocol ResultAuxiliaryData: Sendable {}

/// The raw output from an inference strategy (API or CoreML).
/// All physiological data is represented as time-series arrays matching the frame count.
public struct VitalLensResult: Codable, Sendable {
    
    public let face: FaceData
    public let vitals: [String: ScalarResult]
    public let waveforms: [String: TimeSeries]
    public let time: [Double]
    public let fps: Double?
    public let modelUsed: String?
    public let state: StateData?
    public let message: String?
    public let sampleCount: Int?

    public var auxiliary: (any ResultAuxiliaryData)? 

    // MARK: - Convenience Accessors
    
    public var ppg: TimeSeries? { waveforms["ppg_waveform"] } // TODO: Change key
    public var resp: TimeSeries? { waveforms["respiratory_waveform"] } // TODO: Change key
    
    public var heartRate: ScalarResult? { vitals["heart_rate"] }
    public var respiratoryRate: ScalarResult? { vitals["respiratory_rate"] }
    public var hrvSdnn: ScalarResult? { vitals["hrv_sdnn"] }
    public var hrvRmssd: ScalarResult? { vitals["hrv_rmssd"] }
    
    public var sbp: ScalarResult? { vitals["sbp"] }
    public var dbp: ScalarResult? { vitals["dbp"] }
    public var spo2: ScalarResult? { vitals["spo2"] }

    public init(
        face: FaceData,
        vitals: [String: ScalarResult],
        waveforms: [String: TimeSeries],
        time: [Double],
        fps: Double? = nil,
        modelUsed: String? = nil,
        state: StateData? = nil,
        message: String? = nil,
        sampleCount: Int? = nil,
        auxiliary: (any ResultAuxiliaryData)? = nil
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
    }
    
    // MARK: - Codable Implementation
    
    struct DynamicKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { return nil }
        init?(intValue: Int) { return nil }
    }

    enum CodingKeys: String, CodingKey {
        case face, signals, time, fps, modelUsed, state, message, sampleCount
        case vital_signs = "vital_signs"  
    }
    
    public init(from decoder: Decoder) throws {
        // Use DynamicKey directly for the root container
        let container = try decoder.container(keyedBy: DynamicKey.self)
        
        self.face = try container.decodeIfPresent(FaceData.self, forKey: DynamicKey(stringValue: "face")!) 
                    ?? FaceData(coordinates: [], confidence: [], note: nil)
        
        self.time = try container.decodeIfPresent([Double].self, forKey: DynamicKey(stringValue: "time")!) ?? []
        self.fps = try container.decodeIfPresent(Double.self, forKey: DynamicKey(stringValue: "fps")!)
        
        // Explicitly map the distinct JSON keys
        self.modelUsed = try container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "model_used")!)
        self.state = try container.decodeIfPresent(StateData.self, forKey: DynamicKey(stringValue: "state")!)
        self.message = try container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "message")!)
        self.sampleCount = try container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "n")!)
        
        if let vitalsContainer = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey(stringValue: "vital_signs")!) {
            var tempWaveforms = [String: TimeSeries]()
            var tempVitals = [String: ScalarResult]()
            
            for key in vitalsContainer.allKeys {
                if let signal = try? vitalsContainer.decode(TimeSeries.self, forKey: key) {
                    tempWaveforms[key.stringValue] = signal
                } 
                else if let scalar = try? vitalsContainer.decode(ScalarResponse.self, forKey: key) {
                    tempVitals[key.stringValue] = ScalarResult(
                        value: Double(scalar.value ?? 0),
                        confidence: Double(scalar.confidence ?? 0),
                        unit: scalar.unit ?? "",
                        note: scalar.note
                    )
                }
            }
            self.waveforms = tempWaveforms
            self.vitals = tempVitals
        } else {
            self.waveforms = [:]
            self.vitals = [:]
        }
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
        
        var dynamicContainer = encoder.container(keyedBy: DynamicKey.self)
        var vitalsContainer = dynamicContainer.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey(stringValue: "vital_signs")!)
        
        for (key, value) in waveforms {
            try vitalsContainer.encode(value, forKey: DynamicKey(stringValue: key)!)
        }
        for (key, value) in vitals {
            try vitalsContainer.encode(value, forKey: DynamicKey(stringValue: key)!)
        }
    }
}

/// Represents a raw time-series signal from the model.
/// Contains one value and one confidence score per frame.
public struct TimeSeries: Codable, Sendable {
    public let data: [Float]
    public let confidence: [Float]
    public let unit: String?
    public let note: String?
    
    public init(data: [Float], confidence: [Float], unit: String?, note: String?) {
        self.data = data
        self.confidence = confidence
        self.unit = unit
        self.note = note
    }
    
    // Init from Scalar Response (backend "value" format)
    init(scalar: ScalarResponse) {
        self.data = scalar.value != nil ? [scalar.value!] : []
        self.confidence = scalar.confidence != nil ? [scalar.confidence!] : []
        self.unit = scalar.unit
        self.note = scalar.note
    }
}

struct ScalarResponse: Decodable {
    let value: Float?
    let confidence: Float?
    let unit: String?
    let note: String?
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
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
        
        // FIX: Handle Polymorphic 'data' field (String OR Array<Float>)
        if let stringData = try? container.decode(String.self, forKey: .data) {
            self.data = stringData
        } else if let floatArray = try? container.decode([Float].self, forKey: .data) {
            // Convert [Float] -> Data -> Base64 String
            let rawData = floatArray.withUnsafeBufferPointer { Data(buffer: $0) }
            self.data = rawData.base64EncodedString()
        } else {
            // If it's null or missing, we can't do much, but let's avoid crashing if possible
            // or throw a specific error.
            throw DecodingError.typeMismatch(String.self, DecodingError.Context(codingPath: container.codingPath, debugDescription: "State data expected to be String or [Float]"))
        }
    }
}

// TODO: Name ScalarResult and TimeSeries in a more helpful and consistent way

public struct ScalarResult: Codable, Sendable {
    public let value: Double
    public let confidence: Double
    public let unit: String
    public let note: String?
    
    public init(value: Double, confidence: Double, unit: String, note: String? = nil) {
        self.value = value
        self.confidence = confidence
        self.unit = unit
        self.note = note
    }
}