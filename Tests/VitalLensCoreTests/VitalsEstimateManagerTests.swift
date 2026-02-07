import XCTest
@testable import VitalLensCore

final class VitalsEstimateManagerTests: XCTestCase {
    
    // Config: 1 FPS for easier manual time calculation
    let config = ModelConfig(
        nInputs: 4,
        inputSize: 40,
        fpsTarget: 1.0,
        roiMethod: "face",
        supportedVitals: ["heart_rate", "ppg_waveform"]
    )
    
    /// Helper to create a synthetic result chunk using the new dynamic structure
    func makeChunk(
        times: [Double],
        ppg: [Float]? = nil,
        ppgConf: [Float]? = nil,
        faceCoords: [[Double]]? = nil
    ) -> VitalLensResult {
        let count = times.count
        
        var signals = [String: TimeSeries]()
        
        // Create PPG Signal
        let ppgData = ppg ?? (0..<count).map { Float($0 + 1) }
        let confData = ppgConf ?? Array(repeating: 1.0, count: count)
        
        // NEW: Store in the signals map
        signals["ppg_waveform"] = TimeSeries(
            data: ppgData,
            confidence: confData,
            unit: "unitless",
            note: nil
        )
        
        let face = FaceData(
            coordinates: faceCoords,
            confidence: faceCoords != nil ? Array(repeating: 0.9, count: count) : nil,
            note: nil
        )
        
        // NEW: Use the dynamic initializer
        return VitalLensResult(
            face: face,
            signals: signals,
            time: times
        )
    }
    
    func testSoftStitchingAveragesOverlap() async {
        let manager = VitalsEstimateManager()
        
        let chunk1 = makeChunk(times: [1.0, 2.0, 3.0], ppg: [10, 20, 30])
        _ = await manager.process(chunk: chunk1, mode: .complete, config: config)
        
        let chunk2 = makeChunk(times: [2.0, 3.0, 4.0], ppg: [22, 34, 40])
        let result = await manager.process(chunk: chunk2, mode: .complete, config: config)
        
        XCTAssertEqual(result.time, [1.0, 2.0, 3.0, 4.0])
        
        // UPDATED: Access via .ppg convenience accessor
        guard let ppg = result.ppg?.data else { XCTFail("PPG missing"); return }
        
        XCTAssertEqual(ppg.count, 4)
        XCTAssertEqual(ppg[0], 10.0, accuracy: 0.01)
        XCTAssertEqual(ppg[1], 21.0, accuracy: 0.01) // Average of 20 and 22
        XCTAssertEqual(ppg[2], 32.0, accuracy: 0.01) // Average of 30 and 34
        XCTAssertEqual(ppg[3], 40.0, accuracy: 0.01)
    }
    
    func testStitchingDisjointChunks() async {
        let manager = VitalsEstimateManager()
        
        let chunk1 = makeChunk(times: [1.0, 2.0], ppg: [10, 20])
        _ = await manager.process(chunk: chunk1, mode: .complete, config: config)
        
        let chunk2 = makeChunk(times: [3.0, 4.0], ppg: [30, 40])
        let result = await manager.process(chunk: chunk2, mode: .complete, config: config)
        
        XCTAssertEqual(result.time, [1.0, 2.0, 3.0, 4.0])
        XCTAssertEqual(result.ppg!.data, [10, 20, 30, 40])
    }
    
    func testStitchingIdenticalChunkIsNoOp() async {
        let manager = VitalsEstimateManager()
        
        let chunk1 = makeChunk(times: [1.0, 2.0], ppg: [10, 20])
        _ = await manager.process(chunk: chunk1, mode: .complete, config: config)
        
        // Sending the exact same chunk again
        let result = await manager.process(chunk: chunk1, mode: .complete, config: config)
        
        XCTAssertEqual(result.time.count, 2)
        XCTAssertEqual(result.ppg!.data, [10, 20])
    }
    
    func testIncrementalMode() async {
        let manager = VitalsEstimateManager()
        
        let chunk1 = makeChunk(times: [1.0, 2.0, 3.0])
        let res1 = await manager.process(chunk: chunk1, mode: .incremental, config: config)
        
        XCTAssertEqual(res1.time, [1.0, 2.0, 3.0])
        
        let chunk2 = makeChunk(times: [2.0, 3.0, 4.0])
        let res2 = await manager.process(chunk: chunk2, mode: .incremental, config: config)
        
        // Should only return new data (time 4.0)
        XCTAssertEqual(res2.time, [4.0])
        XCTAssertEqual(res2.ppg!.data.count, 1)
    }
    
    func testWindowedMode() async {
        let manager = VitalsEstimateManager()
        
        var times: [Double] = []
        for i in 0..<10 { times.append(Double(i)) }
        let chunk1 = makeChunk(times: times)
        
        // Window 3 seconds
        let res1 = await manager.process(chunk: chunk1, mode: .windowed(seconds: 3), config: config)
        
        XCTAssertEqual(res1.time.count, 3)
        XCTAssertEqual(res1.time.first!, 7.0)
        XCTAssertEqual(res1.time.last!, 9.0)
        
        let chunk2 = makeChunk(times: [9.0, 10.0, 11.0])
        let res2 = await manager.process(chunk: chunk2, mode: .windowed(seconds: 3), config: config)
        
        XCTAssertEqual(res2.time, [9.0, 10.0, 11.0])
    }
    
