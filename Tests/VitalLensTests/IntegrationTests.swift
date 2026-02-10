import XCTest
import VitalLens
import VitalLensCore

final class IntegrationTests: XCTestCase {

    func testProcessSampleVideo_EndToEnd() async throws {
        // 1. Fail fast if the environment is not configured for this test
        // This ensures the test fails by default if you forget the Env Vars.
        guard ProcessInfo.processInfo.environment["VITALLENS_BASE_URL"] != nil else {
            XCTFail("❌ Skipped: VITALLENS_BASE_URL not set. Set this in your Scheme to run integration tests.")
            return
        }
        
        guard ProcessInfo.processInfo.environment["VITALLENS_API_KEY"] != nil else {
            XCTFail("❌ Skipped: VITALLENS_API_KEY not set. Set this in your Scheme to run integration tests.")
            return
        }

        // 2. Locate the real video file
        guard let videoURL = Bundle.module.url(forResource: "sample_video_2", withExtension: "mp4") else {
            XCTFail("❌ Could not find 'sample_video_2.mp4'. Ensure it is in Tests/VitalLensTests/Resources/ and declared in Package.swift.")
            return
        }
        
        print("[Integration] Video found: \(videoURL.lastPathComponent)")

        // 3. Initialize Client
        // We pass NO arguments. The Client automatically picks up the Env Vars.
        // We use .vitalLens2 to ensure we test the latest pipeline.
        let client = VitalLens(method: .vitalLens2)
        
        // 4. Run Processing
        do {
            let result = try await client.processVideoFile(at: videoURL)

            print("[Integration] ✅ API Response: \(result.message ?? "OK")")
            
            // 5. Verify Results
            XCTAssertEqual(result.fps ?? 0.0, 30.0, accuracy: 1.0)
            XCTAssertFalse(result.signals.isEmpty)
            
            let faceCount = result.face.boundingBoxes.count
            XCTAssertGreaterThan(faceCount, 0, "Vision should detect face in sample video")
            
            if let hr = result.heartRate?.latest?.value {
                print("[Integration] ❤️ Heart Rate: \(hr)")
                XCTAssertGreaterThan(hr, 40)
            } else {
                XCTFail("No heart rate returned from API")
            }
            
        } catch {
            XCTFail("❌ Integration Failed: \(error.localizedDescription)")
        }
    }
}
