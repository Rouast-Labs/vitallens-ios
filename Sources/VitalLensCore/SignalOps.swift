import Foundation
import Accelerate

/// A collection of stateless signal processing primitives using vDSP.
/// Optimized for x86_64 and ARM64 to prevent SIGILL by ensuring memory alignment
/// and avoiding dangerous floating-point instructions in loops.
public struct SignalOps {

    // MARK: - Constants
    public static let nfft = 4096

    /// Thread-safe, lazy FFT setup.
    nonisolated(unsafe) private static let fftProvider: vDSP.FFT<DSPSplitComplex>? = {
        let log2n = vDSP_Length(log2(Double(nfft)))
        return vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
    }()

    // MARK: - 1. Preprocessing

    public static func standardize(_ signal: [Float]) -> [Float] {
        guard !signal.isEmpty else { return [] }
        let count = signal.count
        
        var mean: Float = 0
        var stdDev: Float = 0
        var result = [Float](repeating: 0, count: count)
        
        // Optimization: Calculate stats and write normalized output in a single pass
        vDSP_normalize(signal, 1, &result, 1, &mean, &stdDev, vDSP_Length(count))
        
        // Safety check for flatlines or NaNs
        if stdDev < 1e-6 || stdDev.isNaN {
            return [Float](repeating: 0.0, count: count)
        }
        
        return result
    }

    public static func detrend(_ signal: [Float], fs: Float, cutoff: Float = 0.5) -> [Float] {
        guard signal.count > 1 else { return signal }
        let forward = efficientDetrend(signal, fs: fs, cutoff: cutoff)
        let backward = efficientDetrend(forward.reversed(), fs: fs, cutoff: cutoff)
        return Array(backward.reversed())
    }

    private static func efficientDetrend<S: Sequence>(_ signal: S, fs: Float, cutoff: Float) -> [Float] where S.Element == Float {
        let dt = 1.0 / fs
        let rc = 1.0 / (2.0 * Float.pi * cutoff)
        let alpha = rc / (rc + dt)
        
        // Optimization: Pre-allocate to avoid resize overhead
        var output = [Float]()
        output.reserveCapacity(signal.underestimatedCount)
        
        var lastOut: Float = 0.0
        var lastIn: Float = 0.0
        
        for (i, val) in signal.enumerated() {
            if i == 0 {
                output.append(0.0)
            } else {
                let out = alpha * (lastOut + val - lastIn)
                output.append(out)
                lastOut = out
            }
            lastIn = val
        }
        return output
    }

    // MARK: - 2. Rate Estimation (FFT)

    public static func estimateRate(from waveform: [Float], fs: Float, minRate: Float, maxRate: Float) -> Float? {
        guard let setup = fftProvider else { return nil }
        let fmin = minRate / 60.0
        let fmax = maxRate / 60.0
        return estimateFreq(waveform, fs: fs, nfft: nfft, fmin: fmin, fmax: fmax, fftSetUp: setup)
    }

    // MARK: - 3. Peak Detection (Adaptive Z-Score)

    public static func findPeaks(in signal: [Float], fs: Float, hr: Float?) -> [Int] {
        guard signal.count > 2 else { return [] }

        // 1. Configuration
        // Lag: Window size for moving average. Approx 1.5s is standard for rPPG.
        let lag = max(1, Int(round(fs * 1.5)))
        let thresholdSq: Float = 1.5 * 1.5 // Threshold = 1.5 std devs
        let height: Float = 0.0
        
        // Refractory Period: Minimum distance between peaks based on HR
        let minDistance: Int
        if let hr = hr, hr >= 40, hr <= 220 {
            // e.g. HR=60 -> 1s period. minDistance = 0.5s (15 frames @ 30fps)
            minDistance = Int(round((fs * 60.0) / hr * 0.5))
        } else {
            // Default conservative: assume max HR 220 -> ~270ms period
            minDistance = Int(round((fs * 60.0) / 220.0))
        }
        
        var detectedIndices = [Int]()
        
        // 2. Sliding Window Initialization (O(N) Approach)
        // We maintain a running Sum and SumSquares to calculate Mean/StdDev in O(1)
        var sum: Float = 0
        var sumSq: Float = 0
        
        // We pad the beginning with the first value (or 0) to "warm up" the lag window
        // For standard inputs (standardized signal), padding with 0 is safe.
        // To match the original logic exactly (padding with signal[0]), we do:
        let padVal = signal[0]
        
        // Initialize window state as if we processed `lag` frames of `padVal`
        sum = padVal * Float(lag)
        sumSq = (padVal * padVal) * Float(lag)
        
        let lagF = Float(lag)
        
        // 3. Iterate
        for i in 1..<(signal.count - 1) {
            let val = signal[i]
            
            // A. Update Rolling Stats
            // The stats correspond to the window ending at i-1 (indices [i-lag ... i-1])
            // Standard deviation calculation
            let mean = sum / lagF
            let variance = max(0, (sumSq / lagF) - (mean * mean))
            
            // B. Peak Check
            // Must be local maxima AND above Z-score threshold
            if val > signal[i-1] && val > signal[i+1] && val > height {
                let diff = val - mean
                if diff > 0 && (diff * diff) > (thresholdSq * variance) {
                    // Refractory check
                    if let last = detectedIndices.last {
                        if (i - last) >= minDistance {
                            detectedIndices.append(i)
                        }
                    } else {
                        detectedIndices.append(i)
                    }
                }
            }
            
            // C. Slide Window for Next Iteration (i+1)
            // Window moves from [i-lag...i-1] to [i-lag+1...i]
            // We remove the element at (i - lag) and add the element at (i)
            let leavingIndex = i - lag
            let leavingValue = (leavingIndex < 0) ? padVal : signal[leavingIndex]
            
            sum = sum - leavingValue + val
            sumSq = sumSq - (leavingValue * leavingValue) + (val * val)
        }
        
        // Removed the "minSequenceLength >= 3" logic.
        // A low-level signal op should return what it finds. 
        // Higher-level logic can filter short sequences if needed.
        return detectedIndices
    }

