import Foundation
import Accelerate

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
        
        // Optimization: Calculate stats and write normalized output in a single vDSP pass
        vDSP_normalize(signal, 1, &result, 1, &mean, &stdDev, vDSP_Length(count))
        
        // Safety check for flatlines or NaNs (prevents divide-by-zero propagation)
        if stdDev < 1e-6 || stdDev.isNaN {
            return [Float](repeating: 0.0, count: count)
        }
        
        return result
    }

    public static func detrend(_ signal: [Float], fs: Float, cutoff: Float = 0.5) -> [Float] {
        guard signal.count > 1 else { return signal }
        
        // Optimization: In-place filtering to reduce memory allocations from 3xN to 1xN.
        // We act on a copy of the signal.
        var buffer = signal
        
        let dt = 1.0 / fs
        let rc = 1.0 / (2.0 * Float.pi * cutoff)
        let alpha = rc / (rc + dt)
        
        // 1. Forward Pass
        applyDetrendInPlace(&buffer, alpha: alpha)
        
        // 2. Reverse
        buffer.reverse()
        
        // 3. Backward Pass (applied to reversed data)
        applyDetrendInPlace(&buffer, alpha: alpha)
        
        // 4. Reverse back
        buffer.reverse()
        
        return buffer
    }

    /// High-performance in-place detrending using UnsafeMutableBufferPointer.
    /// Eliminates array bounds checking overhead in the hot loop.
    private static func applyDetrendInPlace(_ buffer: inout [Float], alpha: Float) {
        buffer.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress, ptr.count > 1 else { return }
            
            var lastOut: Float = 0.0
            var lastIn: Float = base[0] // Corresponds to x[i-1]
            
            // First element is treated as 0 (DC removal starts relative to 0)
            base[0] = 0.0
            
            // Loop starts at 1
            for i in 1..<ptr.count {
                let currentIn = base[i]
                // formula: y[i] = alpha * (y[i-1] + x[i] - x[i-1])
                let out = alpha * (lastOut + currentIn - lastIn)
                
                base[i] = out
                
                lastOut = out
                lastIn = currentIn
            }
        }
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

        // Configuration
        let lag = max(1, Int(round(fs * 1.5)))
        let thresholdSq: Float = 1.5 * 1.5
        let height: Float = 0.0
        
        // Refractory Period Logic
        let minDistance: Int
        if let hr = hr, hr >= 40, hr <= 220 {
            minDistance = Int(round((fs * 60.0) / hr * 0.5))
        } else {
            minDistance = Int(round((fs * 60.0) / 220.0))
        }
        
        var detectedIndices = [Int]()
        
        signal.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress, ptr.count > lag + 2 else { return }
            
            var sum: Float = 0
            var sumSq: Float = 0
            
            // FIX: Use 0.0 as the padding value for history.
            // Since signal is standardized (mean 0), assuming past is 0 is safer than 
            // repeating signal[0], which creates artificial zero-variance windows.
            let padVal: Float = 0.0
            
            // Initialize Rolling Stats with padVal
            sum = padVal * Float(lag)
            sumSq = (padVal * padVal) * Float(lag)
            let lagF = Float(lag)
            
            // Iterate
            for i in 1..<(ptr.count - 1) {
                let val = base[i]
                
                // 1. Calculate stats for window [i-lag ... i-1]
                let mean = sum / lagF
                let variance = max(0, (sumSq / lagF) - (mean * mean))
                
                // 2. Check Peak
                // We add a check for variance > epsilon to prevent divide-by-zero sensitivity on flatlines
                if val > base[i-1] && val > base[i+1] && val > height {
                    if variance > 1e-6 {
                        let diff = val - mean
                        if diff > 0 && (diff * diff) > (thresholdSq * variance) {
                            // Refractory Check
                            if let last = detectedIndices.last {
                                if (i - last) >= minDistance {
                                    detectedIndices.append(i)
                                }
                            } else {
                                detectedIndices.append(i)
                            }
                        }
                    }
                }
                
                // 3. Slide Window
                let leavingIndex = i - lag
                // Use the same padVal (0.0) for virtual history indices < 0
                let leavingValue = (leavingIndex < 0) ? padVal : base[leavingIndex]
                
                sum = sum - leavingValue + val
                sumSq = sumSq - (leavingValue * leavingValue) + (val * val)
            }
        }
        
        return detectedIndices
    }

    // MARK: - 4. HRV Calculation

    public static func calculateSDNN(peaks: [Int], fs: Float) -> Double? {
        let intervals = calculateNNIntervals(peaks: peaks, fs: fs)
        // SDNN requires at least 2 intervals (3 peaks) to calculate variance
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
        // Standard loop is efficient enough for small interval arrays (< 50 items)
        for i in 0..<(intervals.count - 1) {
            let diff = intervals[i+1] - intervals[i]
            sumSqDiff += (diff * diff)
        }
        
        let meanSqDiff = sumSqDiff / Float(intervals.count - 1)
        return Double(sqrt(meanSqDiff) * 1000.0)
    }

    private static func calculateNNIntervals(peaks: [Int], fs: Float) -> [Float] {
        guard peaks.count >= 2 else { return [] }
        var intervals = [Float]()
        intervals.reserveCapacity(peaks.count - 1)
        
        for i in 0..<(peaks.count - 1) {
            intervals.append(Float(peaks[i+1] - peaks[i]) / fs)
        }
        return filterNNIntervals(intervals)
    }

    private static func filterNNIntervals(_ intervals: [Float], threshold: Float = 0.3) -> [Float] {
        guard intervals.count >= 3 else { return intervals }
        
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        
        // Filter outliers (> 30% deviation from median)
        return intervals.filter { abs($0 - median) <= (median * threshold) }
    }

    // MARK: - Internal FFT Helpers

    private static func powerSpectrum(_ input: [Float], fs: Float, nfft: Int, fftSetUp: vDSP.FFT<DSPSplitComplex>) -> (magnitudes: [Float], frequencies: [Float]) {
        let count = input.count
        
        // Generate Window
        var window = [Float](repeating: 0, count: count)
        vDSP_hann_window(&window, vDSP_Length(count), Int32(vDSP_HANN_NORM))
        
        // Apply Window
        var windowedInput = [Float](repeating: 0, count: count)
        vDSP_vmul(input, 1, window, 1, &windowedInput, 1, vDSP_Length(count))
        
        // Pad to NFFT
        let nhalf = nfft / 2
        var paddedInput = windowedInput
        if count < nfft {
            paddedInput.append(contentsOf: [Float](repeating: 0.0, count: nfft - count))
        }

        // FFT Calculation
        // Using withUnsafeBufferPointer avoids copying data when binding memory
        var real = [Float](repeating: 0, count: nhalf)
        var imag = [Float](repeating: 0, count: nhalf)
        
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
        
        // Find highest peak in valid range
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
        
        // Peak Validation: Must be at least 50% of the global max energy
        if let freq = bestFreq, bestMag >= (globalMax * 0.5) {
            return freq * 60.0
        }
        return nil
    }
}