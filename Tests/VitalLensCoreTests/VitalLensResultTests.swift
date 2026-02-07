import XCTest
@testable import VitalLensCore

final class VitalLensResultTests: XCTestCase {
    
    // MARK: - Decoding Tests
    
    func testDynamicDecoding() throws {
        // A JSON blob simulating a response with:
        // 1. Standard PPG waveform
        // 2. A "Future" scalar array (sbp)
        // 3. Face data
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
                    "data": [120.0, 120.5, 121.0],
                    "confidence": [0.8, 0.8, 0.8],
                    "unit": "mmHg",
                    "note": "Experimental"
                }
            },
            "time": [1.0, 1.03, 1.06],
            "fps": 30.0,
            "message": "OK"
        }
        """.data(using: .utf8)!
        
        let result = try JSONDecoder().decode(VitalLensResult.self, from: json)
        
        // 1. Verify Standard Fields
        XCTAssertEqual(result.fps, 30.0)
        XCTAssertEqual(result.message, "OK")
        XCTAssertEqual(result.face.coordinates?.count, 1)
        
        // 2. Verify Known Accessor
        XCTAssertNotNil(result.ppg)
        XCTAssertEqual(result.ppg?.data.count, 3)
        // FIX: Cast Float? to Double for comparison
        XCTAssertEqual(Double(result.ppg?.data.first ?? 0), 0.5, accuracy: 0.001)
        
        // 3. Verify Dynamic Dictionary Access (The "SBP" field)
        XCTAssertNotNil(result.signals["sbp"])
        XCTAssertEqual(result.signals["sbp"]?.unit, "mmHg")
        // FIX: Cast Float? to Double for comparison
        XCTAssertEqual(Double(result.signals["sbp"]?.data.last ?? 0), 121.0, accuracy: 0.1)
    }
    
    func testMissingSignalsDoNotCrash() throws {
        // JSON with empty vital_signs
        let json = """
        {
            "face": { "coordinates": [], "confidence": [], "note": "" },
            "vital_signs": {},
            "time": [1.0]
        }
        """.data(using: .utf8)!
        
        let result = try JSONDecoder().decode(VitalLensResult.self, from: json)
        
        XCTAssertTrue(result.signals.isEmpty)
        XCTAssertNil(result.ppg)
        XCTAssertNil(result.heartRate)
    }
    
    // MARK: - UI Compatibility Tests
    
    func testScalarResultHelper() {
        // Case 1: Data exists
        let series = TimeSeries(
            data: [60, 61, 62],
            confidence: [0.9, 0.9, 0.95],
            unit: "bpm",
            note: "Test"
        )
        
        let scalar = series.latest
        XCTAssertNotNil(scalar)
        
        // FIX: Unwrap optional Double? to Double using ?? 0
        XCTAssertEqual(scalar?.value ?? 0, 62.0, accuracy: 0.01)
        XCTAssertEqual(scalar?.confidence ?? 0, 0.95, accuracy: 0.01)
        XCTAssertEqual(scalar?.unit, "bpm")
        
        // Case 2: Empty Data
        let emptySeries = TimeSeries(
            data: [],
            confidence: [],
            unit: "bpm",
            note: nil
        )
        XCTAssertNil(emptySeries.latest)
    }
    
    func testResultConvenienceAccessors() {
        // Manually construct result with signals dictionary
        var signals = [String: TimeSeries]()
        
        signals["heart_rate"] = TimeSeries(data: [72], confidence: [1.0], unit: "bpm", note: nil)
        signals["hrv_sdnn"] = TimeSeries(data: [50], confidence: [0.8], unit: "ms", note: nil)
        
        let result = VitalLensResult(
            face: FaceData(coordinates: nil, confidence: nil, note: nil),
            signals: signals,
            time: [1.0]
        )
        
        // Test helpers
        XCTAssertNotNil(result.heartRate)
        XCTAssertEqual(result.heartRate?.latest?.value, 72.0)
        
        XCTAssertNotNil(result.hrvSdnn)
        XCTAssertEqual(result.hrvSdnn?.latest?.value, 50.0)
        
        // Test missing
        XCTAssertNil(result.respiratoryRate)
    }
}