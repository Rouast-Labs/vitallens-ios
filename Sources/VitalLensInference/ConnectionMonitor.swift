import Foundation

/// Thresholds for deciding that a connection is too slow for the standard frame rate.
/// Keep in sync with the other VitalLens SDKs.
public enum ConnectionThresholds {
    /// Median request duration (ms) above which the connection counts as slow.
    public static let medianMs: Double = 1000
    /// Duration (ms) of a single request above which the connection counts as slow.
    public static let singleMs: Double = 2000
    /// Frames in a single request above which the connection counts as slow.
    public static let maxFrames: Int = 50
    /// Number of most recent requests the median is taken over.
    public static let window: Int = 5
    /// Requests needed before the median rule applies.
    public static let minSamples: Int = 3
    /// Frame rate of eco mode. Slow connections are only reported above it.
    public static let ecoFps: Double = 15
}

/// Details of a connection that was found to be too slow.
public struct SlowConnectionInfo: Sendable, Equatable {
    public let medianMs: Double
    public let frames: Int
}

/// Decides from stream request durations and sizes whether the connection is too slow
/// for the current frame rate. Reports at most once, until reset.
public struct ConnectionMonitor: Sendable {
    private let medianMs: Double
    private let singleMs: Double
    private let maxFrames: Int
    private let window: Int
    private let minSamples: Int

    private var durations: [Double] = []
    private var samples = 0
    private var fired = false

    public init(
        medianMs: Double = ConnectionThresholds.medianMs,
        singleMs: Double = ConnectionThresholds.singleMs,
        maxFrames: Int = ConnectionThresholds.maxFrames,
        window: Int = ConnectionThresholds.window,
        minSamples: Int = ConnectionThresholds.minSamples
    ) {
        self.medianMs = medianMs
        self.singleMs = singleMs
        self.maxFrames = maxFrames
        self.window = window
        self.minSamples = minSamples
    }

    /// Records one stream request.
    ///
    /// - Parameters:
    ///   - ms: Time from sending the request to receiving the response.
    ///   - frames: Number of frames sent in the request.
    /// - Returns: Details if the connection was just found to be too slow, otherwise `nil`.
    public mutating func record(ms: Double, frames: Int) -> SlowConnectionInfo? {
        if fired { return nil }
        samples += 1
        durations.append(ms)
        if durations.count > window { durations.removeFirst() }

        // One very slow request or a long queue is decisive on its own: waiting for
        // more samples is too late once too many frames are queued.
        let median = currentMedian()
        let decisive = ms > singleMs || frames > maxFrames
        if decisive || (samples >= minSamples && median > medianMs) {
            fired = true
            return SlowConnectionInfo(medianMs: median, frames: frames)
        }
        return nil
    }

    public mutating func reset() {
        durations = []
        samples = 0
        fired = false
    }

    private func currentMedian() -> Double {
        let sorted = durations.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
