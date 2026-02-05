import XCTest
@testable import VitalLens

final class SignalOpsTests: XCTestCase {

    func testStandardize() {
        let input: [Float] = [10, 20, 30, 40, 50]
        let result = SignalOps.standardize(input)
        
        // Mean should be ~0, StdDev ~1
        let mean = result.reduce(0, +) / Float(result.count)
        
        // Calculate variance
        let variance = result.map { pow($0 - mean, 2) }.reduce(0, +) / Float(result.count)
        
        XCTAssertEqual(mean, 0, accuracy: 0.001)
        XCTAssertEqual(variance, 1, accuracy: 0.001)
    }

    func testEstimateRateWithSineWave() {
        // Generate a 1Hz sine wave at 30fps (60 BPM)
        let fs: Float = 30.0
        let duration: Float = 10.0 // 10 seconds
        let count = Int(fs * duration)
        let frequency: Float = 1.0 // 1 Hz = 60 BPM
        
        var signal: [Float] = []
        for i in 0..<count {
            let t = Float(i) / fs
            signal.append(sin(2 * .pi * frequency * t))
        }
        
        // Run Estimation
        let rate = SignalOps.estimateRate(from: signal, fs: fs, minRate: 40, maxRate: 200)
        
        // FFT bin resolution is fs/N = 30/4096 = ~0.007 Hz (~0.4 BPM)
        // We expect exactly 60 BPM
        XCTAssertNotNil(rate)
        XCTAssertEqual(rate!, 60.0, accuracy: 0.5)
    }
    
    func testPeakDetection() {
        // Create a signal with peaks exactly every 30 samples (1 sec at 30fps)
        let fs: Float = 30.0
        var signal = [Float](repeating: 0.0, count: 300)
        
        // Insert spikes
        for i in stride(from: 10, to: 300, by: 30) {
            signal[i] = 10.0 // Huge spike
        }
        
        // We hint the HR is 60 BPM so it picks reasonable window sizes
        let peaks = SignalOps.findPeaks(in: signal, fs: fs, hr: 60)
        
        // We expect peaks at 10, 40, 70...
        // Total peaks in 300 samples (10 seconds) should be ~10
        XCTAssertEqual(peaks.count, 10)
        XCTAssertEqual(peaks.first, 10)
        XCTAssertEqual(peaks[1], 40)
    }
}