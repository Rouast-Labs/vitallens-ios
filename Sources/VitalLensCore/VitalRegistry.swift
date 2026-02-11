import Foundation
import SwiftUI

/// Defines how a raw time-series array from the model should be processed into a single value.
public enum DerivationMethod: String, Sendable {
    case none           // Do not calculate a scalar (just display waveform)
    case average        // Take the mean of the window (e.g., SpO2, SBP, Heart Rate stream)
    case latest         // Take the last valid value in the array
    case rateFromFFT    // Calculate frequency via FFT (e.g., Heart Rate from PPG)
    case hrvStatistics  // Calculate SDNN/RMSSD (requires peak detection on signal)
}

public struct VitalMeta: Sendable {
    public let id: String
    public let displayName: String
    public let unit: String
    public let color: Color
    
    /// How to derive a scalar value from the raw array.
    public let derivation: DerivationMethod
    
    /// Valid bounds for frequency estimation (if derivation is .rateFromFFT).
    public let frequencyBounds: ClosedRange<Double>? // e.g. 40...240 bpm
    
    /// Valid bounds for the scalar value (for UI clamping).
    public let valueBounds: ClosedRange<Double>?
}

public final class VitalRegistry: Sendable {
    
    public static let shared = VitalRegistry()
    
    private let registry: [String: VitalMeta] = [
        // --- Core Source Signals ---
        "ppg_waveform": VitalMeta(
            id: "ppg_waveform", displayName: "PPG", unit: "", color: .red,
            derivation: .rateFromFFT, frequencyBounds: 40...240, valueBounds: nil
        ),
        "respiratory_waveform": VitalMeta(
            id: "respiratory_waveform", displayName: "Respiration", unit: "", color: .blue,
            derivation: .rateFromFFT, frequencyBounds: 6...60, valueBounds: nil
        ),
        
        // --- Derived/Scalar Vitals ---
        "heart_rate": VitalMeta(
            id: "heart_rate", displayName: "Heart Rate", unit: "bpm", color: .red,
            derivation: .average, frequencyBounds: nil, valueBounds: 40...200
        ),
        "respiratory_rate": VitalMeta(
            id: "respiratory_rate", displayName: "Resp Rate", unit: "rpm", color: .blue,
            derivation: .average, frequencyBounds: nil, valueBounds: 8...40
        ),
        "hrv_sdnn": VitalMeta(
            id: "hrv_sdnn", displayName: "HRV (SDNN)", unit: "ms", color: .purple,
            derivation: .average, frequencyBounds: nil, valueBounds: 0...150
        ),
        "hrv_rmssd": VitalMeta(
            id: "hrv_rmssd", displayName: "HRV (RMSSD)", unit: "ms", color: .purple,
            derivation: .average, frequencyBounds: nil, valueBounds: 0...150
        ),
        "hrv_lfhf": VitalMeta(
            id: "hrv_lfhf", displayName: "HRV (LF/HF)", unit: "", color: .purple,
            derivation: .average, frequencyBounds: nil, valueBounds: 0...10
        ),
        
        // --- Future / Implicit Signals ---
        "sbp": VitalMeta(
            id: "sbp", displayName: "Systolic BP", unit: "mmHg", color: .green,
            derivation: .average, frequencyBounds: nil, valueBounds: 60...180
        ),
        "dbp": VitalMeta(
            id: "dbp", displayName: "Diastolic BP", unit: "mmHg", color: .green,
            derivation: .average, frequencyBounds: nil, valueBounds: 40...120
        ),
        "spo2": VitalMeta(
            id: "spo2", displayName: "SpO2", unit: "%", color: .orange,
            derivation: .average, frequencyBounds: nil, valueBounds: 80...100
        ),
        "stress_index": VitalMeta(
            id: "stress_index", displayName: "Stress", unit: "", color: .purple,
            derivation: .latest, frequencyBounds: nil, valueBounds: 0...100
        )
    ]
    
    public func getMeta(for key: String) -> VitalMeta {
        if let known = registry[key] { return known }
        
        // Intelligent fallback
        let name = key.replacingOccurrences(of: "_", with: " ").capitalized
        return VitalMeta(
            id: key, displayName: name, unit: "", color: .gray,
            derivation: .average, frequencyBounds: nil, valueBounds: nil
        )
    }
}