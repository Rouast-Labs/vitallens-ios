import Foundation

/// The SDK release version. Sent to the API as part of the origin so usage can be broken down by client version.
/// Keep in sync with the git tag: bump this before tagging a release (the release workflow checks it).
public enum VitalLensVersion {
    public static let current = "0.2.0"

    /// The origin label sent to the API, e.g. `vitallens-ios_0.2.0`.
    public static var apiOrigin: String { "vitallens-ios_\(current)" }
}
