import Foundation
import Accelerate

/// A collection of stateless signal processing primitives using vDSP.
/// Optimized for x86_64 and ARM64 to prevent SIGILL by ensuring memory alignment
/// and avoiding dangerous floating-point instructions in loops.
public struct SignalOps {

    // MARK: - Constants
    public static let nfft = 4096

    /// Thread-safe, lazy FFT setup to prevent illegal instructions during static initialization.
    nonisolated(unsafe) private static let fftProvider: vDSP.FFT<DSPSplitComplex>? = {
        let log2n = vDSP_Length(log2(Double(nfft)))
        return vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
    }()

    // MARK: - 1. Preprocessing

    public static func standardize(_ signal: [Float]) -> [Float] {
        guard !signal.isEmpty else { return [] }
        let count = signal.count
        
        var mean: Float = 0
        vDSP_meanv(signal, 1, &mean, vDSP_Length(count))
        
        var stdDev: Float = 0
        vDSP_normalize(signal, 1, nil, 1, &mean, &stdDev, vDSP_Length(count))
        
        if stdDev < 1e-6 || stdDev.isNaN {
            return [Float](repeating: 0.0, count: count)
        }
        
        var result = [Float](repeating: 0, count: count)
        var negMean = -mean
        var invStdDev = 1.0 / stdDev
        
        vDSP_vsadd(signal, 1, &negMean, &result, 1, vDSP_Length(count))
        vDSP_vsmul(result, 1, &invStdDev, &result, 1, vDSP_Length(count))
        
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
        
        var output: [Float] = []
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
        let lag = max(1, Int(round(fs * 1.5)))
        let thresholdSq: Float = 1.5 * 1.5
        let height: Float = 0.0
        
        let minDistance: Int
        if let hr = hr, hr >= 45, hr <= 220 {
            minDistance = Int(round((fs * 60.0) / hr * 0.5))
        } else {
            minDistance = Int(round((fs * 60.0) / 220.0))
        }
        
        guard signal.count > 2 else { return [] }
        
        var detectedIndices = [Int]()
        let lagF = Float(lag)
        
        // Loop uses direct indexing and squared comparisons to remain SIGILL-safe
        for i in 1..<(signal.count - 1) {
            let val = signal[i]
            if val > signal[i-1] && val > signal[i+1] && val > height {
                let windowStart = i - lag
                var sum: Float = 0
                var sumSq: Float = 0
                
                for j in windowStart..<i {
                    let s = j < 0 ? signal[0] : signal[j]
                    sum += s
                    sumSq += (s * s)
                }
                
                let mean = sum / lagF
                let diff = val - mean
                
                if diff > 0 {
                    let variance = max(0, (sumSq / lagF) - (mean * mean))
                    if (diff * diff) > (thresholdSq * variance) {
                        if let last = detectedIndices.last {
                            if (i - last) >= minDistance { detectedIndices.append(i) }
                        } else {
                            detectedIndices.append(i)
                        }
                    }
                }
            }
        }
        
        var finalPeaks = [Int]()
        var currentSeq = [Int]()
        let maxGap = Int(fs * 2.5)
        
        for idx in detectedIndices {
            if let last = currentSeq.last, (idx - last) > maxGap {
                if currentSeq.count >= 3 { finalPeaks.append(contentsOf: currentSeq) }
                currentSeq = [idx]
            } else {
                currentSeq.append(idx)
            }
        }
        if currentSeq.count >= 3 { finalPeaks.append(contentsOf: currentSeq) }
        
        return finalPeaks
    }

    // MARK: - 4. HRV Calculation

    public static func calculateSDNN(peaks: [Int], fs: Float) -> Double? {
        let intervals = calculateNNIntervals(peaks: peaks, fs: fs)
        guard intervals.count >= 2 else { return nil }
        var mean: Float = 0
        var stdDev: Float = 0
        vDSP_normalize(intervals, 1, nil, 1, &mean, &stdDev, vDSP_Length(intervals.count))
        return Double(stdDev * 1000.0)
    }

    public static func calculateRMSSD(peaks: [Int], fs: Float) -> Double? {
        let intervals = calculateNNIntervals(peaks: peaks, fs: fs)
        guard intervals.count >= 2 else { return nil }
        
        var sumSqDiff: Float = 0
        for i in 0..<(intervals.count - 1) {
            let diff = intervals[i+1] - intervals[i]
            sumSqDiff += (diff * diff)
        }
        return Double(sqrt(max(0, sumSqDiff / Float(intervals.count - 1))) * 1000.0)
    }

    private static func calculateNNIntervals(peaks: [Int], fs: Float) -> [Float] {
        guard peaks.count >= 2 else { return [] }
        var intervals: [Float] = []
        for i in 0..<(peaks.count - 1) {
            intervals.append(Float(peaks[i+1] - peaks[i]) / fs)
        }
        return filterNNIntervals(intervals)
    }

    private static func filterNNIntervals(_ intervals: [Float], threshold: Float = 0.3) -> [Float] {
        guard intervals.count >= 3 else { return intervals }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        return intervals.filter { abs($0 - median) <= (median * threshold) }
    }

    // MARK: - Internal FFT Helpers

    private static func powerSpectrum(_ input: [Float], fs: Float, nfft: Int, fftSetUp: vDSP.FFT<DSPSplitComplex>) -> (magnitudes: [Float], frequencies: [Float]) {
        let count = input.count
        var window = [Float](repeating: 0, count: count)
        vDSP_hann_window(&window, vDSP_Length(count), Int32(vDSP_HANN_NORM))
        
        var windowedInput = [Float](repeating: 0, count: count)
        vDSP_vmul(input, 1, window, 1, &windowedInput, 1, vDSP_Length(count))
        
        let nhalf = nfft / 2
        var real = [Float](repeating: 0, count: nhalf)
        var imag = [Float](repeating: 0, count: nhalf)
        
        var paddedInput = windowedInput
        if count < nfft { paddedInput.append(contentsOf: [Float](repeating: 0.0, count: nfft - count)) }

        return real.withUnsafeMutableBufferPointer { rPtr in
            imag.withUnsafeMutableBufferPointer { iPtr in
                var complex = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                paddedInput.withUnsafeBufferPointer { buffer in
                    let ptr = UnsafeRawPointer(buffer.baseAddress!).bindMemory(to: DSPComplex.self, capacity: nhalf)
                    vDSP_ctoz(ptr, 2, &complex, 1, vDSP_Length(nhalf))
                }
                fftSetUp.forward(input: complex, output: &complex)
                var mags = [Float](repeating: 0, count: nhalf)
                vDSP_zaspec(&complex, &mags, vDSP_Length(nhalf))
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
            if freqs[i] >= fmin && freqs[i] <= fmax {
                if mags[i] > bestMag {
                    bestMag = mags[i]
                    bestFreq = freqs[i]
                }
            }
        }
        
        if let freq = bestFreq, bestMag >= (globalMax * 0.5) { return freq * 60.0 }
        return nil
    }
}