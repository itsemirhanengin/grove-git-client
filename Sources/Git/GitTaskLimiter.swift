import Foundation

/// Caps how many `git` processes Grove runs at once.
///
/// Without a cap, refreshing a workspace of twenty repositories forks twenty
/// gits simultaneously; each is dominated by process startup and disk I/O, so
/// they mostly slow each other down. A modest cap finishes the same work sooner
/// and keeps the machine responsive.
///
/// The slot is handed **directly** from a finishing caller to the next waiter
/// rather than being released and re-acquired. Releasing first would open a
/// window in which a fresh caller could take the slot ahead of a task that had
/// already been queued, letting the count briefly exceed capacity.
///
/// Waiting is deliberately not cancellable. Unwinding a queued waiter correctly
/// requires tracking whether a slot had already been transferred to it, and
/// getting that wrong leaks capacity permanently — a bug that only shows up as
/// the app mysteriously refusing to run git after a while. Cancellation is
/// handled where it actually matters instead: `ProcessRunner` kills the running
/// process, and a cancelled task that reaches the front of the queue observes
/// cancellation as soon as its body starts. Slots turn over in milliseconds, so
/// the wait is bounded in practice.
actor GitTaskLimiter {

    private let capacity: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(capacity: Int? = nil) {
        let suggested = ProcessInfo.processInfo.activeProcessorCount / 2
        self.capacity = capacity ?? min(max(suggested, 4), 8)
    }

    var availableSlots: Int { max(0, capacity - active) }
    var queueDepth: Int { waiters.count }
    var activeCount: Int { active }

    func withSlot<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        // Queue even when a slot looks free if others are already waiting, so
        // the order stays fair.
        if active < capacity, waiters.isEmpty {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        // No increment here: `release` transferred its slot to us.
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            // Hand the slot straight over; `active` stays the same.
            waiters.removeFirst().resume()
        }
    }
}
