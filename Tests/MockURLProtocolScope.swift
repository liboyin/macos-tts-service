import Foundation
import os

/// The shared scope registry, private to this file so the URL-protocol half can reach it only
/// through the claim and finish seam and can never mutate scope accounting directly.
private enum ScopeStorage {
    static let condition = NSCondition()
    /// Runs the half of revocation that can block, so the tearing-down thread only waits on a deadline.
    ///
    /// Concurrent because a release half that never returns would otherwise occupy a serial queue
    /// for every later scope, so only its own scope should ever reach the recovery bound.
    static let revocationQueue = DispatchQueue(
        label: "com.clipboardtts.tests.mockurlprotocol.revocation",
        attributes: .concurrent
    )
    /// Confinement invariant: `condition` remains the sole mutual-exclusion and wait/broadcast
    /// primitive for scope state, so every `registry` access below is made while it is held. The
    /// box exists because `NSCondition` is a manual lock the compiler cannot see: it gives the
    /// storage a checked `Sendable` boundary without an unchecked conformance, and because it is
    /// only ever entered under `condition` it is uncontended and adds no second ordering to reason
    /// about. Swift offers no checked-`Sendable` condition variable at this deployment target, so
    /// the wait/broadcast half of the contract stays with `NSCondition`.
    static let registry = OSAllocatedUnfairLock(initialState: ScopeRegistry())

    /// Reads a value out of the scope registry. The caller must already hold `condition`.
    static func readRegistry<Value: Sendable>(_ body: @Sendable (ScopeRegistry) -> Value) -> Value {
        registry.withLock { body($0) }
    }

    /// Updates the scope registry in place. The caller must already hold `condition`.
    static func updateRegistry(_ body: @Sendable (inout ScopeRegistry) -> Void) {
        registry.withLock(body)
    }

    /// The scope new work joins when a caller names none. The caller must already hold `condition`.
    static var activeTestIdentifier: String? {
        get { readRegistry(\.activeTestIdentifier) }
        set { updateRegistry { $0.activeTestIdentifier = newValue } }
    }

    /// Reads one scope's state, or `nil` when the scope is not registered.
    static func state(for testIdentifier: String) -> TestState? {
        readRegistry { $0.testStates[testIdentifier] }
    }

    /// Replaces one scope's state.
    static func setState(_ state: TestState, for testIdentifier: String) {
        updateRegistry { $0.testStates[testIdentifier] = state }
    }

    /// Deregisters a scope that has finished every shutdown step it owed.
    static func removeState(for testIdentifier: String) {
        updateRegistry { $0.testStates.removeValue(forKey: testIdentifier) }
    }
}

extension MockURLProtocol {
    struct TestEndResult {
        let expectedUnhandledRequestCount: Int
        let observedUnhandledRequestCount: Int
        let didQuiesce: Bool
    }

    /// One protocol load a scope has accepted responsibility for draining before it can quiesce.
    struct ClaimedLoad {
        let testIdentifier: String
        let requestHandler: RequestHandler?
    }

    /// Starts an isolated test scope and returns the identifier embedded in its mock sessions.
    static func beginTest() -> String {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        let testIdentifier = UUID().uuidString
        ScopeStorage.activeTestIdentifier = testIdentifier
        ScopeStorage.setState(TestState(), for: testIdentifier)
        return testIdentifier
    }

    /// Returns the identifier that must be embedded in each mock-routed session created by this test.
    static func currentTestIdentifier() -> String {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard let activeTestIdentifier = ScopeStorage.activeTestIdentifier else {
            preconditionFailure("MockURLProtocol test scope has not been started.")
        }
        return activeTestIdentifier
    }

    /// Installs the response handler used by mock-routed requests in the current test.
    static func installRequestHandler(_ handler: @escaping RequestHandler) {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard let activeTestIdentifier = ScopeStorage.activeTestIdentifier,
              var state = ScopeStorage.state(for: activeTestIdentifier) else {
            preconditionFailure("MockURLProtocol test scope has not been started.")
        }
        state.requestHandler = handler
        ScopeStorage.setState(state, for: activeTestIdentifier)
    }

