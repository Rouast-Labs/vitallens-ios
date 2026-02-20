import XCTest
import CoreGraphics
import VitalLensCore
@testable import VitalLensInference

final class SessionAdapterTests: XCTestCase {
    
    // MARK: - Swift to Rust (Lowering)
    
    func testModelConfigToSessionConfig() {
        let config = ModelConfig(nInputs: 4, inputSize: 40, fpsTarget: 30.5, roiMethod: "forehead", supportedVitals: ["heart_rate", "sbp"])
        let rustConfig = config.toSessionConfig()
        
        XCTAssertEqual(rustConfig.nInputs, 4)
        XCTAssertEqual(rustConfig.inputSize, 40)
        XCTAssertEqual(rustConfig.fpsTarget, 30.5)
        XCTAssertEqual(rustConfig.roiMethod, "forehead")
        XCTAssertEqual(rustConfig.supportedVitals, ["heart_rate", "sbp"])
    }
    
    func testCGRectToRustRect() {
        let cgRect = CGRect(x: 10.5, y: 20.5, width: 30.0, height: 40.0)
        let rustRect = cgRect.toRustRect()
        
        XCTAssertEqual(rustRect.x, 10.5)
        XCTAssertEqual(rustRect.y, 20.5)
        XCTAssertEqual(rustRect.width, 30.0)
        XCTAssertEqual(rustRect.height, 40.0)
    }
    
    func testVitalLensResultToSessionInput_WithFace() {
        let wave = Waveform(data: [1.0, 2.0], confidence: [0.5, 0.5], unit: "bpm", note: nil)
        let face = FaceData(coordinates: [[0.5, 0.25, 0.75, 1.0]], confidence: [0.5], note: "ok")
        let result = VitalLensResult(
            face: face,
            vitals: [:],
            waveforms: ["ppg": wave],
            time: [100.0, 101.0]
        )
        
        let chunk = result.toSessionInput()
        
        XCTAssertEqual(chunk.timestamp, [100.0, 101.0])
        XCTAssertEqual(chunk.signals["ppg"]?.data, [1.0, 2.0])
        XCTAssertNotNil(chunk.face)
        XCTAssertEqual(chunk.face?.coordinates.count, 1)
    }

    func testVitalLensResultToSessionInput_EmptySignals() {
        let result = VitalLensResult(
            face: FaceData(coordinates: nil, confidence: nil, note: nil),
            vitals: [:],
            waveforms: [:],
            time: []
        )
        let chunk = result.toSessionInput()
        XCTAssertTrue(chunk.signals.isEmpty)
        XCTAssertNil(chunk.face)
    }
    
    // MARK: - Rust to Swift (Lifting)
    
    func testSessionResultToVitalLensResult_FullData() {
        let rustFace = FaceResult(coordinates: [[0.5, 0.25, 0.75, 1.0]], confidence: [0.9], note: "rust_ok")
        let rustVital = VitalResult(value: 60.0, confidence: 0.5, unit: "bpm")
        let rustWave = WaveformResult(data: [0.5, 0.25], confidence: [1.0, 1.0], unit: "unitless")
        
        let sessionResult = SessionResult(
            timestamp: [10.0, 11.0],
            face: rustFace,
            waveforms: ["ppg_waveform": rustWave],
            vitals: ["heart_rate": rustVital],
            fps: 30.0,
            message: "rust_msg"
        )
        
        let state = StateData(data: "base64state", note: nil)
        let vlResult = sessionResult.toVitalLensResult(originalState: state, message: "override_msg", modelUsed: "test_model")
        
        XCTAssertEqual(vlResult.message, "override_msg")
        XCTAssertEqual(vlResult.modelUsed, "test_model")
        XCTAssertEqual(vlResult.state?.data, "base64state")
        XCTAssertEqual(vlResult.heartRate?.value, 60.0)
        XCTAssertEqual(vlResult.ppg?.data.count, 2)
    }
    
    func testSessionResultToVitalLensResult_NilFallbacks() {
        // Test behavior when optional inputs are nil
        let sessionResult = SessionResult(
            timestamp: [10.0],
            face: nil,
            waveforms: [:],
            vitals: [:],
            fps: 30.0,
            message: "rust_msg"
        )
        
        let vlResult = sessionResult.toVitalLensResult(originalState: nil, message: nil, modelUsed: nil)
        
        XCTAssertEqual(vlResult.message, "rust_msg", "Should fallback to rust core message if swift message is nil")
        XCTAssertNil(vlResult.state)
        XCTAssertNil(vlResult.modelUsed)
        XCTAssertNil(vlResult.face.coordinates)
        XCTAssertTrue(vlResult.waveforms.isEmpty)
    }

    func testSessionResultToVitalLensResult_PartialFaceData() {
        // Rust core might return a FaceResult with coordinates, but we ensure our 
        // VitalLensResult constructor handles it.
        let rustFace = FaceResult(coordinates: [], confidence: [], note: "no_face")
        let sessionResult = SessionResult(
            timestamp: [],
            face: rustFace,
            waveforms: [:],
            vitals: [:],
            fps: 30.0,
            message: "OK"
        )
        
        let vlResult = sessionResult.toVitalLensResult(originalState: nil, message: nil, modelUsed: nil)
        
        XCTAssertNotNil(vlResult.face)
        XCTAssertEqual(vlResult.face.note, "no_face")
        XCTAssertTrue(vlResult.face.boundingBoxes.isEmpty)
    }
    
    func testSessionResultToVitalLensResult_PreservesSampleCount() {
        let sessionResult = SessionResult(
            timestamp: [1.0, 2.0, 3.0],
            face: nil,
            waveforms: [:],
            vitals: [:],
            fps: 30.0,
            message: "OK"
        )
        
        let vlResult = sessionResult.toVitalLensResult(originalState: nil, message: nil, modelUsed: nil)
        XCTAssertEqual(vlResult.sampleCount, 3)
    }
}