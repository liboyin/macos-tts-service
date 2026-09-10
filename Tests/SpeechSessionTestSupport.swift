import Foundation
@testable import ClipboardTTSApp

// Test doubles shared by the suites that observe a speech session's handoff. They live here
// rather than beside one suite because the session owner's tests and the network manager's
// termination tests both watch the same two things: what a client was handed, and whether a
// revocation genuinely had to wait for an authorized callback.

/// Records what one session's client received, in the order it received it.
///
/// Both halves of the handoff arrive on the manager's audio-delivery queue and are read on the test
/// thread, so the log owns its value rather than leaving a `var` for a `@Sendable` client to mutate.
final class SessionEventLog: @unchecked Sendable {
    /// What a client was handed, reduced to what order assertions need to distinguish.
    enum Event: Equatable {
        case audio(Data)
        case terminated(SpeechStreamTermination)
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func record(_ event: Event) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    var recorded: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

/// A recursive callback authority that reports when a caller has to wait for authority somebody
/// else holds.
///
/// `RecursiveCallbackAuthority` cannot distinguish a revocation that returned because it waited
/// from one that returned because there was nothing to wait for, and that difference is the whole
/// guarantee. Trying the lock first separates them: only a failed attempt means another thread is
/// inside an authorized callback. The observer is armed for one wait at a time, so an unrelated
/// uncontended acquisition earlier in a test cannot satisfy the wait a test is watching for.
final class WaitObservingCallbackAuthority: CallbackAuthorityLocking, @unchecked Sendable {
    private let recursiveLock = NSRecursiveLock()
    private let pendingObserver = LockedValue<(@Sendable () -> Void)?>(nil)

    /// Reports the next contended acquisition, once.
    func observeNextWait(_ body: @escaping @Sendable () -> Void) {
        pendingObserver.withValue { $0 = body }
    }

    func lock() {
        if recursiveLock.`try`() { return }
        let observer = pendingObserver.withValue { pending -> (@Sendable () -> Void)? in
            defer { pending = nil }
            return pending
        }
        observer?()
        recursiveLock.lock()
    }

    func unlock() {
        recursiveLock.unlock()
    }
}
