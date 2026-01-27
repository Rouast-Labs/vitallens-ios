import Foundation
import Accelerate

/// A collection of stateless signal processing primitives using vDSP.
/// These functions are public and can be used independently of the API client.
struct SignalOps {

    // MARK: - Constants

    /// FFT Size must be a power of 2. 4096 provides high resolution for HR/RR.
    public static let nfft = 4096

    // Shared FFT Setup. Thread-safe if used read-only.
    static let fftSetup: vDSP.FFT<DSPSplitComplex>? = {
        let log2n = vDSP_Length(floor(log2(Float(nfft))))
        return vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
    }()

    // MARK: - 1. Preprocessing

    /// Standardizes the signal to zero mean and unit variance.
    public static func standardize(_ signal: [Float]) -> [Float] {
        guard !signal.isEmpty else { return [] }
        
        var mu: Float = 0
        var sigma: Float = 0
        
        vDSP_normalize(signal, 1, nil, 1, &mu, &sigma, vDSP_Length(signal.count))
        
        var result = [Float](repeating: 0, count: signal.count)
        vDSP_normalize(signal, 1, &result, 1, &mu, &sigma, vDSP_Length(signal.count))
        
        return result
    }

    /// Detrends a signal using a zero-phase high-pass IIR filter.
    /// Runs the filter forward and backward to eliminate phase shift.
    ///
    /// - Parameters:
    ///   - signal: The input waveform.
    ///   - fs: Sampling frequency.
    ///   - cutoff: Cutoff frequency (default 0.5Hz for PPG).
    public static func detrend(_ signal: [Float], fs: Float, cutoff: Float = 0.5) -> [Float] {
        guard signal.count > 1 else { return signal }
        
        // Forward pass
        let forward = efficientDetrend(signal, fs: fs, cutoff: cutoff)
        
        // Reverse
        let reversed = Array(forward.reversed())
        
        // Backward pass
        let backward = efficientDetrend(reversed, fs: fs, cutoff: cutoff)
        
        // Final reverse
        return Array(backward.reversed())
    }

    private static func efficientDetrend(_ signal: [Float], fs: Float, cutoff: Float) -> [Float] {
        let dt = 1.0 / fs
        let rc = 1.0 / (2.0 * Float.pi * cutoff)
        let alpha = rc / (rc + dt)
        
        var output = [Float](repeating: 0, count: signal.count)
        output[0] = signal[0]
        
        for i in 1..<signal.count {
            output[i] = alpha * (output[i-1] + signal[i] - signal[i-1])
        }
        
        return output
    }

    // MARK: - 2. Rate Estimation (FFT)

    /// Estimates a rate (HR/RR) from a waveform using FFT.
    ///
    /// - Parameters:
    ///   - waveform: The input signal.
    ///   - fs: Sampling rate.
    ///   - minRate: Minimum rate in **BPM** (e.g., 40).
    ///   - maxRate: Maximum rate in **BPM** (e.g., 240).
    public static func estimateRate(from waveform: [Float], fs: Float, minRate: Float, maxRate: Float) -> Float? {
        guard let setup = fftSetup else { return nil }
        
        let fmin = minRate / 60.0
        let fmax = maxRate / 60.0
        
        return estimateFreq(waveform, fs: fs, nfft: nfft, fmin: fmin, fmax: fmax, fftSetUp: setup)
    }

    // MARK: - 3. Peak Detection (Adaptive Z-Score)