    /// Removes the response handler so a request without an explicit mock fails locally.
    static func reset() {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard let activeTestIdentifier = ScopeStorage.activeTestIdentifier,
              var state = ScopeStorage.state(for: activeTestIdentifier) else { return }
        state.requestHandler = nil
        ScopeStorage.setState(state, for: activeTestIdentifier)
    }

    /// Declares the number of deliberately unhandled requests expected by the current test.
    static func expectUnhandledRequests(_ count: Int = 1) {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard let activeTestIdentifier = ScopeStorage.activeTestIdentifier,
              var state = ScopeStorage.state(for: activeTestIdentifier) else {
            preconditionFailure("MockURLProtocol test scope has not been started.")
        }
        state.expectedUnhandledRequestCount += count
        ScopeStorage.setState(state, for: activeTestIdentifier)
    }

    /// Registers a session so teardown can invalidate it before releasing the test scope.
    static func register(session: URLSession,
                         delegate: (any Sendable)? = nil,
                         forTestIdentifier testIdentifier: String) {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard var state = ScopeStorage.state(for: testIdentifier) else { return }
        guard !state.isClosing else {
            state.unhandledRequestCount += 1
            ScopeStorage.setState(state, for: testIdentifier)
            session.invalidateAndCancel()
            return
        }
        state.sessionRegistrations.append(SessionRegistration(session: session, delegate: delegate))
        ScopeStorage.setState(state, for: testIdentifier)
    }

    /// Records that a registered session can no longer begin new protocol loads.
    static func sessionDidInvalidate(_ session: URLSession, forTestIdentifier testIdentifier: String) {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard var state = ScopeStorage.state(for: testIdentifier) else { return }
        state.sessionRegistrations.removeAll { $0.session === session }
        ScopeStorage.setState(state, for: testIdentifier)
        ScopeStorage.condition.broadcast()
    }

    /// Atomically claims the active scope for a manager initializer before it can read settings.
    static func beginManagerConstructionForCurrentTest() -> String {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard let testIdentifier = ScopeStorage.activeTestIdentifier,
              var state = ScopeStorage.state(for: testIdentifier),
              !state.isClosing else {
            preconditionFailure("MockURLProtocol test scope has not been started.")
        }
        state.activeManagerConstructionCount += 1
        ScopeStorage.setState(state, for: testIdentifier)
        return testIdentifier
    }

    /// Marks a factory-created manager initializer as complete after it has registered its session.
    static func managerConstructionDidFinish(forTestIdentifier testIdentifier: String) {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard var state = ScopeStorage.state(for: testIdentifier) else { return }
        state.activeManagerConstructionCount -= 1
        ScopeStorage.setState(state, for: testIdentifier)
        ScopeStorage.condition.broadcast()
    }

    /// Registers a factory-created manager's delivery queue and cancellation boundary with its test scope.
    ///
    /// `releasePendingDelivery` runs off the tearing-down thread under the scope deadline because it
    /// waits for an in-flight client handler. `finishRevocation` runs on the tearing-down thread
    /// afterwards, where the owner's terminal state can be read and restored without a hop.
    static func register(audioDeliveryQueue: DispatchQueue,
                         releasePendingDelivery: @escaping @Sendable () -> Void,
                         finishRevocation: @escaping @Sendable () -> Void,
                         forTestIdentifier testIdentifier: String) {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard var state = ScopeStorage.state(for: testIdentifier) else { return }
        state.audioDeliveryScopes.append(
            AudioDeliveryScope(
                queue: audioDeliveryQueue,
                releasePendingDelivery: releasePendingDelivery,
                finishRevocation: finishRevocation
            )
        )
        ScopeStorage.setState(state, for: testIdentifier)
    }