    // MARK: - 4. HRV Calculation

    public static func calculateSDNN(peaks: [Int], fs: Float) -> Double? {
        let intervals = calculateNNIntervals(peaks: peaks, fs: fs)
        // SDNN requires at least 2 intervals (3 peaks) to have a variance? 
        // Actually, stdDev requires N >= 2 data points. 
        // 2 peaks -> 1 interval. StdDev of 1 point is 0 (or undefined).
        // 3 peaks -> 2 intervals. StdDev is valid.
        guard intervals.count >= 2 else { return nil }
        
        var mean: Float = 0
        var stdDev: Float = 0
        // We use vDSP to calculate stdDev of the intervals
        vDSP_normalize(intervals, 1, nil, 1, &mean, &stdDev, vDSP_Length(intervals.count))
        
        return Double(stdDev * 1000.0) // Convert s to ms
    }

    public static func calculateRMSSD(peaks: [Int], fs: Float) -> Double? {
        let intervals = calculateNNIntervals(peaks: peaks, fs: fs)
        guard intervals.count >= 2 else { return nil }
        
        var sumSqDiff: Float = 0
        // RMSSD is root mean square of SUCCESSIVE differences
        // If we have 2 intervals, we have 1 diff. Valid.
        for i in 0..<(intervals.count - 1) {
            let diff = intervals[i+1] - intervals[i]
            sumSqDiff += (diff * diff)
        }
        
        let meanSqDiff = sumSqDiff / Float(intervals.count - 1)
        return Double(sqrt(meanSqDiff) * 1000.0)
    }

    private static func calculateNNIntervals(peaks: [Int], fs: Float) -> [Float] {
        guard peaks.count >= 2 else { return [] }
        var intervals: [Float] = []
        intervals.reserveCapacity(peaks.count - 1)
        
        for i in 0..<(peaks.count - 1) {
            intervals.append(Float(peaks[i+1] - peaks[i]) / fs)
        }
        return filterNNIntervals(intervals)
    }

    private static func filterNNIntervals(_ intervals: [Float], threshold: Float = 0.3) -> [Float] {
        // Need at least 3 intervals to establish a meaningful median for filtering
        guard intervals.count >= 3 else { return intervals }
        
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        
        // Reject intervals that deviate by >30% from median
        return intervals.filter { abs($0 - median) <= (median * threshold) }
    }

    // MARK: - Internal FFT Helpers

    private static func powerSpectrum(_ input: [Float], fs: Float, nfft: Int, fftSetUp: vDSP.FFT<DSPSplitComplex>) -> (magnitudes: [Float], frequencies: [Float]) {
        let count = input.count
        
        // Optimization: Cache window if possible, or use stack buffer for small N
        var window = [Float](repeating: 0, count: count)
        vDSP_hann_window(&window, vDSP_Length(count), Int32(vDSP_HANN_NORM))
        
        var windowedInput = [Float](repeating: 0, count: count)
        vDSP_vmul(input, 1, window, 1, &windowedInput, 1, vDSP_Length(count))
        
        let nhalf = nfft / 2
        var real = [Float](repeating: 0, count: nhalf)
        var imag = [Float](repeating: 0, count: nhalf)
        
        var paddedInput = windowedInput
        if count < nfft {
            paddedInput.append(contentsOf: [Float](repeating: 0.0, count: nfft - count))
        }

        return real.withUnsafeMutableBufferPointer { rPtr in
            imag.withUnsafeMutableBufferPointer { iPtr in
                var complex = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                
                // Pack real input into split complex format
                paddedInput.withUnsafeBufferPointer { buffer in
                    let ptr = UnsafeRawPointer(buffer.baseAddress!).bindMemory(to: DSPComplex.self, capacity: nhalf)
                    vDSP_ctoz(ptr, 2, &complex, 1, vDSP_Length(nhalf))
                }
                
                // Forward FFT
                fftSetUp.forward(input: complex, output: &complex)
                
                // Calculate magnitudes (squared) -> then sqrt? 
                // vDSP_zaspec calculates squared magnitude (Re^2 + Im^2).
                // For peak finding, squared is fine (peak is same), but if we want specific units...
                // The original code used zaspec.
                var mags = [Float](repeating: 0, count: nhalf)
                vDSP_zaspec(&complex, &mags, vDSP_Length(nhalf))
                
                // Frequency axis
                let fres = fs / Float(nfft)
                let freqs = (0..<nhalf).map { Float($0) * fres }
                
                return (mags, freqs)
            }
        }
    }

    private static func estimateFreq(_ input: [Float], fs: Float, nfft: Int, fmin: Float, fmax: Float, fftSetUp: vDSP.FFT<DSPSplitComplex>) -> Float? {
        let (mags, freqs) = powerSpectrum(input, fs: fs, nfft: nfft, fftSetUp: fftSetUp)
        
        guard let globalMax = mags.max() else { return nil }
        
        var bestMag: Float = -1
        var bestFreq: Float? = nil
        
        for i in 0..<mags.count {
            let f = freqs[i]
            if f >= fmin && f <= fmax {
                if mags[i] > bestMag {
                    bestMag = mags[i]
                    bestFreq = f
                }
            }
        }
        
        // Threshold check: Peak must be significant relative to global max (noise)
        if let freq = bestFreq, bestMag >= (globalMax * 0.5) {
            return freq * 60.0
        }
        return nil
    }
}