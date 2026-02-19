import XCTest
import SwiftUI
@testable import VitalLensInference

final class VitalRegistryTests: XCTestCase {
    
    func testKnownVitalLookup() {
        let registry = VitalRegistry.shared
        
        // Test standard scalar vital (Heart Rate)
        let hr = registry.getMeta(for: "heart_rate")
        XCTAssertEqual(hr.displayName, "Heart Rate")
        XCTAssertEqual(hr.unit, "bpm")
        XCTAssertEqual(hr.color, .red)
        // Heart rate itself is a stream of values, so we average it or take latest.
        // It is NOT derived via FFT (PPG is derived via FFT to get HR).
        XCTAssertEqual(hr.derivation, .average)
        
        // Test Source Signal (PPG Waveform)
        let ppg = registry.getMeta(for: "ppg_waveform")
        XCTAssertEqual(ppg.derivation, .rateFromFFT)
        XCTAssertNotNil(ppg.frequencyBounds)
    }
    
    func testFutureVitalFallback() {
        let registry = VitalRegistry.shared
        
        // Simulate API sending a new vital we've never seen
        let key = "skin_temperature_celsius"
        let meta = registry.getMeta(for: key)
        
        // 1. Check ID retention
        XCTAssertEqual(meta.id, key)
        
        // 2. Check Intelligent Naming (snake_case -> Title Case)
        XCTAssertEqual(meta.displayName, "Skin Temperature Celsius")
        
        // 3. Check Defaults
        XCTAssertEqual(meta.unit, "") // Default unit
        XCTAssertEqual(meta.color, .gray) // Default color
        XCTAssertEqual(meta.derivation, .average) // Default derivation
    }
    
    func testHardcodedFutureProofing() {
        // We manually added SBP support even though the API doesn't send it yet.
        // Ensure it's retrieved correctly.
        let registry = VitalRegistry.shared
        let sbp = registry.getMeta(for: "sbp")
        
        XCTAssertEqual(sbp.displayName, "Systolic BP")
        XCTAssertEqual(sbp.unit, "mmHg")
        XCTAssertEqual(sbp.derivation, .average)
    }
}