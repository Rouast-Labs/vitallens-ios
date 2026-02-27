import XCTest
@testable import VitalLens
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
            
            let expectedSampleCount = 630
            XCTAssertEqual(result.sampleCount, expectedSampleCount, "Sample count should be exactly 630")
            
            let faceCoords = try XCTUnwrap(result.face.coordinates, "Missing face coordinates")
            let faceConfs = try XCTUnwrap(result.face.confidence, "Missing face confidence scores")
            
            XCTAssertEqual(faceCoords.count, expectedSampleCount, "Face coordinates count must match sample count")
            XCTAssertEqual(faceConfs.count, expectedSampleCount, "Face confidence count must match sample count")
            
            if let firstBox = faceCoords.first {
                XCTAssertEqual(firstBox.count, 4, "Bounding box should contain exactly 4 coordinates [minX, minY, maxX, maxY]")
            }
            
            let hr = try XCTUnwrap(result.heartRate?.value, "Missing heart rate")
            print("[Integration] ❤️ Heart Rate: \(hr)")
            XCTAssertEqual(hr, 60.5, accuracy: 2.0)
            
            let rr = try XCTUnwrap(result.respiratoryRate?.value, "Missing respiratory rate")
            print("[Integration] 🫁 Resp Rate: \(rr)")
            XCTAssertEqual(rr, 12.0, accuracy: 1.5)
            
            let sdnn = try XCTUnwrap(result.hrvSdnn?.value, "Missing HRV SDNN")
            print("[Integration] 📈 HRV SDNN: \(sdnn)")
            XCTAssertEqual(sdnn, 65.0, accuracy: 10.0)
            
            let rmssd = try XCTUnwrap(result.hrvRmssd?.value, "Missing HRV RMSSD")
            print("[Integration] 📉 HRV RMSSD: \(rmssd)")
            XCTAssertEqual(rmssd, 65.0, accuracy: 10.0)
            
            if let ieRatio = result.vitals["ie_ratio"]?.value {
                print("[Integration] ⚖️ I:E Ratio: \(ieRatio)")
                XCTAssertEqual(ieRatio, 1.12, accuracy: 0.15)
            }

            let ppg = try XCTUnwrap(result.ppg, "Missing PPG waveform")
            XCTAssertGreaterThan(ppg.data.count, 0, "PPG waveform is empty")
            
            let resp = try XCTUnwrap(result.resp, "Missing Respiratory waveform")
            XCTAssertGreaterThan(resp.data.count, 0, "Respiratory waveform is empty")

            XCTAssertEqual(result.sampleCount, expectedSampleCount, "Sample count should be exactly 630")
            XCTAssertEqual(result.time.count, expectedSampleCount, "Time array length must match expected sample count")
            XCTAssertEqual(ppg.data.count, expectedSampleCount, "PPG data length must match expected sample count")
            XCTAssertEqual(resp.data.count, expectedSampleCount, "Resp data length must match expected sample count")
            
        } catch {
            XCTFail("❌ Integration Failed: \(error)")
        }
    }

    func testProcessSampleVideo_StreamingMode_EndToEnd() async throws {
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
        
        let passiveSource = PassiveSource()
        
        let client = VitalLens(
            apiKey: apiKey,
            method: "vitallens-2.0",
            source: passiveSource,
        )
        let fileSource = try await FileSource.from(url: videoURL)
        let nominalFPS = fileSource.nominalFrameRate
        let frameDuration = 1.0 / Double(nominalFPS)
        
        let stream = try await client.startStream()
        let expectation = XCTestExpectation(description: "Receive valid heart rate from streaming API")
        
        actor ResultCollector {
            var results: [VitalLensResult] = []
            func append(_ result: VitalLensResult) { results.append(result) }
            func count() -> Int { results.count }
            func last() -> VitalLensResult? { results.last }
        }
        let collector = ResultCollector()
        
        let streamTask = Task {
            var validHeartRatesReceived = 0
            
            for await result in stream {
                await collector.append(result)
                let currentHR = result.heartRate?.value ?? 0.0
                print("[Integration Stream] 🟢 Received Result Chunk - HR: \(currentHR)")
                
                XCTAssertNotNil(result.face.coordinates, "Streaming chunk should contain local face coordinates")
                XCTAssertNotNil(result.face.confidence, "Streaming chunk should contain API face confidence")
                
                if let coords = result.face.coordinates, let confs = result.face.confidence {
                    XCTAssertEqual(coords.count, confs.count, "Coordinate and confidence arrays must be synchronized in the stream")
                    XCTAssertEqual(coords.count, result.time.count, "Face data length must match the chunk's time array")
                }
                
                if currentHR > 0 {
                    validHeartRatesReceived += 1
                }
                
                if validHeartRatesReceived >= 2 {
                    expectation.fulfill()
                    break 
                }
            }
        }
        
        let injectTask = Task {
            var frameCount = 0
            for await frame in fileSource.frames() {
                if Task.isCancelled { break }
                
                passiveSource.inject(
                    buffer: frame.buffer,
                    orientation: fileSource.orientation,
                    isMirrored: false,
                    timestamp: Double(frameCount) * frameDuration
                )
                frameCount += 1
                
                try await Task.sleep(nanoseconds: UInt64(frameDuration * 1_000_000_000 / 2.0))
            }
        }
        
        await fulfillment(of: [expectation], timeout: 45.0)
        
        streamTask.cancel()
        injectTask.cancel()
        client.stopStream()
        
        let finalCount = await collector.count()
        XCTAssertGreaterThan(finalCount, 0, "Should have received streaming results.")
        
        if let lastResult = await collector.last() {
            let finalHR = lastResult.heartRate?.value ?? 0.0
            XCTAssertGreaterThan(finalHR, 0.0, "Streaming result should contain a calculated heart rate.")
            XCTAssertNotNil(lastResult.ppg?.data, "Streaming result should contain PPG waveform.")
            XCTAssertGreaterThan(lastResult.time.count, 0, "Time array should be populated.")
        }
    }
}
