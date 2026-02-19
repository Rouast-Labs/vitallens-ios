import Foundation
import Accelerate

/// A collection of stateless signal processing utilities for rPPG analysis.
///
/// Includes high-performance implementations of:
/// - Standardization (Z-Score normalization)
/// - Detrending (Drift removal)
/// - Frequency estimation (FFT)
/// - Peak detection (Adaptive Z-Score)
/// - HRV metrics (SDNN, RMSSD)
public struct SignalOps {

    // MARK: - Constants
    
    /// The size of the FFT window. A larger window provides better frequency resolution.
    public static let nfft = 4096

    /// Thread-safe, lazy FFT setup for Accelerate/vDSP.
    nonisolated(unsafe) private static let fftProvider: vDSP.FFT<DSPSplitComplex>? = {
        let log2n = vDSP_Length(log2(Double(nfft)))
        return vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
    }()

    // MARK: - 1. Preprocessing

    /// Standardizes a signal to have zero mean and unit variance (Z-Score normalization).
    ///
    /// - Parameter signal: The input signal array.
    /// - Returns: The standardized signal. Returns a zero-filled array if the input is empty or flat (zero variance).
    public static func standardize(_ signal: [Float]) -> [Float] {
        guard !signal.isEmpty else { return [] }
        let count = signal.count
        
        var mean: Float = 0
        var stdDev: Float = 0
        var result = [Float](repeating: 0, count: count)
        
        // Single pass calculation using vDSP
        vDSP_normalize(signal, 1, &result, 1, &mean, &stdDev, vDSP_Length(count))
        
        // Safety check for flatlines or NaNs to prevent downstream math errors
        if stdDev < 1e-6 || stdDev.isNaN {
            return [Float](repeating: 0.0, count: count)
        }
        
        return result
    }

    /// Removes linear and low-frequency trends from the signal using a smoothness prior approach.
    ///
    /// This method applies a forward and backward pass to ensure zero phase shift.
    ///
    /// - Parameters:
    ///   - signal: The input signal array.
    ///   - fs: Sampling frequency in Hz.
    ///   - cutoff: The cutoff frequency for detrending (default 0.5 Hz).
    /// - Returns: The detrended signal.
    public static func detrend(_ signal: [Float], fs: Float, cutoff: Float = 0.5) -> [Float] {
        guard signal.count > 1 else { return signal }
        
        var buffer = signal
        
        let dt = 1.0 / fs
        let rc = 1.0 / (2.0 * Float.pi * cutoff)
        let alpha = rc / (rc + dt)
        
        // Forward pass
        applyDetrendInPlace(&buffer, alpha: alpha)
        
        // Backward pass (reverse, filter, reverse back) to cancel phase shift
        buffer.reverse()
        applyDetrendInPlace(&buffer, alpha: alpha)
        buffer.reverse()
        
        return buffer
    }

