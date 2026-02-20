import Foundation
import CoreGraphics
import VitalLensCore

public extension ModelConfig {
    func toSessionConfig() -> VitalLensCore.SessionConfig {
        return VitalLensCore.SessionConfig(
            supportedVitals: self.supportedVitals,
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
    func toInputChunk() -> VitalLensCore.InputChunk {
        var signalsMap: [String: [Float]] = [:]
        var confMap: [String: [Float]] = [:]
        
        for (key, ts) in self.signals {
            signalsMap[key] = ts.data
            confMap[key] = ts.confidence
        }
        
        var faceInput: FaceInput? = nil
        if let coords = self.face.coordinates?.first, coords.count == 4, let conf = self.face.confidence?.first {
            faceInput = FaceInput(
                coordinates: coords.map { Float($0) },
                confidence: Float(conf)
            )
        }
        
        return InputChunk(
            timestamp: self.time,
            signals: signalsMap,
            confidences: confMap,
            face: faceInput
        )
    }
}

public extension SessionResult {
    func toVitalLensResult(originalState: StateData?, message: String?, modelUsed: String?) -> VitalLensResult {
        var finalSignals: [String: TimeSeries] = [:]
        for (key, sig) in self.signals {
            finalSignals[key] = TimeSeries(
                data: sig.data,
                confidence: sig.confidence,
                unit: sig.unit,
                note: sig.note
            )
        }

        // TODO: What about signals with value instead data?
        
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
            signals: finalSignals,
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
extension VitalLensCore.InputChunk: @unchecked Sendable {}
extension VitalLensCore.BufferConfig: @unchecked Sendable {}