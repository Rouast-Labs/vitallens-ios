import XCTest
@testable import VitalLensInference

final class VitalLensResultTests: XCTestCase {
    
    // MARK: - Standard Decoding
    
    func testDynamicDecoding() throws {
        // Simulates a V3 API response
        let json = """
        {
            "face": {
                "coordinates": [[0.1, 0.1, 0.2, 0.2]],
                "confidence": [0.99],
                "note": "Face found"
            },
            "vital_signs": {
                "ppg_waveform": {
                    "data": [0.5, 0.6, 0.7],
                    "confidence": [1.0, 1.0, 1.0],
                    "unit": "unitless",
                    "note": ""
                },
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
        
        // 1. Verify Standard Fields
        XCTAssertEqual(result.fps, 30.0)
        XCTAssertEqual(result.message, "OK")
        XCTAssertEqual(result.modelUsed, "vitallens_v3_hybrid")
        XCTAssertEqual(result.sampleCount, 3)
        XCTAssertEqual(result.face.coordinates?.count, 1)
        
        // 2. Verify Known Accessor (PPG)
        XCTAssertNotNil(result.ppg)
        XCTAssertEqual(result.ppg?.data.count, 3)
        
        let ppgFirst = Double(result.ppg?.data.first ?? 0)
        XCTAssertEqual(ppgFirst, 0.5, accuracy: 0.001)
        
        // 3. Verify Dynamic Dictionary Access (SBP)
        XCTAssertNotNil(result.vitals["sbp"])
        XCTAssertEqual(result.vitals["sbp"]?.unit, "mmHg")
        XCTAssertEqual(result.vitals["sbp"]?.value ?? 0, 121.0, accuracy: 0.1)
    }
    
    // MARK: - State Decoding (New & Critical)
    
    func testStateDecoding_Polymorphic() throws {
        // Case 1: API returns State as Base64 String (Standard Stream)
        let jsonStringState = """
        {
            "face": {}, "signals": {}, "time": [],
            "state": { "data": "SGVsbG8=" }
        }
        """.data(using: .utf8)!
        
        let result1 = try JSONDecoder().decode(VitalLensResult.self, from: jsonStringState)
        XCTAssertEqual(result1.state?.data, "SGVsbG8=")
        
        // Case 2: API returns State as Float Array (File/Debug Mode)
        // [0.0, 0.0] -> 8 bytes of zeros -> Base64: "AAAAAAAAAAA="
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
            "vital_signs": {},
            "time": [1.0]
        }
        """.data(using: .utf8)!
        
        let result = try JSONDecoder().decode(VitalLensResult.self, from: json)
        
        XCTAssertTrue(result.vitals.isEmpty)
        XCTAssertTrue(result.waveforms.isEmpty)
        XCTAssertNil(result.ppg)
        XCTAssertNil(result.heartRate)
    }
    
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

    func testVitalCustomDecoding_Defaults() throws {
        // Verifies that the custom Vital decoder handles missing fields gracefully
        let json = "{\"value\": 75.0}".data(using: .utf8)!
        let vital = try JSONDecoder().decode(Vital.self, from: json)
        
        XCTAssertEqual(vital.value, 75.0)
        XCTAssertEqual(vital.confidence, 0.0, "Missing confidence should default to 0")
        XCTAssertEqual(vital.unit, "", "Missing unit should default to empty string")
    }

    func testWaveformDecoding() throws {
        // Verifies standard array-based decoding for the Waveform struct
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

    // MARK: - Payload Routing

    func testPayloadRouting() throws {
        let json = """
        {
            "face": {}, "time": [],
            "vital_signs": {
                "stress_index": {
                    "value": 45.0,
                    "confidence": 0.8,
                    "unit": "pts"
                },
                "resp_signal": {
                    "data": [0.1, 0.2],
                    "confidence": [1.0, 1.0]
                }
            }
        }
        """.data(using: .utf8)!
        
        let result = try JSONDecoder().decode(VitalLensResult.self, from: json)
        
        // stress_index (object) -> result.vitals
        XCTAssertNotNil(result.vitals["stress_index"])
        XCTAssertEqual(result.vitals["stress_index"]?.value, 45.0)
        
        // resp_signal (array) -> result.waveforms
        XCTAssertNotNil(result.waveforms["resp_signal"])
        XCTAssertEqual(result.waveforms["resp_signal"]?.data.count, 2)
    }
}