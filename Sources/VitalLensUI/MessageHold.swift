import Foundation

/// Keeps a hint on screen long enough to read. While a held message is showing, later messages
/// wait and only the most recent one is shown afterwards.
///
/// Keep behaviour in sync with the other VitalLens SDKs.
@MainActor
final class MessageHold {
    private var current: String?
    private var heldUntil: TimeInterval = 0
    private var pending: (text: String, hold: Bool, force: Bool)?
    private var cancelTimer: (() -> Void)?
    
    private let minInterval: TimeInterval
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    private let apply: (String, Bool) -> Void
    
    /// - Parameters:
    ///   - minInterval: How long a held message stays before a later one can replace it.
    ///   - now: The current time, in seconds.
    ///   - schedule: Runs an action after a delay and returns a closure that cancels it.
    ///   - apply: Shows a message. The flag is the `force` value given to `show`.
    init(
        minInterval: TimeInterval = 3,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = MessageHold.defaultSchedule,
        apply: @escaping (String, Bool) -> Void
    ) {
        self.minInterval = minInterval
        self.now = now
        self.schedule = schedule
        self.apply = apply
    }
    
    /// Shows a message, or queues it while a held message is showing.
    ///
    /// - Parameters:
    ///   - text: The message.
    ///   - hold: Keep this message on screen for at least the minimum time.
    ///   - immediate: Show now, dropping any hold and waiting message.
    ///   - force: Passed through to `apply`.
    func show(_ text: String, hold: Bool = false, immediate: Bool = false, force: Bool = false) {
        if immediate {
            release()
            applyNow(text, hold: hold, force: force)
            return
        }
        if now() < heldUntil {
            if text == current {
                clearPending()
            } else {
                pending = (text, hold, force)
                scheduleWaiting()
            }
            return
        }
        applyNow(text, hold: hold, force: force)
    }
    
    /// Drops the hold and any waiting message.
    func release() {
        clearPending()
        heldUntil = 0
    }
    
    private func applyNow(_ text: String, hold: Bool, force: Bool) {
        // Re-showing the same message does not restart its hold
        if text != current {
            current = text
            heldUntil = hold ? now() + minInterval : 0
        }
        apply(text, force)
    }
    
    private func scheduleWaiting() {
        guard cancelTimer == nil else { return }
        cancelTimer = schedule(max(0, heldUntil - now())) { [weak self] in
            guard let self = self else { return }
            self.cancelTimer = nil
            if let next = self.pending {
                self.pending = nil
                self.applyNow(next.text, hold: next.hold, force: next.force)
            }
        }
    }
    
    private func clearPending() {
        pending = nil
        cancelTimer?()
        cancelTimer = nil
    }
    
    /// Runs the action on the main actor after `delay` seconds.
    nonisolated static func defaultSchedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }
}
