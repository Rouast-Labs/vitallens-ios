import XCTest
import Accelerate
@testable import VitalLensCore

final class SignalOpsTests: XCTestCase {

    // MARK: - Test Helpers

    /// Generates a synthetic signal with customizable characteristics for testing.
    ///
    /// - Parameters:
    ///   - freq: Target frequency in Hz (e.g., 1.0 for 60 BPM).
    ///   - fs: Sampling rate in Hz.
    ///   - duration: Duration in seconds.
    ///   - noise: Amplitude of random noise (0.0 to 1.0 relative to signal).
    ///   - trend: Linear drift slope to add to the signal (e.g., 2.0 adds 2*t).
    ///   - harmonics: Optional list of (frequency multiplier, amplitude) tuples to simulate complex waveforms.
    ///   - nanIndices: Specific indices to inject `NaN` values to test robustness.
    /// - Returns: An array of floats representing the generated signal.
    private func generateSignal(
        freq: Float,
        fs: Float,
        duration: Float,
        noise: Float = 0.0,
        trend: Float = 0.0,
        harmonics: [(Float, Float)] = [],
        nanIndices: [Int] = []
    ) -> [Float] {
        let count = Int(fs * duration)
        var signal = [Float]()
        signal.reserveCapacity(count)
        
        for i in 0..<count {
            let t = Float(i) / fs
            
            // 1. Fundamental Frequency
            var val = sin(2 * Float.pi * freq * t)
            
            // 2. Harmonics
            for (mult, amp) in harmonics {
                val += amp * sin(2 * Float.pi * (freq * mult) * t)
            }
            
            // 3. Noise
            let n = Float.random(in: -1...1) * noise
            
            // 4. Trend
            let drift = trend * t
            
            signal.append(val + n + drift)
        }
        
        // 5. Corruption
        for idx in nanIndices where idx < signal.count {
            signal[idx] = Float.nan
        }
        
        return signal
    }

    // MARK: - 1. Preprocessing (Standardize)

    func testStandardizeNormal() {
        let input: [Float] = [10, 20, 30, 40, 50]
        let result = SignalOps.standardize(input)
        
        let mean = result.reduce(0, +) / Float(result.count)
        let sumSq = result.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        let std = sqrt(sumSq / Float(result.count))
        
        XCTAssertEqual(mean, 0.0, accuracy: 0.001)
        XCTAssertEqual(std, 1.0, accuracy: 0.001)
    }

    func testStandardizeFlatline() {
        // vDSP_normalize can fail on variance=0.
        // The implementation should handle this via the stdDev check.
        let input: [Float] = [5, 5, 5, 5, 5]
        let result = SignalOps.standardize(input)
        XCTAssertEqual(result, [0, 0, 0, 0, 0])
        XCTAssertFalse(result.contains { $0.isNaN })
    }

