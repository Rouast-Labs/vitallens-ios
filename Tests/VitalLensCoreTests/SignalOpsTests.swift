import XCTest
@testable import VitalLensCore

final class SignalOpsTests: XCTestCase {

    // MARK: - 1. Standardize Tests

    func testStandardizeNormal() {
        let input: [Float] = [10, 20, 30, 40, 50]
        let result = SignalOps.standardize(input)
        let mean = result.reduce(0, +) / Float(result.count)
        let variance = result.map { pow($0 - mean, 2) }.reduce(0, +) / Float(result.count)
        XCTAssertEqual(mean, 0.0, accuracy: 0.001)
        XCTAssertEqual(variance, 1.0, accuracy: 0.001)
    }

    func testStandardizeConstant() {
        let input: [Float] = [5, 5, 5, 5, 5]
        let result = SignalOps.standardize(input)
        XCTAssertEqual(result, [0, 0, 0, 0, 0])
    }

    func testStandardizeEmpty() {
        XCTAssertTrue(SignalOps.standardize([]).isEmpty)
    }

    // MARK: - 2. Detrend Tests

    func testDetrendDCRemoval() {
        let fs: Float = 30.0
        var signal: [Float] = []
        for i in 0..<300 {
            signal.append(sin(Float(i) * 0.1) + 100.0)
        }
        
        // Initial DC ~ 100
        XCTAssertEqual(signal.reduce(0, +) / Float(signal.count), 100.0, accuracy: 1.0)
        
        let result = SignalOps.detrend(signal, fs: fs)
        let postMean = result.reduce(0, +) / Float(result.count)
        
        // With improved initialization, mean should be very close to 0
        XCTAssertEqual(postMean, 0.0, accuracy: 0.1)
    }
    
    func testDetrendShortSignal() {
        let input: [Float] = [10.0]
        let result = SignalOps.detrend(input, fs: 30)
        XCTAssertEqual(result, input)
    }

    // MARK: - 3. Estimate Rate Tests

    func testEstimateRate60BPM() {
        let fs: Float = 30.0
        var signal: [Float] = []
        for i in 0..<300 {
            let t = Float(i) / fs
            signal.append(sin(2 * .pi * 1.0 * t))
        }
        let rate = SignalOps.estimateRate(from: signal, fs: fs, minRate: 40, maxRate: 200)
        XCTAssertEqual(rate!, 60.0, accuracy: 0.5)
    }
    
    func testEstimateRate120BPM() {
        let fs: Float = 30.0
        var signal: [Float] = []
        for i in 0..<300 {
            let t = Float(i) / fs
            signal.append(sin(2 * .pi * 2.0 * t))
        }
        let rate = SignalOps.estimateRate(from: signal, fs: fs, minRate: 40, maxRate: 200)
        XCTAssertEqual(rate!, 120.0, accuracy: 0.5)
    }
    
    func testEstimateRateOutOfBounds() {
        // 300 BPM = 5 Hz. Max allowed 200 (3.33Hz).
        let fs: Float = 30.0
        var signal: [Float] = []
        for i in 0..<300 {
            let t = Float(i) / fs
            signal.append(sin(2 * .pi * 5.0 * t))
        }
        
        let rate = SignalOps.estimateRate(from: signal, fs: fs, minRate: 40, maxRate: 200)
        
        // With Hanning window and local peak check, this should return nil
        // as the leakage into the valid range will not form a local peak.
        XCTAssertNil(rate)
    }

    // MARK: - 4. Peak Detection Tests

    func testFindPeaksPeriodic() {
        let fs: Float = 30.0
        var signal = [Float](repeating: 0.0, count: 300)
        let expectedPeaks = stride(from: 10, to: 300, by: 30).map { $0 }
        for idx in expectedPeaks {
            signal[idx] = 5.0
        }
        let found = SignalOps.findPeaks(in: signal, fs: fs, hr: 60)
        XCTAssertEqual(found, expectedPeaks)
    }
    
    func testFindPeaksEmpty() {
        let signal: [Float] = []
        let found = SignalOps.findPeaks(in: signal, fs: 30, hr: 60)
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: - 5. HRV (SDNN) Tests

    func testSDNNPerfectRhythm() {
        let peaks = [0, 30, 60, 90, 120]
        let sdnn = SignalOps.calculateSDNN(peaks: peaks, fs: 30.0)
        XCTAssertEqual(sdnn!, 0.0, accuracy: 0.001)
    }
    
    func testSDNNKnownVariance() {
        let peaks = [0, 30, 50]
        let fs: Float = 10.0
        let sdnn = SignalOps.calculateSDNN(peaks: peaks, fs: fs)
        XCTAssertEqual(sdnn!, 500.0, accuracy: 1.0)
    }
    
    func testSDNNInsufficientData() {
        let peaks2 = [0, 30] // 1 interval
        XCTAssertNil(SignalOps.calculateSDNN(peaks: peaks2, fs: 30))
        
        let peaks3 = [0, 30, 60] // 2 intervals
        XCTAssertNotNil(SignalOps.calculateSDNN(peaks: peaks3, fs: 30))
    }

    // MARK: - 6. HRV (RMSSD) Tests

    func testRMSSDPerfectRhythm() {
        let peaks = [0, 30, 60, 90]
        let rmssd = SignalOps.calculateRMSSD(peaks: peaks, fs: 30.0)
        XCTAssertEqual(rmssd!, 0.0, accuracy: 0.001)
    }
    
    func testRMSSDKnownValues() {
        let peaks = [0, 30, 65]
        let fs: Float = 10.0
        let rmssd = SignalOps.calculateRMSSD(peaks: peaks, fs: fs)
        XCTAssertEqual(rmssd!, 500.0, accuracy: 1.0)
    }
}