    /// Detects peaks in a physiological signal using adaptive Z-Score thresholding.
    ///
    /// - Parameters:
    ///   - signal: The input signal (typically PPG).
    ///   - fs: Sampling frequency.
    ///   - hr: Estimated Heart Rate (BPM) to adapt window sizes (optional).
    /// - Returns: Indices of detected peaks.
    public static func findPeaks(in signal: [Float], fs: Float, hr: Float?) -> [Int] {
        // Defaults
        let lag = Int(round(fs * 1.5))
        let threshold: Float = 1.5
        let height: Float = 0.0
        
        // Adaptive distances based on HR (if available)
        let minDistanceSamples: Int
        let maxDistanceSamples: Int
        
        if let hr = hr, hr >= 45, hr <= 220 {
            let expectedIntervalSamples = (fs * 60.0) / hr
            minDistanceSamples = Int(round(expectedIntervalSamples * 0.5))
            maxDistanceSamples = Int(round(expectedIntervalSamples * 2.5))
        } else {
            // Fallback: Max physiological HR 220 BPM
            minDistanceSamples = Int(round((fs * 60.0) / 220.0))
            // Fallback: Min physiological HR 45 BPM
            maxDistanceSamples = Int(round(((fs * 60.0) / 45.0) * 2.0))
        }
        
        guard signal.count > lag else { return [] }
        
        // Pre-pad to handle edge effects (repeat first element)
        let padding = Array(repeating: signal[0], count: lag)
        let paddedSignal = padding + signal
        
        var sequences: [[Int]] = []
        var currentSequence: [Int] = []
        var lastPeakOverall = -Int.max
        
        // Single-pass iteration
        for i in lag..<(paddedSignal.count - 1) {
            let val = paddedSignal[i]
            let originalIndex = i - lag
            
            if val > paddedSignal[i-1] && val > paddedSignal[i+1] && val > height {
                let windowStart = i - lag
                let windowData = Array(paddedSignal[windowStart..<i])
                var mean: Float = 0
                var stdDev: Float = 0
                vDSP_normalize(windowData, 1, nil, 1, &mean, &stdDev, vDSP_Length(windowData.count))
                
                let dynamicThreshold = mean + (threshold * stdDev)
                
                if val > dynamicThreshold {
                    if (originalIndex - lastPeakOverall) >= minDistanceSamples {
                        let lastPeakInSequence = currentSequence.last ?? -Int.max
                        if (originalIndex - lastPeakInSequence) < maxDistanceSamples {
                            currentSequence.append(originalIndex)
                        } else {
                            if !currentSequence.isEmpty { sequences.append(currentSequence) }
                            currentSequence = [originalIndex]
                        }
                        lastPeakOverall = originalIndex
                    }
                }
            }
        }
        
        if !currentSequence.isEmpty {
            sequences.append(currentSequence)
        }
        
        // Filter short sequences (min length 3)
        let minSequenceLength = 3
        let validSequences = sequences.filter { $0.count >= minSequenceLength }
        
        // Flatten output
        return validSequences.flatMap { $0 }
    }

    // MARK: - 4. HRV Calculation

    /// Calculates SDNN (Standard Deviation of NN intervals) in milliseconds.
    public static func calculateSDNN(peaks: [Int], fs: Float) -> Double? {
        let intervals = calculateNNIntervals(peaks: peaks, fs: fs)
        guard intervals.count >= 2 else { return nil }
        
        var mean: Float = 0
        var stdDev: Float = 0
        vDSP_normalize(intervals, 1, nil, 1, &mean, &stdDev, vDSP_Length(intervals.count))
        
        return Double(stdDev * 1000.0)
    }

    /// Calculates RMSSD (Root Mean Square of Successive Differences) in milliseconds.
    public static func calculateRMSSD(peaks: [Int], fs: Float) -> Double? {
        let intervals = calculateNNIntervals(peaks: peaks, fs: fs)
        guard intervals.count >= 2 else { return nil }
        
        var diffs: [Float] = []
        for i in 0..<(intervals.count - 1) {
            let diff = intervals[i+1] - intervals[i]
            diffs.append(diff * diff)
        }
        
        var meanSqDiff: Float = 0
        vDSP_meanv(diffs, 1, &meanSqDiff, vDSP_Length(diffs.count))
        
        return Double(sqrt(meanSqDiff) * 1000.0)
    }

