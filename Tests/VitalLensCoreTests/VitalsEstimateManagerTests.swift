import XCTest
@testable import VitalLensCore

final class VitalsEstimateManagerTests: XCTestCase {
    
    // MARK: - Helpers
    
    /// Creates a dummy config for testing.
    /// FPS is set to 1.0 to make manual time calculations easier.
    let config = ModelConfig(
        nInputs: 4,
        inputSize: 40,
        fpsTarget: 1.0,
        roiMethod: "face",
        supportedVitals: ["heart_rate", "ppg_waveform"]
    )
    
    /// Helper to create a synthetic result chunk.
    func makeChunk(
        times: [Double],
        ppg: [Float]? = nil,
        ppgConf: [Float]? = nil,
        faceCoords: [[Double]]? = nil
    ) -> VitalLensResult {
        let count = times.count
        
        // Default PPG: [1, 2, 3...]
        let ppgData = ppg?.map { Double($0) } ?? (0..<count).map { Double($0 + 1) }
        // Default Conf: [1.0, 1.0...]
        let confData = ppgConf?.map { Double($0) } ?? Array(repeating: 1.0, count: count)
        
        let ppgWave = WaveformMetric(data: ppgData, unit: "unitless", confidence: confData, note: nil)
        
        let vitals = VitalSigns(
            heartRate: nil, respiratoryRate: nil,
            hrvSdnn: nil, hrvRmssd: nil, hrvLfhf: nil,
            ppgWaveform: ppgWave,
            respiratoryWaveform: nil // Simpler to just test PPG, logic is shared
        )
        
        let face = FaceData(
            coordinates: faceCoords,
            confidence: faceCoords != nil ? Array(repeating: 0.9, count: count) : nil,
            note: nil
        )
        
        return VitalLensResult(
            face: face,
            vitalSigns: vitals,
            time: times
        )
    }
    
    // MARK: - 1. Soft Stitching (Averaging) Tests
    
    func testSoftStitchingAveragesOverlap() async {
        let manager = VitalsEstimateManager()
        
        // Chunk 1: [1.0, 2.0, 3.0]
        // Values:  [10,  20,  30 ]
        let chunk1 = makeChunk(times: [1.0, 2.0, 3.0], ppg: [10, 20, 30])
        _ = await manager.process(chunk: chunk1, mode: .complete, config: config)
        
        // Chunk 2: [2.0, 3.0, 4.0] (Overlaps 2.0 and 3.0)
        // Values:  [22,  34,  40 ]
        // Expected Average at 2.0: (20 + 22) / 2 = 21
        // Expected Average at 3.0: (30 + 34) / 2 = 32
        // Expected Value at 4.0:   40
        let chunk2 = makeChunk(times: [2.0, 3.0, 4.0], ppg: [22, 34, 40])
        let result = await manager.process(chunk: chunk2, mode: .complete, config: config)
        
        XCTAssertEqual(result.time, [1.0, 2.0, 3.0, 4.0])
        
        let ppg = result.vitalSigns.ppgWaveform!.data
        XCTAssertEqual(ppg.count, 4)
        
        XCTAssertEqual(ppg[0], 10.0, accuracy: 0.01)
        XCTAssertEqual(ppg[1], 21.0, accuracy: 0.01) // Averaged
        XCTAssertEqual(ppg[2], 32.0, accuracy: 0.01) // Averaged
        XCTAssertEqual(ppg[3], 40.0, accuracy: 0.01) // New
    }
    
    func testStitchingDisjointChunks() async {
        let manager = VitalsEstimateManager()
        
        let chunk1 = makeChunk(times: [1.0, 2.0], ppg: [10, 20])
        _ = await manager.process(chunk: chunk1, mode: .complete, config: config)
        
        // Gap in time (3.0, 4.0)
        let chunk2 = makeChunk(times: [3.0, 4.0], ppg: [30, 40])
        let result = await manager.process(chunk: chunk2, mode: .complete, config: config)
        
        XCTAssertEqual(result.time, [1.0, 2.0, 3.0, 4.0])
        XCTAssertEqual(result.vitalSigns.ppgWaveform!.data, [10, 20, 30, 40])
    }
    
