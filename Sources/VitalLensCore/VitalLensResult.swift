import Foundation
import CoreGraphics

/// The raw output from an inference strategy (API or CoreML).
/// All physiological data is represented as time-series arrays matching the frame count.
public struct VitalLensResult: Codable, Sendable {
    
    public let face: FaceData
    
    /// The map of all raw signals returned by the model.
    /// Key: Signal ID (e.g., "ppg_waveform", "respiratory_waveform", "sbp", "spo2")
    /// Value: Time-series data
    public let signals: [String: TimeSeries]
    
    // Metadata
    public let time: [Double]
    public let fps: Double?
    public let modelUsed: String?
    public let state: StateData? // For RNN continuity
    public let message: String?

    // MARK: - Computed Convenience Accessors
    // These helpers allow strongly-typed access to known core signals while keeping the structure dynamic.
    
    public var ppg: TimeSeries? { signals["ppg_waveform"] }
    public var resp: TimeSeries? { signals["respiratory_waveform"] }
    
    // Future-proofing examples (these return nil if not present in 'signals')
    public var sbp: TimeSeries? { signals["sbp"] }
    public var dbp: TimeSeries? { signals["dbp"] }
    public var spo2: TimeSeries? { signals["spo2"] }

    public init(
        face: FaceData,
        signals: [String: TimeSeries],
        time: [Double],
        fps: Double? = nil,
        modelUsed: String? = nil,
        state: StateData? = nil,
        message: String? = nil
    ) {
        self.face = face
        self.signals = signals
        self.time = time
        self.fps = fps
        self.modelUsed = modelUsed
        self.state = state
        self.message = message
    }
    
    // MARK: - Dynamic Decoding
    
    struct DynamicKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { return nil }
        init?(intValue: Int) { return nil }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        
        // Decode standard fields
        self.face = try container.decode(FaceData.self, forKey: DynamicKey(stringValue: "face")!)
        self.time = try container.decode([Double].self, forKey: DynamicKey(stringValue: "time")!)
        self.fps = try container.decodeIfPresent(Double.self, forKey: DynamicKey(stringValue: "fps")!)
        self.modelUsed = try container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "model_used")!)
        self.state = try container.decodeIfPresent(StateData.self, forKey: DynamicKey(stringValue: "state")!)
        self.message = try container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "message")!)
        
        // Dynamic Signal Decoding
        // We look inside the "vital_signs" container
        let vitalsContainer = try container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey(stringValue: "vital_signs")!)
        
        var tempSignals = [String: TimeSeries]()
        
        for key in vitalsContainer.allKeys {
            // We assume everything inside 'vital_signs' conforms to the TimeSeries structure
            if let signal = try? vitalsContainer.decode(TimeSeries.self, forKey: key) {
                tempSignals[key.stringValue] = signal
            }
        }
        
        self.signals = tempSignals
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(face, forKey: DynamicKey(stringValue: "face")!)
        try container.encode(time, forKey: DynamicKey(stringValue: "time")!)
        try container.encodeIfPresent(fps, forKey: DynamicKey(stringValue: "fps")!)
        try container.encodeIfPresent(modelUsed, forKey: DynamicKey(stringValue: "model_used")!)
        try container.encodeIfPresent(state, forKey: DynamicKey(stringValue: "state")!)
        try container.encodeIfPresent(message, forKey: DynamicKey(stringValue: "message")!)
        
        var vitalsContainer = container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey(stringValue: "vital_signs")!)
        for (key, value) in signals {
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
}

// MARK: - UI Compatibility Helpers

/// A lightweight scalar representation for UI consumption.
public struct ScalarResult: Sendable {
    public let value: Double
    public let confidence: Double
    public let unit: String
}

public extension TimeSeries {
    /// Returns the most recent value from the time series as a scalar.
    var latest: ScalarResult? {
        guard let val = data.last, let conf = confidence.last else { return nil }
        return ScalarResult(
            value: Double(val),
            confidence: Double(conf),
            unit: unit ?? ""
        )
    }
}

public extension VitalLensResult {
    // These helpers allow the UI to access "heartRate.latest.value" 
    // mimicking the old "heartRate.value" behavior.
    
    var heartRate: TimeSeries? { signals["heart_rate"] }
    var respiratoryRate: TimeSeries? { signals["respiratory_rate"] }
    var hrvSdnn: TimeSeries? { signals["hrv_sdnn"] }
    var hrvRmssd: TimeSeries? { signals["hrv_rmssd"] }
    
    var ppgWaveform: TimeSeries? { signals["ppg_waveform"] }
    var respiratoryWaveform: TimeSeries? { signals["respiratory_waveform"] }
}