    /// Helper: Converts peak indices to NN intervals (in seconds), with outlier filtering.
    private static func calculateNNIntervals(peaks: [Int], fs: Float) -> [Float] {
        guard peaks.count >= 2 else { return [] }
        var intervals: [Float] = []
        for i in 0..<(peaks.count - 1) {
            let intervalSamples = Float(peaks[i+1] - peaks[i])
            intervals.append(intervalSamples / fs)
        }
        return filterNNIntervals(intervals)
    }

    /// Filters outliers (deviating > 30% from median).
    private static func filterNNIntervals(_ intervals: [Float], threshold: Float = 0.3) -> [Float] {
        guard intervals.count >= 3 else { return intervals }
        let sorted = intervals.sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[mid-1] + sorted[mid]) / 2.0 : sorted[mid]
        let lowerBound = median * (1.0 - threshold)
        let upperBound = median * (1.0 + threshold)
        return intervals.filter { $0 >= lowerBound && $0 <= upperBound }
    }

    // MARK: - Internal Helpers

    /// Convert signal from time domain to frequency domain
    /// Zero-pads `input` to `nfft`, runs FFT and computes the frequency response magnitudes & corresponding frequencies
    private static func powerSpectrum(_ input: [Float], fs: Float, nfft: Int, fftSetUp: vDSP.FFT<DSPSplitComplex>) -> (magnitudes: [Float], frequencies: [Float]) {
        precondition(input.count > 0)
        precondition(nfft >= input.count)
        precondition((nfft > 0) && (nfft & (nfft - 1) == 0), "nfft needs to be a power of 2")
        let nhalf = Int(nfft/2)
        let fres = fs/Float(nfft)
        // Pad input with zeroes to match nfft
        let inputPadded = input + [Float](repeating: 0.0, count: max(nfft - input.count, 0))
        // Create arrays for time domain inputs, frequency domain and magnitude outputs
        var real = [Float](repeating: 0, count: nhalf)
        var imag = [Float](repeating: 0, count: nhalf)
        // Run
        let autospectrum = [Float](unsafeUninitializedCapacity: nhalf) {
            autospectrumBuffer, initializedCount in
            vDSP.clear(&autospectrumBuffer)
            real.withUnsafeMutableBufferPointer { realPtr in
                imag.withUnsafeMutableBufferPointer { imagPtr in
                    // Create a `DSPSplitComplex` for time domain input / frequency domain output
                    var complex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    // Convert the real values in `signal` to complex numbers.
                    inputPadded.withUnsafeBytes {
                        vDSP.convert(interleavedComplexVector: [DSPComplex]($0.bindMemory(to: DSPComplex.self)),
                                    toSplitComplexVector: &complex)
                    }
                    // Perform the FFT
                    fftSetUp.forward(input: complex, output: &complex)
                    vDSP_zaspec(&complex, autospectrumBuffer.baseAddress!, vDSP_Length(nhalf))
                }
            }
            initializedCount = nhalf
        }
        // Frequencies
        let frequencies = Array(stride(from: 0.0, through: fres * Float(nhalf-1), by: fres))
        assert(frequencies.count == autospectrum.count, "freq.count \(frequencies.count) != mag.count \(autospectrum.count)")
        return (autospectrum, frequencies)
    }

    /// Estimates the dominant frequency in a signal
    private static func estimateFreq(_ input: [Float], fs: Float, nfft: Int, fmin: Float, fmax: Float, fftSetUp: vDSP.FFT<DSPSplitComplex>) -> Float? {
        // Compute power spectrum
        let spectrum = powerSpectrum(input, fs: fs, nfft: nfft, fftSetUp: fftSetUp)
        // Filter out infeasible frequencies
        let feasibleIndices = spectrum.frequencies.indices.filter { frequencyIndex in
            let frequency = spectrum.frequencies[frequencyIndex]
            return frequency >= fmin && frequency <= fmax
        }
        // Find the maximum magnitude within the feasible range
        guard let maximumMagnitude = feasibleIndices.map({ spectrum.magnitudes[$0] }).max(),
            let index = spectrum.magnitudes.firstIndex(of: maximumMagnitude) else {
            return nil
        }
        return spectrum.frequencies[index] * 60.0
    }

}