    /// Claims one protocol load for the scope that owns it, returning the handler that load may use.
    ///
    /// Returns `nil` when no scope owns the request, which leaves the load unaccounted for and the
    /// caller responsible for failing it locally. A claimed load must be balanced by `finishLoad`.
    static func beginLoad(requestedTestIdentifier: String?) -> ClaimedLoad? {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        let testIdentifier = requestedTestIdentifier ?? ScopeStorage.activeTestIdentifier
        guard let testIdentifier, var state = ScopeStorage.state(for: testIdentifier) else { return nil }

        state.activeLoadCount += 1
        let requestHandler = state.isClosing ? nil : state.requestHandler
        if requestHandler == nil {
            state.unhandledRequestCount += 1
        }
        ScopeStorage.setState(state, for: testIdentifier)
        return ClaimedLoad(testIdentifier: testIdentifier, requestHandler: requestHandler)
    }

    /// Releases a claimed protocol load so its scope can reach quiescence.
    static func finishLoad(forTestIdentifier testIdentifier: String) {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard var state = ScopeStorage.state(for: testIdentifier) else { return }
        state.activeLoadCount -= 1
        ScopeStorage.setState(state, for: testIdentifier)
        ScopeStorage.condition.broadcast()
    }

    /// Invalidates a test's sessions, revokes pending delivery, drains owned queues, and closes the scope.
    static func endTest(identifier: String, timeout: TimeInterval = 2.0) -> TestEndResult {
        ScopeStorage.condition.lock()
        guard var state = ScopeStorage.state(for: identifier) else {
            ScopeStorage.condition.unlock()
            return TestEndResult(expectedUnhandledRequestCount: 0, observedUnhandledRequestCount: 0, didQuiesce: true)
        }
        state.requestHandler = nil
        state.isClosing = true
        let sessions = state.sessionRegistrations.map(\.session)
        ScopeStorage.setState(state, for: identifier)
        ScopeStorage.condition.unlock()

        sessions.forEach { $0.invalidateAndCancel() }

        ScopeStorage.condition.lock()
        advanceClosingScope(identifier: identifier, deadline: Date().addingTimeInterval(timeout))

        guard let completedState = ScopeStorage.state(for: identifier) else {
            ScopeStorage.condition.unlock()
            return TestEndResult(expectedUnhandledRequestCount: 0, observedUnhandledRequestCount: 0, didQuiesce: true)
        }
        let didQuiesce = isQuiescent(completedState)
        if didQuiesce {
            ScopeStorage.removeState(for: identifier)
        }
        if ScopeStorage.activeTestIdentifier == identifier {
            ScopeStorage.activeTestIdentifier = nil
        }
        ScopeStorage.condition.unlock()
        return TestEndResult(
            expectedUnhandledRequestCount: completedState.expectedUnhandledRequestCount,
            observedUnhandledRequestCount: completedState.unhandledRequestCount,
            didQuiesce: didQuiesce
        )
    }

    /// Waits for a closing test scope to drain before removing its shared mock state.
    ///
    /// Bounded by `timeout` because this runs after the tearing-down thread already gave up: the
    /// release it waits for calls into a client handler, and a handler that never returns would
    /// otherwise hold the mock-test gate closed and hang every following mock-network test.
    /// Returns whether the scope quiesced. A scope that did not is left registered, because an
    /// owner this call could not revoke can still deliver into whatever runs next; the caller must
    /// fail the run rather than release the gate.
    static func finishClosingTestWhenQuiescent(identifier: String, timeout: TimeInterval = 5.0) -> Bool {
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        advanceClosingScope(identifier: identifier, deadline: Date().addingTimeInterval(timeout))
        if let state = ScopeStorage.state(for: identifier), !isQuiescent(state) { return false }
        ScopeStorage.removeState(for: identifier)
        if ScopeStorage.activeTestIdentifier == identifier {
            ScopeStorage.activeTestIdentifier = nil
        }
        return true
    }
}