    func testStandardizeNaNs() {
        // Test robustness against single-frame corruption
        let input: [Float] = [1, 2, Float.nan, 4, 5]
        let result = SignalOps.standardize(input)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result, [0, 0, 0, 0, 0])
    }
    
    func testStandardizeNearFlatline() {
        // Signal with variance < 1e-6 should also be zeroed out to prevent noise amplification
        let input: [Float] = [1.0000001, 1.0000002, 1.0000001]
        let result = SignalOps.standardize(input)
        let sum = result.reduce(0, +)
        XCTAssertEqual(sum, 0.0, accuracy: 0.00001)
    }

    // MARK: - 2. Detrending (Drift Removal)

    func testDetrendRemovesLinearDrift() {
        let fs: Float = 30.0
        let trendSlope: Float = 10.0
        let signal = generateSignal(freq: 1.0, fs: fs, duration: 5.0, trend: trendSlope)
        
        // Verify trend exists in raw signal
        XCTAssertGreaterThan(signal.last!, signal.first! + 40.0)
        
        let result = SignalOps.detrend(signal, fs: fs)
        
        // Verify trend is removed by comparing start/end means
        let sliceSize = Int(Float(result.count) * 0.1)
        let startMean = result.prefix(sliceSize).reduce(0, +) / Float(sliceSize)
        let endMean = result.suffix(sliceSize).reduce(0, +) / Float(sliceSize)
        
        // They should be roughly centered around 0 now
        XCTAssertEqual(startMean, endMean, accuracy: 1.0)
    }

    // MARK: - 3. Rate Estimation (FFT)

    func testEstimateRateClean() {
        let fs: Float = 30.0
        let signal = generateSignal(freq: 1.5, fs: fs, duration: 10.0)
        let rate = SignalOps.estimateRate(from: signal, fs: fs, minRate: 40, maxRate: 200)
        XCTAssertEqual(rate!, 90.0, accuracy: 1.0)
    }

    func testEstimateRateWithNoise() {
        // 90 BPM with 50% noise amplitude
        let fs: Float = 30.0
        let signal = generateSignal(freq: 1.5, fs: fs, duration: 10.0, noise: 0.5)
        let rate = SignalOps.estimateRate(from: signal, fs: fs, minRate: 40, maxRate: 200)
        
        XCTAssertNotNil(rate)
        XCTAssertEqual(rate!, 90.0, accuracy: 3.0)
    }
    
    func testEstimateRateHarmonics() {
        // 50 BPM (0.83 Hz) with weak 100 BPM harmonic
        let fs: Float = 30.0
        let signal = generateSignal(
            freq: 0.833,
            fs: fs,
            duration: 10.0,
            harmonics: [(2.0, 0.5)]
        )
        
        let rate = SignalOps.estimateRate(from: signal, fs: fs, minRate: 40, maxRate: 200)
        XCTAssertEqual(rate!, 50.0, accuracy: 2.0)
    }

    func testEstimateRateAliasingProtection() {
        // High frequency noise (20Hz) should not alias into valid HR range
        let fs: Float = 30.0
        let signal = generateSignal(freq: 20.0, fs: fs, duration: 5.0)
        
        let rate = SignalOps.estimateRate(from: signal, fs: fs, minRate: 40, maxRate: 200)
        XCTAssertNil(rate, "FFT picked up aliased high-freq noise as a valid heart rate")
    }

    // MARK: - 4. Peak Detection & Physiological Checks

    func testFindPeaksWithNoise() {
        let fs: Float = 30.0
        var signal = [Float](repeating: 0.0, count: 300)
        
        // Add Baseline Noise
        for i in 0..<300 { signal[i] = Float.random(in: -0.05...0.05) }
        
        // Add Peaks (Every 30 frames -> 60 BPM)
        let expectedPeaks = stride(from: 15, to: 300, by: 30).map { $0 }
        for idx in expectedPeaks {
            signal[idx] = 2.0
            // Make it a "shape"
            if idx > 0 { signal[idx-1] = 1.0 }
            if idx < 299 { signal[idx+1] = 1.0 }
        }
        
        let stdSignal = SignalOps.standardize(signal)
        let found = SignalOps.findPeaks(in: stdSignal, fs: fs, hr: 60)
        
        XCTAssertEqual(found.count, expectedPeaks.count)
        for (f, e) in zip(found, expectedPeaks) {
            XCTAssertLessThanOrEqual(abs(f - e), 1)
        }
    }

    func testFindPeaksRefractoryPeriod() {
        let fs: Float = 30.0
        var signal = [Float](repeating: 0, count: 60)
        
        // Valid Beat 1
        signal[10] = 5.0
        
        // Noise Beat (Only 5 frames later) -> Should be IGNORED by refractory logic
        signal[15] = 4.0
        
        // Valid Beat 2 (30 frames later) -> Should be KEPT
        signal[40] = 5.0
        
        let std = SignalOps.standardize(signal)
        let peaks = SignalOps.findPeaks(in: std, fs: fs, hr: 60)
        
        XCTAssertTrue(peaks.contains(10))
        XCTAssertFalse(peaks.contains(15))
        XCTAssertTrue(peaks.contains(40))
    }
    
    func testFindPeaksWithoutHRHint() {
        let fs: Float = 30.0
        var signal = [Float](repeating: 0, count: 60)
        signal[10] = 5.0
        signal[20] = 5.0 // 10 frames distance
        
        let std = SignalOps.standardize(signal)
        
        // With Hint: Reject (10 frames is too close for 60 BPM)
        let peaksHint = SignalOps.findPeaks(in: std, fs: fs, hr: 60)
        XCTAssertFalse(peaksHint.contains(20))
        
        // Without Hint: Accept (default max HR is higher)
        let peaksNoHint = SignalOps.findPeaks(in: std, fs: fs, hr: nil)
        XCTAssertTrue(peaksNoHint.contains(20))
    }

    // MARK: - 5. HRV (SDNN & RMSSD)

    func testSDNNRejectsOutliers() {
        let fs: Float = 10.0
        var peaks = [0, 10, 20, 30] // 1.0s intervals
        peaks.append(60)            // 3.0s interval (Outlier)
        peaks.append(70); peaks.append(80)
        
        let sdnn = SignalOps.calculateSDNN(peaks: peaks, fs: fs)
        
        // If outlier is filtered, variance is 0 -> SDNN is 0.
        XCTAssertNotNil(sdnn)
        XCTAssertEqual(sdnn!, 0.0, accuracy: 0.1)
    }

    func testRMSSDRequiresMinimumIntervals() {
        let fs: Float = 30.0
        // 2 Peaks = 1 Interval -> Not enough
        XCTAssertNil(SignalOps.calculateRMSSD(peaks: [10, 40], fs: fs))
        // 3 Peaks = 2 Intervals -> Enough
        XCTAssertNotNil(SignalOps.calculateRMSSD(peaks: [10, 40, 70], fs: fs))
    }
    
    func testSDNNKnownVariance() {
        // Peaks: 0, 30, 50 (Intervals: 3.0s, 2.0s)
        // Mean = 2.5. Std = 0.5. SDNN = 0.5 * 1000 = 500ms.
        let fs: Float = 10.0
        let peaks = [0, 30, 50]
        let sdnn = SignalOps.calculateSDNN(peaks: peaks, fs: fs)
        XCTAssertEqual(sdnn!, 500.0, accuracy: 1.0)
    }
}