    func testStitchingIdenticalChunkIsNoOp() async {
        let manager = VitalsEstimateManager()
        
        let chunk1 = makeChunk(times: [1.0, 2.0], ppg: [10, 20])
        _ = await manager.process(chunk: chunk1, mode: .complete, config: config)
        
        // Send exactly the same chunk again
        let result = await manager.process(chunk: chunk1, mode: .complete, config: config)
        
        XCTAssertEqual(result.time.count, 2)
        // Averages with itself, so values shouldn't change
        XCTAssertEqual(result.vitalSigns.ppgWaveform!.data, [10, 20])
    }
    
    // MARK: - 2. Output Mode Tests
    
    func testIncrementalMode() async {
        let manager = VitalsEstimateManager()
        
        // 1. Process initial chunk
        let chunk1 = makeChunk(times: [1.0, 2.0, 3.0])
        let res1 = await manager.process(chunk: chunk1, mode: .incremental, config: config)
        
        XCTAssertEqual(res1.time, [1.0, 2.0, 3.0])
        
        // 2. Process overlap chunk
        // Overlap: 2.0, 3.0. New: 4.0
        let chunk2 = makeChunk(times: [2.0, 3.0, 4.0])
        let res2 = await manager.process(chunk: chunk2, mode: .incremental, config: config)
        
        // Incremental should ONLY return the *new* data point (4.0)
        // It should NOT return 2.0 or 3.0, even though they were updated internally
        XCTAssertEqual(res2.time, [4.0])
        XCTAssertEqual(res2.vitalSigns.ppgWaveform!.data.count, 1)
    }
    
    func testWindowedMode() async {
        let manager = VitalsEstimateManager()
        
        // Add 10 seconds of data (0.0 to 9.0)
        var times: [Double] = []
        for i in 0..<10 { times.append(Double(i)) }
        let chunk1 = makeChunk(times: times)
        
        // Request 3 second window
        let res1 = await manager.process(chunk: chunk1, mode: .windowed(seconds: 3), config: config)
        
        // Should get [7.0, 8.0, 9.0]
        XCTAssertEqual(res1.time.count, 3)
        XCTAssertEqual(res1.time.first!, 7.0)
        XCTAssertEqual(res1.time.last!, 9.0)
        
        // Add new data [9.0, 10.0, 11.0]
        let chunk2 = makeChunk(times: [9.0, 10.0, 11.0])
        let res2 = await manager.process(chunk: chunk2, mode: .windowed(seconds: 3), config: config)
        
        // Should get [9.0, 10.0, 11.0]
        XCTAssertEqual(res2.time, [9.0, 10.0, 11.0])
    }
    
    func testCompleteMode() async {
        let manager = VitalsEstimateManager()
        
        let chunk1 = makeChunk(times: [1.0])
        _ = await manager.process(chunk: chunk1, mode: .complete, config: config)
        
        let chunk2 = makeChunk(times: [2.0])
        let res2 = await manager.process(chunk: chunk2, mode: .complete, config: config)
        
        XCTAssertEqual(res2.time, [1.0, 2.0])
    }
    
    // MARK: - 3. Pruning Tests
    
