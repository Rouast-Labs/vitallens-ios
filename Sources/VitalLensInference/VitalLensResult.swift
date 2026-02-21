import Foundation
import CoreGraphics

/// A marker protocol for auxiliary data attached to a result.
/// Implement this in the host app to attach custom data (e.g. debug images, attention masks).
public protocol ResultAuxiliaryData: Sendable {}

/// The raw output from an inference strategy (API or CoreML).
/// All physiological data is represented as time-series arrays matching the frame count.
public struct VitalLensResult: Codable, Sendable {
    
    public let face: FaceData
    public let vitals: [String: Vital]
    public let waveforms: [String: Waveform]
    public let time: [Double]
    public let fps: Double?
    public let modelUsed: String?
    public let state: StateData?
    public let message: String?
    public let sampleCount: Int?

    public var auxiliary: (any ResultAuxiliaryData)? 

    // MARK: - Convenience Accessors
    
    public var ppg: Waveform? { waveforms["ppg_waveform"] }
    public var resp: Waveform? { waveforms["respiratory_waveform"] }
    
    public var heartRate: Vital? { vitals["heart_rate"] }
    public var respiratoryRate: Vital? { vitals["respiratory_rate"] }
    public var hrvSdnn: Vital? { vitals["hrv_sdnn"] }
    public var hrvRmssd: Vital? { vitals["hrv_rmssd"] }
    
    public var sbp: Vital? { vitals["sbp"] }
    public var dbp: Vital? { vitals["dbp"] }
    public var spo2: Vital? { vitals["spo2"] }

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
        let container = try decoder.container(keyedBy: DynamicKey.self)
        
        self.face = try container.decodeIfPresent(FaceData.self, forKey: DynamicKey(stringValue: "face")!) 
                    ?? FaceData(coordinates: [], confidence: [], note: nil)
        
        self.time = []
        self.fps = try container.decodeIfPresent(Double.self, forKey: DynamicKey(stringValue: "fps")!)
        
        self.modelUsed = try container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "model_used")!)
        self.state = try container.decodeIfPresent(StateData.self, forKey: DynamicKey(stringValue: "state")!)
        self.message = try container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "message")!)
        self.sampleCount = try container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "n")!)
        
        var tempWaveforms = [String: Waveform]()
        var tempVitals = [String: Vital]()

        // Parse legacy combined 'vital_signs' object
        if let vitalsContainer = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey(stringValue: "vital_signs")!) {
            for key in vitalsContainer.allKeys {
                if let wave = try? vitalsContainer.decode(Waveform.self, forKey: key) {
                    tempWaveforms[key.stringValue] = wave
                } else if let vital = try? vitalsContainer.decode(Vital.self, forKey: key) {
                    tempVitals[key.stringValue] = vital
                }
            }
        }
        
        // Parse split 'waveforms' object
        if let waveContainer = try? container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey(stringValue: "waveforms")!) {
            for key in waveContainer.allKeys {
                if let wave = try? waveContainer.decode(Waveform.self, forKey: key) {
                    tempWaveforms[key.stringValue] = wave
                }
            }
        }
        
        // Parse split 'vitals' object
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

public struct Vital: Codable, Sendable {
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
    
    // Add this custom decoder to handle potentially missing API fields safely
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.value = try container.decodeIfPresent(Double.self, forKey: .value) ?? 0.0
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.0
        self.unit = try container.decodeIfPresent(String.self, forKey: .unit) ?? ""
        self.note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

public struct Waveform: Codable, Sendable {
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