import XCTest
import VitalLens
import VitalLensInference

final class IntegrationTests: XCTestCase {

    func testProcessSampleVideo_EndToEnd() async throws {
        guard let baseURLString = ProcessInfo.processInfo.environment["VITALLENS_BASE_URL"],
              let url = URL(string: baseURLString) else {
            throw XCTSkip("❌ Skipped: VITALLENS_BASE_URL not set or invalid.")
        }
        
        guard let apiKey = ProcessInfo.processInfo.environment["VITALLENS_API_KEY"] else {
            throw XCTSkip("❌ Skipped: VITALLENS_API_KEY not set.")
        }

        // 2. Locate the real video file
        guard let videoURL = Bundle.module.url(forResource: "sample_video_2", withExtension: "mp4") else {
            XCTFail("❌ Could not find 'sample_video_2.mp4'.")
            return
        }
        
        print("[Integration] Video found: \(videoURL.lastPathComponent)")

        // 3. Initialize Client
        // We use the constructor that accepts the proxyURL and apiKey explicitly 
        // to ensure it uses the test environment variables.
        let client = VitalLens(
            apiKey: apiKey,
            method: .vitalLens2,
            proxyURL: url
        )
        
        // 4. Run Processing
        do {
            let result = try await client.processVideoFile(at: videoURL)

            print("[Integration] ✅ API Response: \(result.message ?? "Success")")
            print("[Integration] Model used: \(result.modelUsed ?? "unknown")")
            
            // 5. Verify Results
            XCTAssertEqual(result.fps ?? 0.0, 30.0, accuracy: 1.0)
            XCTAssertFalse(result.signals.isEmpty, "Result should contain signal data")
            
            // Verify Face Detection (coordinates are normalized [x, y, w, h])
            if let coordinates = result.face.coordinates {
                XCTAssertGreaterThan(coordinates.count, 0, "Should have face coordinates")
            }
            
            // Verify Heart Rate
            // Note: In VitalLensInference, 'heartRate' is a convenience property that 
            // looks for the "heart_rate" key in the signals dictionary.
            if let hrSignal = result.signals["heart_rate"], let hrValue = hrSignal.data.last {
                print("[Integration] ❤️ Heart Rate (Latest): \(hrValue) \(hrSignal.unit ?? "")")
                XCTAssertGreaterThan(hrValue, 40, "Heart rate should be in a realistic range")
            } else {
                XCTFail("No heart rate returned from API. Signals found: \(result.signals.keys)")
            }
            
            // Verify Timing
            XCTAssertGreaterThan(result.time.count, 0)
            if let count = result.sampleCount {
                XCTAssertEqual(result.time.count, Int(count))
            }
            
        } catch {
            XCTFail("❌ Integration Failed: \(error)")
        }
    }
}