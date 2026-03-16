import XCTest
@testable import VitalLensInference

final class VitalLensResultTests: XCTestCase {
    
    // MARK: - Decoding
    
    func testDynamicDecoding() throws {
        let json = """
        {
            "face": {
                "coordinates": [[0.1, 0.1, 0.2, 0.2]],
                "confidence": [0.99],
                "note": "Face found"
            },
            "waveforms": {
                "ppg_waveform": {
                    "data": [0.5, 0.6, 0.7],
                    "confidence": [1.0, 1.0, 1.0],
                    "unit": "unitless",
                    "note": ""
                }
            },
            "vitals": {
                "sbp": {
                    "value": 121.0,
                    "confidence": 0.8,
                    "unit": "mmHg",
                    "note": "Experimental"
                }
            },
            "time": [1.0, 1.03, 1.06],
            "fps": 30.0,
            "message": "OK",
            "model_used": "vitallens_v3_hybrid",
            "n": 3
        }
        """.data(using: .utf8)!
        
        let result = try JSONDecoder().decode(VitalLensResult.self, from: json)
        
        XCTAssertEqual(result.fps, 30.0)
        XCTAssertEqual(result.message, "OK")
        XCTAssertEqual(result.modelUsed, "vitallens_v3_hybrid")
        XCTAssertEqual(result.sampleCount, 3)
        XCTAssertEqual(result.face.coordinates?.count, 1)
        
        XCTAssertNotNil(result.ppg)
        XCTAssertEqual(result.ppg?.data.count, 3)
        
        let ppgFirst = Double(result.ppg?.data.first ?? 0)
        XCTAssertEqual(ppgFirst, 0.5, accuracy: 0.001)
        
        XCTAssertNotNil(result.vitals["sbp"])
        XCTAssertEqual(result.vitals["sbp"]?.unit, "mmHg")
        XCTAssertEqual(result.vitals["sbp"]?.value ?? 0, 121.0, accuracy: 0.1)
    }
    
    func testStateDecoding_Polymorphic() throws {
        let jsonStringState = """
        {
            "face": {}, "signals": {}, "time": [],
            "state": { "data": "SGVsbG8=" }
        }
        """.data(using: .utf8)!
        
        let result1 = try JSONDecoder().decode(VitalLensResult.self, from: jsonStringState)
        XCTAssertEqual(result1.state?.data, "SGVsbG8=")
        
        let jsonArrayState = """
        {
            "face": {}, "signals": {}, "time": [],
            "state": { "data": [0.0, 0.0] }
        }
        """.data(using: .utf8)!
        
        let result2 = try JSONDecoder().decode(VitalLensResult.self, from: jsonArrayState)
        XCTAssertEqual(result2.state?.data, "AAAAAAAAAAA=")
    }
    
    func testMissingSignalsDoNotCrash() throws {
        let json = """
        {
            "face": { "coordinates": [], "confidence": [], "note": "" },
            "vitals": {},
            "waveforms": {},
            "time": [1.0]
        }
        """.data(using: .utf8)!
        
        let result = try JSONDecoder().decode(VitalLensResult.self, from: json)
        
        XCTAssertTrue(result.vitals.isEmpty)
        XCTAssertTrue(result.waveforms.isEmpty)
        XCTAssertNil(result.ppg)
        XCTAssertNil(result.heartRate)
    }

    func testVitalCustomDecoding_Defaults() throws {
        let json = "{\"value\": 75.0}".data(using: .utf8)!
        let vital = try JSONDecoder().decode(Vital.self, from: json)
        
        XCTAssertEqual(vital.value, 75.0)
        XCTAssertEqual(vital.confidence, 0.0)
        XCTAssertEqual(vital.unit, "")
    }

    func testWaveformDecoding() throws {
        let json = """
        {
            "data": [1.0, 2.0],
            "confidence": [0.9, 0.8],
            "unit": "unitless"
        }
        """.data(using: .utf8)!
        let wave = try JSONDecoder().decode(Waveform.self, from: json)
        XCTAssertEqual(wave.data.count, 2)
        XCTAssertEqual(wave.unit, "unitless")
    }

    func testPayloadRouting() throws {
        let json = """
        {
            "face": {}, "time": [],
            "vitals": {
                "stress_index": {
                    "value": 45.0,
                    "confidence": 0.8,
                    "unit": "pts"
                }
            },
            "waveforms": {
                "resp_signal": {
                    "data": [0.1, 0.2],
                    "confidence": [1.0, 1.0]
                }
            }
        }
        """.data(using: .utf8)!
        
        let result = try JSONDecoder().decode(VitalLensResult.self, from: json)
        
        XCTAssertNotNil(result.vitals["stress_index"])
        XCTAssertEqual(result.vitals["stress_index"]?.value, 45.0)
        
        XCTAssertNotNil(result.waveforms["resp_signal"])
        XCTAssertEqual(result.waveforms["resp_signal"]?.data.count, 2)
    }

    // MARK: - Convenience Accessors

    func testResultConvenienceAccessors() {
        let result = VitalLensResult(
            face: FaceData(coordinates: nil, confidence: nil, note: nil),
            vitals: [
                "heart_rate": Vital(value: 72.0, confidence: 1.0, unit: "bpm"),
                "hrv_sdnn": Vital(value: 50.0, confidence: 0.8, unit: "ms"),
                "sbp": Vital(value: 120.0, confidence: 0.9, unit: "mmHg")
            ],
            waveforms: [:],
            time: [1.0]
        )
        
        XCTAssertNotNil(result.heartRate)
        XCTAssertEqual(result.heartRate?.value, 72.0)
        XCTAssertNotNil(result.hrvSdnn)
        XCTAssertEqual(result.hrvSdnn?.value, 50.0)
        XCTAssertNotNil(result.sbp)
        XCTAssertEqual(result.sbp?.value, 120.0)
        XCTAssertNil(result.respiratoryRate)
    }

    // MARK: - Encoding

    func testEncodingRoundTrip() throws {
        let original = VitalLensResult(
            face: FaceData(coordinates: [[0,0,1,1]], confidence: [1.0], note: "test"),
            vitals: ["heart_rate": Vital(value: 70, confidence: 1, unit: "bpm")],
            waveforms: ["ppg_waveform": Waveform(data: [0.1], confidence: [1.0], unit: nil, note: nil)],
            time: [1.0]
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoded = try JSONDecoder().decode(VitalLensResult.self, from: data)
        
        XCTAssertEqual(decoded.heartRate?.value, 70)
        XCTAssertEqual(decoded.ppg?.data.first, 0.1)
        XCTAssertEqual(decoded.face.note, "test")
    }
}