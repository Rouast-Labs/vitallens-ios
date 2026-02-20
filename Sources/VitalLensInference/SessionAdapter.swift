import Foundation
import CoreGraphics
import VitalLensCore

public extension ModelConfig {
    func toSessionConfig() -> VitalLensCore.SessionConfig {
        return VitalLensCore.SessionConfig(
            supportedVitals: self.supportedVitals,
            returnWaveforms: nil,
            fpsTarget: Float(self.fpsTarget),
            inputSize: UInt64(self.inputSize),
            nInputs: UInt64(self.nInputs),
            roiMethod: self.roiMethod
        )
    }
}

public extension CGRect {
    func toRustRect() -> VitalLensCore.Rect {
        return VitalLensCore.Rect(x: Float(minX), y: Float(minY), width: Float(width), height: Float(height))
    }
}

public extension VitalLensResult {
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
    func toVitalLensResult(originalState: StateData?, message: String?, modelUsed: String?) -> VitalLensResult {
        
        var finalWaveforms: [String: TimeSeries] = [:]
        for (key, wave) in self.waveforms {
            finalWaveforms[key] = TimeSeries(
                data: wave.data,
                confidence: wave.confidence,
                unit: wave.unit,
                note: nil // TODO: Support note
            )
        }
        
        var finalVitals: [String: ScalarResult] = [:]
        for (key, vital) in self.vitals {
            finalVitals[key] = ScalarResult(
                value: Double(vital.value),
                confidence: Double(vital.confidence),
                unit: vital.unit,
                note: nil // TODO: Support note
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

// MARK: - Sendable Conformances for UniFFI Types

extension VitalLensCore.Session: @unchecked Sendable {}
extension VitalLensCore.BufferPlanner: @unchecked Sendable {}
extension VitalLensCore.InferenceCommand: @unchecked Sendable {}
extension VitalLensCore.InferenceMode: @unchecked Sendable {}
extension VitalLensCore.Rect: @unchecked Sendable {}
extension VitalLensCore.SessionConfig: @unchecked Sendable {}
extension VitalLensCore.SessionInput: @unchecked Sendable {}
extension VitalLensCore.BufferConfig: @unchecked Sendable {}