/// Runs the shutdown steps a closing scope still owes, in the order that keeps each one safe.
///
/// The caller must hold the scope condition. Every caller supplies a deadline — the tearing-down
/// thread its scope deadline and the recovery path its own longer bound — so no step can hold a
/// caller indefinitely on an owner that never releases. Steps that call into an owner unlock
/// around the call.
private func advanceClosingScope(identifier: String, deadline: Date) {
    while Date() < deadline, let state = ScopeStorage.state(for: identifier) {
        if hasUndrainedSessionWork(state) {
            waitForScopeChange(until: deadline)
        } else if !state.hasStartedAudioDeliveryRelease {
            startAudioDeliveryRelease(for: identifier, state: state)
        } else if !state.hasReleasedAudioDelivery {
            waitForScopeChange(until: deadline)
        } else if !state.hasRevokedAudioDelivery {
            finishAudioDeliveryRevocation(for: identifier, state: state)
        } else if !state.hasScheduledAudioDeliveryDrains {
            scheduleAudioDeliveryDrains(for: identifier, state: state)
        } else if state.pendingAudioDeliveryDrainCount > 0 {
            waitForScopeChange(until: deadline)
        } else {
            break
        }
    }
}

/// Waits for the next scope-state change, never past the caller's deadline.
private func waitForScopeChange(until deadline: Date) {
    ScopeStorage.condition.wait(until: deadline)
}

/// Starts revoking all manager-owned delivery generations, off the thread that is tearing down.
///
/// This half waits for any in-flight client handler to return, so the caller must be free to stop
/// waiting for it: a handler that never returns would otherwise convert one failing test into a
/// hung suite. Construction can no longer add an owner by the time this runs.
private func startAudioDeliveryRelease(for testIdentifier: String, state: TestState) {
    precondition(!state.hasStartedAudioDeliveryRelease)
    var updatedState = state
    updatedState.hasStartedAudioDeliveryRelease = true
    let releases = state.audioDeliveryScopes.map(\.releasePendingDelivery)
    ScopeStorage.setState(updatedState, for: testIdentifier)
    ScopeStorage.revocationQueue.async {
        releases.forEach { $0() }
        ScopeStorage.condition.lock()
        defer { ScopeStorage.condition.unlock() }

        guard var releasedState = ScopeStorage.state(for: testIdentifier) else { return }
        releasedState.hasReleasedAudioDelivery = true
        ScopeStorage.setState(releasedState, for: testIdentifier)
        ScopeStorage.condition.broadcast()
    }
}

/// Completes revocation on the tearing-down thread once no client handler can hold it up.
///
/// The released generation is already stale, so a delivery still queued behind it can only take
/// callback authority long enough to reject itself. That leaves this step free to run where the
/// owner's main-queue-confined terminal state can be read and restored without a hop, and it
/// advances the generation once more so the release's own queued publications are ignored.
private func finishAudioDeliveryRevocation(for testIdentifier: String, state: TestState) {
    precondition(state.hasReleasedAudioDelivery && !state.hasRevokedAudioDelivery)
    var updatedState = state
    updatedState.hasRevokedAudioDelivery = true
    let revocations = state.audioDeliveryScopes.map(\.finishRevocation)
    ScopeStorage.setState(updatedState, for: testIdentifier)
    ScopeStorage.condition.unlock()
    revocations.forEach { $0() }
    ScopeStorage.condition.lock()
}

/// Adds one ordered drain marker per owned delivery queue after cancellation has revoked its callbacks.
private func scheduleAudioDeliveryDrains(for testIdentifier: String, state: TestState) {
    precondition(!state.hasScheduledAudioDeliveryDrains)
    var updatedState = state
    updatedState.hasScheduledAudioDeliveryDrains = true
    updatedState.pendingAudioDeliveryDrainCount = state.audioDeliveryScopes.count
    let queues = state.audioDeliveryScopes.map(\.queue)
    ScopeStorage.setState(updatedState, for: testIdentifier)
    ScopeStorage.condition.unlock()
    queues.forEach { queue in
        queue.async {
            audioDeliveryQueueDidDrain(forTestIdentifier: testIdentifier)
        }
    }
    ScopeStorage.condition.lock()
}

/// Accounts for one scope-owned delivery queue reaching its teardown drain marker.
private func audioDeliveryQueueDidDrain(forTestIdentifier testIdentifier: String) {
    ScopeStorage.condition.lock()
    defer { ScopeStorage.condition.unlock() }

    guard var state = ScopeStorage.state(for: testIdentifier) else { return }
    state.pendingAudioDeliveryDrainCount -= 1
    ScopeStorage.setState(state, for: testIdentifier)
    ScopeStorage.condition.broadcast()
}