    func testPruningKeepsInternalHistory() async {
        let manager = VitalsEstimateManager()
        
        // Max internal history is 1800. Add 2000 frames.
        var times: [Double] = []
        for i in 0..<2000 { times.append(Double(i)) }
        let chunk = makeChunk(times: times)
        
        // Process in .incremental mode.
        // The manager should prune the buffer to 1800 items BEFORE returning the result.
        let result = await manager.process(chunk: chunk, mode: .incremental, config: config)
        
        XCTAssertEqual(result.time.count, 1800, "Should be capped at max internal history immediately")
        
        // Add 1 more frame.
        let chunk2 = makeChunk(times: [2000.0])
        let res2 = await manager.process(chunk: chunk2, mode: .incremental, config: config)
        
        // Result has 1 frame (the new one).
        XCTAssertEqual(res2.time, [2000.0])
        
        // Verify internal state matches the cap.
        // Switching to .complete should return exactly 1800 frames ending at 2000.0.
        let res3 = await manager.process(chunk: makeChunk(times: []), mode: .complete, config: config)
        
        XCTAssertEqual(res3.time.count, 1800)
        XCTAssertEqual(res3.time.last!, 2000.0)
        // First item should be 2000 - 1800 + 1 = 201.0
        XCTAssertEqual(res3.time.first!, 201.0)
    }
    
    // MARK: - 4. Estimation Tests (Integration)
    
    func testEstimationCalculatesHR() async {
        let manager = VitalsEstimateManager()
        // 30 FPS config
        let highFPSConfig = ModelConfig(nInputs: 4, inputSize: 40, fpsTarget: 30, roiMethod: "face", supportedVitals: ["heart_rate"])
        
        // Generate a 1Hz sine wave (60 BPM) for 10 seconds (300 frames)
        var times: [Double] = []
        var ppg: [Float] = []
        
        for i in 0..<300 {
            let t = Double(i) / 30.0
            times.append(t)
            ppg.append(Float(sin(2 * .pi * 1.0 * t)))
        }
        
        let chunk = makeChunk(times: times, ppg: ppg)
        
        let result = await manager.process(chunk: chunk, mode: .complete, config: highFPSConfig)
        
        // Verify HR
        XCTAssertNotNil(result.vitalSigns.heartRate?.value)
        if let hr = result.vitalSigns.heartRate?.value {
            // Should be exactly 60, allow small tolerance for FFT window effects
            XCTAssertEqual(hr, 60.0, accuracy: 1.0)
        }
        
        // Verify Confidence Averaging
        // Chunk had default confidence 1.0
        XCTAssertEqual(result.vitalSigns.heartRate?.confidence ?? 0.0, 1.0, accuracy: 0.01)
    }
    
    func testInsufficientDataSkipsEstimation() async {
        let manager = VitalsEstimateManager()
        // 30 frames (Need 120 for HR)
        let chunk = makeChunk(times: (0..<30).map { Double($0)/30.0 })
        
        let result = await manager.process(chunk: chunk, mode: .complete, config: config)
        
        XCTAssertNil(result.vitalSigns.heartRate)
    }

    func testHRVThresholds() async {
        let manager = VitalsEstimateManager()
        // Config: 30 FPS
        
        // 1. Send 500 frames (Enough for HR (120), NOT enough for HRV (600))
        var times: [Double] = []
        var ppg: [Float] = []
        for i in 0..<500 {
            let t = Double(i)/30.0
            times.append(t)
            
            // Use sin^3 to sharpen peaks for robust detection (Crest factor > 1.5 sigma)
            let raw = sin(2 * .pi * 1.0 * t + 0.1) // 60 BPM + phase offset
            ppg.append(Float(pow(raw, 3)))
        }
        
        let chunk1 = makeChunk(times: times, ppg: ppg)
        let res1 = await manager.process(chunk: chunk1, mode: .complete, config: config)
        
        // Should have HR now
        XCTAssertNotNil(res1.vitalSigns.heartRate, "HR should be present > 120 frames")
        XCTAssertNil(res1.vitalSigns.hrvSdnn, "HRV should be nil < 600 frames")
        
        // 2. Send 200 more frames (Total 700 > 600)
        var times2: [Double] = []
        var ppg2: [Float] = []
        for i in 500..<700 {
            let t = Double(i)/30.0
            times2.append(t)
            let raw = sin(2 * .pi * 1.0 * t + 0.1)
            ppg2.append(Float(pow(raw, 3)))
        }
        
        let chunk2 = makeChunk(times: times2, ppg: ppg2)
        let res2 = await manager.process(chunk: chunk2, mode: .complete, config: config)
        
        XCTAssertNotNil(res2.vitalSigns.hrvSdnn, "HRV should be present > 600 frames")
    }
    
