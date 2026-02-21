import XCTest
import VitalLens
import VitalLensInference

final class IntegrationTests: XCTestCase {

    func testProcessSampleVideo_EndToEnd() async throws {
        guard let baseURLString = ProcessInfo.processInfo.environment["VITALLENS_BASE_URL"],
              let _ = URL(string: baseURLString) else {
            throw XCTSkip("❌ Skipped: VITALLENS_BASE_URL not set or invalid.")
        }
        
        guard let apiKey = ProcessInfo.processInfo.environment["VITALLENS_API_KEY"] else {
            throw XCTSkip("❌ Skipped: VITALLENS_API_KEY not set.")
        }

        guard let videoURL = Bundle.module.url(forResource: "sample_video_2", withExtension: "mp4") else {
            XCTFail("❌ Could not find 'sample_video_2.mp4'.")
            return
        }
        
        let client = VitalLens(
            apiKey: apiKey,
            method: "vitallens-2.0"
        )
        
        do {
            let result = try await client.processVideoFile(at: videoURL)

            print("[Integration] ✅ API Response: \(result.message ?? "Success")")
            print("[Integration] Model used: \(result.modelUsed ?? "unknown")")
            
            XCTAssertEqual(result.fps ?? 0.0, 30.0, accuracy: 1.0)
            XCTAssertFalse(result.vitals.isEmpty && result.waveforms.isEmpty, "Result should contain vital or waveform data")
            
            if let coordinates = result.face.coordinates {
                XCTAssertGreaterThan(coordinates.count, 0, "Should have face coordinates")
            }
            
            let hr = try XCTUnwrap(result.heartRate?.value, "Missing heart rate")
            print("[Integration] ❤️ Heart Rate: \(hr)")
            XCTAssertEqual(hr, 60.5, accuracy: 2.0)
            
            let rr = try XCTUnwrap(result.respiratoryRate?.value, "Missing respiratory rate")
            print("[Integration] 🫁 Resp Rate: \(rr)")
            XCTAssertEqual(rr, 12.0, accuracy: 1.5)
            
            let sdnn = try XCTUnwrap(result.hrvSdnn?.value, "Missing HRV SDNN")
            print("[Integration] 📈 HRV SDNN: \(sdnn)")
            XCTAssertEqual(sdnn, 60.0, accuracy: 10.0)
            
            let rmssd = try XCTUnwrap(result.hrvRmssd?.value, "Missing HRV RMSSD")
            print("[Integration] 📉 HRV RMSSD: \(rmssd)")
            XCTAssertEqual(rmssd, 60.0, accuracy: 10.0)
            
            if let ieRatio = result.vitals["ie_ratio"]?.value {
                print("[Integration] ⚖️ I:E Ratio: \(ieRatio)")
                XCTAssertEqual(ieRatio, 1.12, accuracy: 0.15)
            }

            let ppg = try XCTUnwrap(result.ppg, "Missing PPG waveform")
            XCTAssertGreaterThan(ppg.data.count, 0, "PPG waveform is empty")
            
            let resp = try XCTUnwrap(result.resp, "Missing Respiratory waveform")
            XCTAssertGreaterThan(resp.data.count, 0, "Respiratory waveform is empty")

            let expectedSampleCount = 630
            XCTAssertEqual(result.sampleCount, expectedSampleCount, "Sample count should be exactly 630")
            XCTAssertEqual(result.time.count, expectedSampleCount, "Time array length must match expected sample count")
            XCTAssertEqual(ppg.data.count, expectedSampleCount, "PPG data length must match expected sample count")
            XCTAssertEqual(resp.data.count, expectedSampleCount, "Resp data length must match expected sample count")
            
        } catch {
            XCTFail("❌ Integration Failed: \(error)")
        }
    }
}
