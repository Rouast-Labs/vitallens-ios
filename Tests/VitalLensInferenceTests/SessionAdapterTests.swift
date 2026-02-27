import XCTest
import CoreGraphics
import VitalLensCore
@testable import VitalLensInference

final class SessionAdapterTests: XCTestCase {
    
    // MARK: - Configuration Mapping
    
    func testModelConfigToSessionConfig() {
        let config = ModelConfig(nInputs: 4, inputSize: 40, fpsTarget: 30.5, roiMethod: "forehead", supportedVitals: ["heart_rate", "sbp"])
        let rustConfig = config.toSessionConfig()
        
        XCTAssertEqual(rustConfig.nInputs, 4)
        XCTAssertEqual(rustConfig.inputSize, 40)
        XCTAssertEqual(rustConfig.fpsTarget, 30.5)
        XCTAssertEqual(rustConfig.roiMethod, "forehead")
        XCTAssertEqual(rustConfig.supportedVitals, ["heart_rate", "sbp"])
    }
    
    // MARK: - Geometry Mapping
    
    func testCGRectToRustRect() {
        let cgRect = CGRect(x: 10.5, y: 20.5, width: 30.0, height: 40.0)
        let rustRect = cgRect.toRustRect()
        
        XCTAssertEqual(rustRect.x, 10.5)
        XCTAssertEqual(rustRect.y, 20.5)
        XCTAssertEqual(rustRect.width, 30.0)
        XCTAssertEqual(rustRect.height, 40.0)
    }
    
    // MARK: - Result to Input Mapping
    
    func testVitalLensResultToSessionInput_SignalMapping() {
        let wave = Waveform(data: [1.0, 2.0], confidence: [0.5, 0.5], unit: "bpm", note: nil)
        let result = VitalLensResult(
            face: FaceData(coordinates: nil, confidence: nil, note: nil),
            vitals: [:],
            waveforms: ["custom_signal": wave],
            time: [100.0, 101.0]
        )
        
        let sessionInput = result.toSessionInput()
        
        XCTAssertEqual(sessionInput.timestamp, [100.0, 101.0])
        XCTAssertEqual(sessionInput.signals["custom_signal"]?.data, [1.0, 2.0])
    }

    func testVitalLensResultToSessionInput_FaceAndEmptyStates() {
        let face = FaceData(coordinates: [[0.5, 0.25, 0.75, 1.0]], confidence: [0.5], note: "ok")
        let resultWithFace = VitalLensResult(face: face, vitals: [:], waveforms: [:], time: [])
        XCTAssertNotNil(resultWithFace.toSessionInput().face)

        let emptyResult = VitalLensResult(face: FaceData(coordinates: nil, confidence: nil, note: nil), vitals: [:], waveforms: [:], time: [])
        let emptyInput = emptyResult.toSessionInput()
        XCTAssertTrue(emptyInput.signals.isEmpty)
        XCTAssertNil(emptyInput.face)
    }
    
    // MARK: - Session to Result Mapping
    
    func testSessionResultToVitalLensResult_Mapping() {
        let rustFace = FaceResult(coordinates: [[0.1, 0.1, 0.2, 0.2]], confidence: [0.9], note: "rust_ok")
        let rustVital = VitalResult(value: 60.0, confidence: 0.5, unit: "bpm", note: "hr_note")
        let rustWave = WaveformResult(data: [0.5, 0.25], confidence: [1.0, 1.0], unit: "u", note: "ppg_note")
        
        let sessionResult = SessionResult(
            timestamp: [10.0, 11.0],
            face: rustFace,
            waveforms: ["ppg_waveform": rustWave],
            vitals: ["heart_rate": rustVital],
            fps: 30.0,
            message: "rust_msg"
        )
        
        let state = StateData(data: "b64", note: nil)
        let vlResult = sessionResult.toVitalLensResult(originalState: state, message: "override", modelUsed: "test_model")
        
        XCTAssertEqual(vlResult.message, "override")
        XCTAssertEqual(vlResult.modelUsed, "test_model")
        XCTAssertEqual(vlResult.state?.data, "b64")
        XCTAssertEqual(vlResult.heartRate?.value, 60.0)
        XCTAssertEqual(vlResult.ppg?.data.count, 2)
        XCTAssertEqual(vlResult.sampleCount, 2)
    }
    
    func testSessionResultToVitalLensResult_Fallbacks() {
        let sessionResult = SessionResult(timestamp: [10.0], face: nil, waveforms: [:], vitals: [:], fps: 30.0, message: "msg")
        let vlResult = sessionResult.toVitalLensResult(originalState: nil, message: nil, modelUsed: nil)
        
        XCTAssertEqual(vlResult.message, "msg")
        XCTAssertNil(vlResult.face.coordinates)
        XCTAssertTrue(vlResult.waveforms.isEmpty)
    }
}