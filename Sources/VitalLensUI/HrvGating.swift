import Foundation

/// Whether an HRV metric may be shown. HRV is only shown when it is confident itself and heart
/// rate is confident too: users should not see an HRV without a heart rate.
/// Keep this rule in sync with the other VitalLens SDKs.
///
/// - Parameters:
///   - hrvConf: Confidence of the HRV metric.
///   - hrConf: Confidence of the heart rate.
///   - hrvThreshold: Minimum HRV confidence.
///   - hrThreshold: Minimum heart rate confidence.
/// - Returns: `true` if the HRV metric may be shown.
func isHrvShown(hrvConf: Double?, hrConf: Double?, hrvThreshold: Double, hrThreshold: Double) -> Bool {
    guard let hrvConf = hrvConf, let hrConf = hrConf else { return false }
    return hrvConf >= hrvThreshold && hrConf >= hrThreshold
}