    /// Applies a high-performance in-place detrending filter to the provided buffer.
    ///
    /// - Parameters:
    ///   - buffer: The signal buffer to modify.
    ///   - alpha: The smoothing factor derived from the cutoff frequency.
    private static func applyDetrendInPlace(_ buffer: inout [Float], alpha: Float) {
        buffer.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress, ptr.count > 1 else { return }
            
            var lastOut: Float = 0.0
            var lastIn: Float = base[0]
            
            // Initialize first element to 0 (DC removal relative to start)
            base[0] = 0.0
            
            for i in 1..<ptr.count {
                let currentIn = base[i]
                // Simple high-pass filter recurrence: y[i] = α * (y[i-1] + x[i] - x[i-1])
                let out = alpha * (lastOut + currentIn - lastIn)
                
                base[i] = out
                
                lastOut = out
                lastIn = currentIn
            }
        }
    }

    // MARK: - 2. Rate Estimation (FFT)

    /// Estimates the dominant frequency (rate) from a signal using Fast Fourier Transform (FFT).
    ///
    /// - Parameters:
    ///   - waveform: The input signal (e.g., PPG).
    ///   - fs: Sampling frequency in Hz.
    ///   - minRate: Minimum valid rate in BPM (e.g., 40).
    ///   - maxRate: Maximum valid rate in BPM (e.g., 200).
    /// - Returns: The estimated rate in BPM, or `nil` if no valid peak is found within the range.
    public static func estimateRate(from waveform: [Float], fs: Float, minRate: Float, maxRate: Float) -> Float? {
        guard let setup = fftProvider else { return nil }
        let fmin = minRate / 60.0
        let fmax = maxRate / 60.0
        return estimateFreq(waveform, fs: fs, nfft: nfft, fmin: fmin, fmax: fmax, fftSetUp: setup)
    }

    // MARK: - 3. Peak Detection

    /// Detects peaks in the signal using an adaptive rolling window threshold (Z-Score).
    ///
    /// - Parameters:
    ///   - signal: The input signal array.
    ///   - fs: Sampling frequency in Hz.
    ///   - hr: Optional heart rate hint in BPM. If provided, it enforces a dynamic refractory period.
    /// - Returns: An array of indices representing the detected peaks.
    public static func findPeaks(in signal: [Float], fs: Float, hr: Float?) -> [Int] {
        guard signal.count > 2 else { return [] }

        let lag = max(1, Int(round(fs * 1.5)))
        let thresholdSq: Float = 1.5 * 1.5
        let height: Float = 0.0
        
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
            let padVal: Float = 0.0 // Standardized signal mean is 0
            
            // Initialize rolling statistics
            sum = padVal * Float(lag)
            sumSq = (padVal * padVal) * Float(lag)
            let lagF = Float(lag)
            
            for i in 1..<(ptr.count - 1) {
                let val = base[i]
                
                let mean = sum / lagF
                let variance = max(0, (sumSq / lagF) - (mean * mean))
                
                // Peak check: Local maxima + Variance threshold
                if val > base[i-1] && val > base[i+1] && val > height {
                    if variance > 1e-6 {
                        let diff = val - mean
                        if diff > 0 && (diff * diff) > (thresholdSq * variance) {
                            // Refractory Period Check
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
                
                // Update rolling window (slide out old value, slide in new value)
                let leavingIndex = i - lag
                let leavingValue = (leavingIndex < 0) ? padVal : base[leavingIndex]
                
                sum = sum - leavingValue + val
                sumSq = sumSq - (leavingValue * leavingValue) + (val * val)
            }
        }
        
        return detectedIndices
    }

    // MARK: - 4. HRV Calculation

    /// Calculates the Standard Deviation of NN intervals (SDNN) in milliseconds.
    ///
    /// - Parameters:
    ///   - peaks: Indices of detected peaks.
    ///   - fs: Sampling frequency in Hz.
    /// - Returns: The SDNN value in ms, or `nil` if insufficient peaks are provided.
    public static func calculateSDNN(peaks: [Int], fs: Float) -> Double? {
        let intervals = calculateNNIntervals(peaks: peaks, fs: fs)
        guard intervals.count >= 2 else { return nil }
        
        var mean: Float = 0
        var stdDev: Float = 0
        vDSP_normalize(intervals, 1, nil, 1, &mean, &stdDev, vDSP_Length(intervals.count))
        
        return Double(stdDev * 1000.0)
    }

    /// Calculates the Root Mean Square of Successive Differences (RMSSD) in milliseconds.
    ///
    /// - Parameters:
    ///   - peaks: Indices of detected peaks.
    ///   - fs: Sampling frequency in Hz.
    /// - Returns: The RMSSD value in ms, or `nil` if insufficient peaks are provided.
    public static func calculateRMSSD(peaks: [Int], fs: Float) -> Double? {
        let intervals = calculateNNIntervals(peaks: peaks, fs: fs)
        guard intervals.count >= 2 else { return nil }
        
        var sumSqDiff: Float = 0
        for i in 0..<(intervals.count - 1) {
            let diff = intervals[i+1] - intervals[i]
            sumSqDiff += (diff * diff)
        }
        
        let meanSqDiff = sumSqDiff / Float(intervals.count - 1)
        return Double(sqrt(meanSqDiff) * 1000.0)
    }

    /// Converts peak indices into time intervals (in seconds), filtering out artifacts.
    ///
    /// - Parameters:
    ///   - peaks: Indices of detected peaks.
    ///   - fs: Sampling frequency in Hz.
    /// - Returns: An array of valid NN intervals in seconds.
    private static func calculateNNIntervals(peaks: [Int], fs: Float) -> [Float] {
        guard peaks.count >= 2 else { return [] }
        var intervals = [Float]()
        intervals.reserveCapacity(peaks.count - 1)
        
        for i in 0..<(peaks.count - 1) {
            intervals.append(Float(peaks[i+1] - peaks[i]) / fs)
        }
        return filterNNIntervals(intervals)
    }

    /// Filters intervals that deviate significantly from the median (outlier rejection).
    ///
    /// - Parameters:
    ///   - intervals: Raw peak-to-peak intervals in seconds.
    ///   - threshold: Percentage deviation allowed from median (default 0.3 or 30%).
    /// - Returns: An array of filtered intervals.
    private static func filterNNIntervals(_ intervals: [Float], threshold: Float = 0.3) -> [Float] {
        guard intervals.count >= 3 else { return intervals }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        return intervals.filter { abs($0 - median) <= (median * threshold) }
    }

    // MARK: - Internal FFT Helpers

    /// Computes the power spectrum of the input signal.
    ///
    /// - Parameters:
    ///   - input: The time-domain signal.
    ///   - fs: Sampling frequency in Hz.
    ///   - nfft: The FFT size (zero-padding is applied if input length < nfft).
    ///   - fftSetUp: The pre-calculated Accelerate FFT setup object.
    /// - Returns: A tuple containing the magnitude spectrum and corresponding frequency bins.
    private static func powerSpectrum(_ input: [Float], fs: Float, nfft: Int, fftSetUp: vDSP.FFT<DSPSplitComplex>) -> (magnitudes: [Float], frequencies: [Float]) {
        let count = input.count
        
        // 1. Generate and Apply Hanning Window
        var window = [Float](repeating: 0, count: count)
        vDSP_hann_window(&window, vDSP_Length(count), Int32(vDSP_HANN_NORM))
        
        var windowedInput = [Float](repeating: 0, count: count)
        vDSP_vmul(input, 1, window, 1, &windowedInput, 1, vDSP_Length(count))
        
        // 2. Pad to NFFT
        let nhalf = nfft / 2
        var paddedInput = windowedInput
        if count < nfft {
            paddedInput.append(contentsOf: [Float](repeating: 0.0, count: nfft - count))
        }

        // 3. Compute FFT
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

    /// Extracts the peak frequency within a specified range from the signal's power spectrum.
    ///
    /// - Parameters:
    ///   - input: The time-domain signal.
    ///   - fs: Sampling frequency in Hz.
    ///   - nfft: The FFT size.
    ///   - fmin: Minimum frequency in Hz.
    ///   - fmax: Maximum frequency in Hz.
    ///   - fftSetUp: The pre-calculated Accelerate FFT setup object.
    /// - Returns: The peak frequency converted to BPM, or `nil` if validation fails.
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
        
        // Peak Validation: The found peak must have at least 50% of the global max energy
        // to filter out strong noise outside the valid physiological range.
        if let freq = bestFreq, bestMag >= (globalMax * 0.5) {
            return freq * 60.0
        }
        return nil
    }
}