    // MARK: - 5. Face Data Tests (Hard Stitching)
    
    func testFaceDataHardStitching() async {
        let manager = VitalsEstimateManager()
        
        // Chunk 1: 2 frames, valid faces
        let chunk1 = makeChunk(
            times: [1.0, 2.0],
            faceCoords: [[10,10,50,50], [11,11,50,50]]
        )
        _ = await manager.process(chunk: chunk1, mode: .complete, config: config)
        
        // Chunk 2: Overlap [2.0, 3.0]
        // 2.0 in Chunk 2 has DIFFERENT coords than Chunk 1
        // Hard Stitching means we KEEP the old 2.0 data, and append the new 3.0 data.
        let chunk2 = makeChunk(
            times: [2.0, 3.0],
            faceCoords: [[99,99,50,50], [12,12,50,50]]
        )
        let result = await manager.process(chunk: chunk2, mode: .complete, config: config)
        
        let coords = result.face.boundingBoxes
        XCTAssertEqual(coords.count, 3)
        
        // Frame 1 (1.0): From Chunk 1
        XCTAssertEqual(coords[0].origin.x, 10.0)
        
        // Frame 2 (2.0): From Chunk 1 (First writer wins)
        // Should be 11, NOT 99
        XCTAssertEqual(coords[1].origin.x, 11.0)
        
        // Frame 3 (3.0): From Chunk 2
        XCTAssertEqual(coords[2].origin.x, 12.0)
    }
    
    func testFaceDataPadding() async {
        // Scenario: Signal data arrives, but face data is nil/empty for the new frames
        let manager = VitalsEstimateManager()
        
        let chunk = makeChunk(
            times: [1.0, 2.0],
            faceCoords: nil // No face data
        )
        
        let result = await manager.process(chunk: chunk, mode: .complete, config: config)
        
        // Should align arrays
        XCTAssertEqual(result.face.boundingBoxes.count, 2)
        XCTAssertEqual(result.face.confidence?.count, 2)
        
        // Should be empty/zero
        XCTAssertEqual(result.face.boundingBoxes[0], .zero)
        XCTAssertEqual(result.face.confidence?[0], 0.0)
    }
    
    // MARK: - 6. Reset
    
    func testReset() async {
        let manager = VitalsEstimateManager()
        
        let chunk = makeChunk(times: [1.0, 2.0, 3.0])
        _ = await manager.process(chunk: chunk, mode: .complete, config: config)
        
        await manager.reset()
        
        // Send a chunk that overlaps with previous history (if it wasn't cleared)
        let chunk2 = makeChunk(times: [3.0, 4.0])
        let result = await manager.process(chunk: chunk2, mode: .complete, config: config)
        
        // If reset worked, 3.0 is treated as new data, not overlap
        XCTAssertEqual(result.time.count, 2)
        XCTAssertEqual(result.time.first!, 3.0)
    }

    // MARK: - Edge Cases
    
    func testMismatchedArrayLengths() async {
        let manager = VitalsEstimateManager()
        
        // Scenario: API glitch where we get 5 timestamps but only 2 PPG points
        let times = [0.0, 1.0, 2.0, 3.0, 4.0]
        let ppgData = [10.0, 20.0] // Short!
        
        let ppgWave = WaveformMetric(data: ppgData, unit: "", confidence: [1.0, 1.0], note: nil)
        let vitals = VitalSigns(
            heartRate: nil, respiratoryRate: nil, hrvSdnn: nil, hrvRmssd: nil, hrvLfhf: nil,
            ppgWaveform: ppgWave,
            respiratoryWaveform: nil
        )
        
        let chunk = VitalLensResult(
            face: FaceData(coordinates: nil, confidence: nil, note: nil),
            vitalSigns: vitals,
            time: times
        )
        
        // Should not crash
        let result = await manager.process(chunk: chunk, mode: .complete, config: config)
        
        // Verify behavior: We expect the time to be full length
        XCTAssertEqual(result.time.count, 5)
        
        // And the PPG data should essentially stop where input stopped
        XCTAssertEqual(result.vitalSigns.ppgWaveform?.data.count, 2)
    }
    