    func testPruningKeepsInternalHistory() async {
        let manager = VitalsEstimateManager()
        
        var times: [Double] = []
        for i in 0..<2000 { times.append(Double(i)) }
        let chunk = makeChunk(times: times)
        
        let result = await manager.process(chunk: chunk, mode: .incremental, config: config)
        
        // Manager caps internal history at 1800
        XCTAssertEqual(result.time.count, 1800)
        
        let chunk2 = makeChunk(times: [2000.0])
        let res2 = await manager.process(chunk: chunk2, mode: .incremental, config: config)
        
        XCTAssertEqual(res2.time, [2000.0])
    }
    
    func testEstimationCalculatesHR() async {
        let manager = VitalsEstimateManager()
        
        let highFPSConfig = ModelConfig(nInputs: 4, inputSize: 40, fpsTarget: 30, roiMethod: "face", supportedVitals: ["heart_rate"])
        
        var times: [Double] = []
        var ppg: [Float] = []
        
        // Generate 10 seconds of 60 BPM sine wave
        for i in 0..<300 {
            let t = Double(i) / 30.0
            times.append(t)
            ppg.append(Float(sin(2 * .pi * 1.0 * t)))
        }
        
        let chunk = makeChunk(times: times, ppg: ppg)
        
        let result = await manager.process(chunk: chunk, mode: .complete, config: highFPSConfig)
        
        // UPDATED: Use .latest?.value for scalars
        XCTAssertNotNil(result.heartRate?.latest?.value)
        if let hr = result.heartRate?.latest?.value {
            XCTAssertEqual(hr, 60.0, accuracy: 1.0)
        }
        
        XCTAssertEqual(result.heartRate?.latest?.confidence ?? 0.0, 1.0, accuracy: 0.01)
    }
    
    func testInsufficientDataSkipsEstimation() async {
        let manager = VitalsEstimateManager()
        
        // Less than 4 seconds of data
        let chunk = makeChunk(times: (0..<30).map { Double($0)/30.0 })
        
        let result = await manager.process(chunk: chunk, mode: .complete, config: config)
        
        XCTAssertNil(result.heartRate)
    }

    func testHRVThresholds() async {
        let manager = VitalsEstimateManager()
        
        // 1. Generate enough for HR but not HRV (< 20s)
        var times: [Double] = []
        var ppg: [Float] = []
        for i in 0..<500 {
            let t = Double(i)/30.0
            times.append(t)
            let raw = sin(2 * .pi * 1.0 * t + 0.1)
            ppg.append(Float(pow(raw, 3)))
        }
        
        let chunk1 = makeChunk(times: times, ppg: ppg)
        let res1 = await manager.process(chunk: chunk1, mode: .complete, config: config)
        
        XCTAssertNotNil(res1.heartRate, "HR should be present > 120 frames")
        XCTAssertNil(res1.hrvSdnn, "HRV should be nil < 600 frames")
        
        // 2. Add more data to cross HRV threshold (> 20s)
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
        
        XCTAssertNotNil(res2.hrvSdnn, "HRV should be present > 600 frames")
        
        // Check value
        if let val = res2.hrvSdnn?.latest?.value {
            XCTAssertGreaterThan(val, 0)
        }
    }
    
    func testFaceDataPadding() async {
        let manager = VitalsEstimateManager()
        
        let chunk = makeChunk(
            times: [1.0, 2.0],
            faceCoords: nil // No face data provided
        )
        
        let result = await manager.process(chunk: chunk, mode: .complete, config: config)
        
        XCTAssertEqual(result.face.boundingBoxes.count, 2)
        XCTAssertEqual(result.face.confidence?.count, 2)
        
        // Padding should result in zero rects
        XCTAssertEqual(result.face.boundingBoxes[0], .zero)
        XCTAssertEqual(result.face.confidence?[0], 0.0)
    }
    
    func testUnknownVitalPassThrough() async {
        let manager = VitalsEstimateManager()
        
        // Manually construct a chunk with a "future" vital sign like "sbp"
        var signals = [String: TimeSeries]()
        signals["sbp"] = TimeSeries(data: [120, 122], confidence: [1.0, 1.0], unit: "mmHg", note: nil)
        
        let chunk = VitalLensResult(
            face: FaceData(coordinates: nil, confidence: nil, note: nil),
            signals: signals,
            time: [1.0, 2.0]
        )
        
        let result = await manager.process(chunk: chunk, mode: .complete, config: config)
        
        // The manager should preserve it, and calculate an average (since we added it to Registry)
        XCTAssertNotNil(result.signals["sbp"])
        
        // FIX: Coalesce the optional Double? to 0.0 so it matches the expected Double type
        XCTAssertEqual(result.signals["sbp"]?.latest?.value ?? 0.0, 121.0, accuracy: 0.1)
    }
    
    func testNaNHandlingInSignalMerge() async {
        let manager = VitalsEstimateManager()
        
        let chunk1 = makeChunk(times: [1.0], ppg: [10.0])
        _ = await manager.process(chunk: chunk1, mode: .complete, config: config)
        
        let chunk2 = makeChunk(times: [1.0, 2.0], ppg: [Float.nan, 20.0])
        
        let result = await manager.process(chunk: chunk2, mode: .complete, config: config)
        let ppg = result.ppg!.data
        
        // 10 + NaN should handle gracefully (ignored in merge logic)
        XCTAssertFalse(ppg[0].isNaN)
        XCTAssertEqual(ppg[0], 10.0, accuracy: 0.1)
        XCTAssertEqual(ppg[1], 20.0, accuracy: 0.1)
    }
}