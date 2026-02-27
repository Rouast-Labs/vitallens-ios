import Foundation
import CoreGraphics
import VitalLensCore

public extension ModelConfig {
    /// Converts the `ModelConfig` into a `SessionConfig` required by the Core engine.
    ///
    /// - Returns: A `VitalLensCore.SessionConfig` populated with this model's parameters.
    func toSessionConfig() -> VitalLensCore.SessionConfig {
        return VitalLensCore.SessionConfig(
            modelName: self.modelName,
            supportedVitals: self.supportedVitals,
            returnWaveforms: ["ppg_waveform", "respiratory_waveform"],
            fpsTarget: Float(self.fpsTarget),
            inputSize: UInt64(self.inputSize),
            nInputs: UInt64(self.nInputs),
            roiMethod: self.roiMethod
        )
    }
}

public extension CGRect {
    /// Converts the `CGRect` into a `VitalLensCore.Rect`.
    ///
    /// - Returns: A `Rect` struct compatible with the Rust core logic.
    func toRustRect() -> VitalLensCore.Rect {
        return VitalLensCore.Rect(x: Float(minX), y: Float(minY), width: Float(width), height: Float(height))
    }
}

public extension VitalLensResult {
    /// Converts the `VitalLensResult` into a `SessionInput` to be fed into the Core engine for post-processing.
    ///
    /// - Returns: A `VitalLensCore.SessionInput` containing the raw signals, face data, and timestamps.
    func toSessionInput() -> VitalLensCore.SessionInput {
        var signalsMap: [String: SignalInput] = [:]
        
        for (key, wave) in self.waveforms {
            signalsMap[key] = SignalInput(data: wave.data, confidence: wave.confidence)
        }
        
        var faceInput: FaceInput? = nil
        if let coords = self.face.coordinates, let confs = self.face.confidence {
            faceInput = FaceInput(
                coordinates: coords.map { $0.map { Float($0) } },
                confidence: confs.map { Float($0) }
            )
        }
        
        return SessionInput(
            face: faceInput,
            signals: signalsMap,
            timestamp: self.time
        )
    }
}

public extension SessionResult {
    /// Converts the processed `SessionResult` from the Core engine back into a high-level `VitalLensResult`.
    ///
    /// - Parameters:
    ///   - originalState: The opaque state data to attach to the final result.
    ///   - message: An optional message overriding the default session message.
    ///   - modelUsed: The identifier of the model used to generate this data.
    /// - Returns: A comprehensive `VitalLensResult` populated with refined vitals and waveforms.
    func toVitalLensResult(originalState: StateData?, message: String?, modelUsed: String?) -> VitalLensResult {
        
        var finalWaveforms: [String: Waveform] = [:]
        for (key, wave) in self.waveforms {
            finalWaveforms[key] = Waveform(
                data: wave.data,
                confidence: wave.confidence,
                unit: wave.unit,
                note: wave.note
            )
        }
        
        var finalVitals: [String: Vital] = [:]
        for (key, vital) in self.vitals {
            finalVitals[key] = Vital(
                value: Double(vital.value),
                confidence: Double(vital.confidence),
                unit: vital.unit,
                note: vital.note
            )
        }
        
        var faceData = FaceData(coordinates: nil, confidence: nil, note: nil)
        if let f = self.face {
            faceData = FaceData(
                coordinates: f.coordinates.map { $0.map { Double($0) } },
                confidence: f.confidence.map { Double($0) },
                note: f.note
            )
        }
        
        return VitalLensResult(
            face: faceData,
            vitals: finalVitals,
            waveforms: finalWaveforms,
            time: self.timestamp,
            fps: Double(self.fps),
            modelUsed: modelUsed,
            state: originalState,
            message: message ?? self.message,
            sampleCount: self.timestamp.count
        )
    }
}

// MARK: - Sendable Conformances

extension VitalLensCore.Session: @retroactive @unchecked Sendable {}
extension VitalLensCore.BufferPlanner: @retroactive @unchecked Sendable {}
extension VitalLensCore.InferenceCommand: @retroactive @unchecked Sendable {}
extension VitalLensCore.InferenceMode: @retroactive @unchecked Sendable {}
extension VitalLensCore.Rect: @retroactive @unchecked Sendable {}
extension VitalLensCore.SessionConfig: @retroactive @unchecked Sendable {}
extension VitalLensCore.SessionInput: @retroactive @unchecked Sendable {}
extension VitalLensCore.BufferConfig: @retroactive @unchecked Sendable {}