    func testEffectiveFPSCalculation() async {
        let manager = VitalsEstimateManager()
        
        // Simulate 20 FPS (0.05s interval)
        // Send enough data (>= 60 frames) to trigger the FPS calc
        var times: [Double] = []
        for i in 0..<100 {
            times.append(Double(i) * 0.05)
        }
        
        let chunk = makeChunk(times: times)
        let result = await manager.process(chunk: chunk, mode: .complete, config: config)
        
        // Config says 1.0, but data says 20.0. Manager should trust data.
        XCTAssertEqual(result.fps ?? 0.0, 20.0, accuracy: 0.5)
    }

    func testTimestampPrecisionErrors() async {
        let manager = VitalsEstimateManager()
        
        // Chunk 1 ends exactly at 1.0
        let chunk1 = makeChunk(times: [1.0], ppg: [10])
        _ = await manager.process(chunk: chunk1, mode: .complete, config: config)
        
        // Chunk 2 starts at 1.000000001 (Micro-drift)
        // Strict equality would see this as a NEW frame, causing jitter. Epsilon logic handles it.
        let chunk2 = makeChunk(times: [1.000000001, 2.0], ppg: [10, 20])
        
        let result = await manager.process(chunk: chunk2, mode: .complete, config: config)
        
        // Should detect overlap and merge
        XCTAssertEqual(result.time.count, 2)
    }

    func testNaNHandlingInSignalMerge() async {
        let manager = VitalsEstimateManager()
        
        // Existing data
        let chunk1 = makeChunk(times: [1.0], ppg: [10.0])
        _ = await manager.process(chunk: chunk1, mode: .complete, config: config)
        
        // Incoming data has a NaN (e.g., lost tracking) overlapping our existing data
        let chunk2 = makeChunk(times: [1.0, 2.0], ppg: [Float.nan, 20.0])
        
        let result = await manager.process(chunk: chunk2, mode: .complete, config: config)
        let ppg = result.vitalSigns.ppgWaveform!.data
        
        // If we simply add/divide by count, 10 + NaN = NaN.
        // We must ensure the Manager or SignalBuffer ignores NaNs during merge.
        XCTAssertFalse(ppg[0].isNaN, "Merging a NaN should not corrupt existing valid history")
        XCTAssertEqual(ppg[0], 10.0, accuracy: 0.1)
    }

    func testJitteryTimestamps() async {
        let manager = VitalsEstimateManager()
        let jitterConfig = ModelConfig(nInputs: 4, inputSize: 40, fpsTarget: 30, roiMethod: "face", supportedVitals: ["heart_rate"])

        // Generate 120 frames with random jitter around 30 FPS (0.033s)
        var times: [Double] = []
        var ppg: [Float] = []
        var currentTime = 0.0
        
        for _ in 0..<120 {
            // Interval is 0.033 +/- 0.015
            let jitter = Double.random(in: -0.015...0.015)
            currentTime += (0.0333 + jitter)
            times.append(currentTime)
            ppg.append(Float(sin(2 * .pi * 1.0 * currentTime))) // 60 BPM
        }
        
        let chunk = makeChunk(times: times, ppg: ppg)
        let result = await manager.process(chunk: chunk, mode: .complete, config: jitterConfig)
        
        // Verify FPS calculation is roughly 30 despite jitter
        XCTAssertEqual(result.fps ?? 0, 30.0, accuracy: 5.0)
        
        // Verify Estimation still works (SignalOps usually handles non-uniform sampling via detrend/standardize assuming fs is average)
        XCTAssertNotNil(result.vitalSigns.heartRate?.value)
        XCTAssertEqual(result.vitalSigns.heartRate?.value ?? 0, 60.0, accuracy: 3.0)
    }
}