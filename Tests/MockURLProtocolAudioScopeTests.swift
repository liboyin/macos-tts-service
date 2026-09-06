import XCTest
@testable import ClipboardTTSApp

final class MockURLProtocolAudioScopeTests: XCTestCase {
    func testClosingScopeRevokesBlockedAudioDeliveryBeforeClosingItOrStartingTheNextScope() {
        // WHY: A URL-session drain alone cannot prove that a handler queued behind a blocked
        // delivery queue will not escape into a later test scope.
        MockURLProtocolTestCase.testExecutionLock.lock()
        let acquiredTestExecutionGate = MockURLProtocolTestCase.enterTestExecutionGate()
        var activeTestIdentifier: String?
        let audioDeliveryQueue = DispatchQueue(label: "com.clipboardtts.tests.scope-owned-delivery")
        let releaseDelivery = DispatchSemaphore(value: 0)
        let releaseResponse = DispatchSemaphore(value: 0)
        defer {
            releaseResponse.signal()
            releaseDelivery.signal()
            if let activeTestIdentifier {
                let endResult = MockURLProtocol.endTest(identifier: activeTestIdentifier, timeout: 1.0)
                if !endResult.didQuiesce {
                    MockURLProtocolTestCase.finishClosingScopeOrEndRun(identifier: activeTestIdentifier)
                }
            }
            if acquiredTestExecutionGate {
                MockURLProtocolTestCase.leaveTestExecutionGate()
            }
            MockURLProtocolTestCase.testExecutionLock.unlock()
        }

        activeTestIdentifier = MockURLProtocol.beginTest()

        let deliveryBlocked = expectation(description: "Owned audio delivery queue is blocked")
        audioDeliveryQueue.async {
            deliveryBlocked.fulfill()
            _ = releaseDelivery.wait(timeout: .now() + 2.0)
        }
        wait(for: [deliveryBlocked], timeout: 1.0)

        let manager = TestNetworkFactory.makeManager(audioDeliveryQueue: audioDeliveryQueue)
        manager.updateSettings(
            baseURL: "https://mock.api/v1/audio/speech",
            apiKey: "test",
            model: "test",
            voice: "test",
            selectedProvider: "OpenAI"
        )
        let requestStarted = expectation(description: "Request started before queuing audio")
        let responseReleased = expectation(description: "Mock response was released")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            responseReleased.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, nil)
        }

        let callbackRan = LockedValue(false)
        manager.streamTTS(text: "scope-owned queued audio") { _ in
            callbackRan.withValue { $0 = true }
        }
        wait(for: [requestStarted], timeout: 1.0)
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected the manager to own a task before queuing test audio.")
            return
        }
        manager.urlSession(manager.session, dataTask: task, didReceive: Data([0, 1]))
        assertTerminalState(of: manager, expectedError: nil) {
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
        }
        releaseResponse.signal()
        wait(for: [responseReleased], timeout: 1.0)

        guard let testIdentifier = activeTestIdentifier else {
            XCTFail("Expected the manual mock scope to remain active.")
            return
        }
        let endResult = MockURLProtocol.endTest(identifier: testIdentifier, timeout: 0.2)
        activeTestIdentifier = nil
        XCTAssertFalse(endResult.didQuiesce, "A blocked owned delivery queue must keep the scope from closing.")

        let scopeClosed = expectation(description: "Scope closes after owned delivery drains")
        DispatchQueue.global(qos: .userInitiated).async {
            MockURLProtocolTestCase.finishClosingScopeOrEndRun(identifier: testIdentifier)
            scopeClosed.fulfill()
        }
        releaseDelivery.signal()
        wait(for: [scopeClosed], timeout: 1.0)

        activeTestIdentifier = MockURLProtocol.beginTest()
        audioDeliveryQueue.sync {}
        XCTAssertFalse(callbackRan.value, "A revoked handler must not run once its scope closed, nor in the next test scope.")
        let nextScopeEndResult = MockURLProtocol.endTest(identifier: activeTestIdentifier!, timeout: 1.0)
        XCTAssertTrue(nextScopeEndResult.didQuiesce)
        activeTestIdentifier = nil
    }

    func testClosingScopeStopsWaitingForARevocationAnInFlightHandlerHoldsUp() {
        // WHY: Revocation runs `stopStreaming`, which waits for an in-flight client handler to
        // return — see TTSNetworkManagerCallbackAuthorityTests. Running that on the tearing-down
        // thread left it outside the scope deadline, so a handler that never returned turned one
        // failing test into a hung suite: the failure class this bounded lifecycle exists to end.
        MockURLProtocolTestCase.testExecutionLock.lock()
        let acquiredTestExecutionGate = MockURLProtocolTestCase.enterTestExecutionGate()
        let releaseRevocation = DispatchSemaphore(value: 0)
        var activeTestIdentifier: String?
        defer {
            releaseRevocation.signal()
            if let activeTestIdentifier {
                MockURLProtocolTestCase.finishClosingScopeOrEndRun(identifier: activeTestIdentifier)
            }
            if acquiredTestExecutionGate {
                MockURLProtocolTestCase.leaveTestExecutionGate()
            }
            MockURLProtocolTestCase.testExecutionLock.unlock()
        }

        let testIdentifier = MockURLProtocol.beginTest()
        activeTestIdentifier = testIdentifier
        let revocationStarted = expectation(description: "Blocked revocation started")
        let revocationSteps = LockedValue<[String]>([])
        MockURLProtocol.register(
            audioDeliveryQueue: DispatchQueue(label: "com.clipboardtts.tests.blocked-revocation"),
            releasePendingDelivery: {
                revocationSteps.withValue { $0.append("release") }
                revocationStarted.fulfill()
                _ = releaseRevocation.wait(timeout: .now() + 5.0)
            },
            finishRevocation: {
                revocationSteps.withValue { $0.append("finish") }
            },
            forTestIdentifier: testIdentifier
        )
        let startedAt = Date()
        let endResult = MockURLProtocol.endTest(identifier: testIdentifier, timeout: 0.2)
        let elapsed = Date().timeIntervalSince(startedAt)
        wait(for: [revocationStarted], timeout: 1.0)

        XCTAssertFalse(endResult.didQuiesce, "A revocation still holding an owner must leave the scope non-quiescent.")
        XCTAssertLessThan(
            elapsed,
            2.0,
            "Teardown must stop waiting for a blocked revocation at the scope deadline, not for the handler."
        )
        XCTAssertEqual(
            revocationSteps.value,
            ["release"],
            "Teardown must not run the tearing-down-thread half while the blocking half still owns the manager."
        )

        releaseRevocation.signal()
        let scopeClosed = expectation(description: "Scope closes once the revocation returns")
        DispatchQueue.global(qos: .userInitiated).async {
            MockURLProtocolTestCase.finishClosingScopeOrEndRun(identifier: testIdentifier)
            scopeClosed.fulfill()
        }
        wait(for: [scopeClosed], timeout: 5.0)
        activeTestIdentifier = nil
        XCTAssertEqual(revocationSteps.value, ["release", "finish"], "Recovery must finish the revocation it could not bound.")
    }

    func testQuiescedScopeKeepsTheOwnerTerminalStateAheadOfItsOwnRevocationPublications() {
        // WHY: The blocking half of revocation runs off the tearing-down thread, so its
        // `stopStreaming` publishes `lastError` and `isStreaming` through the main queue instead of
        // inline. Those publications clear the terminal error. Teardown must advance the generation
        // past them on the tearing-down thread, or they land in a later test and erase state that
        // this test's post-quiescence assertions just read.
        MockURLProtocolTestCase.testExecutionLock.lock()
        let acquiredTestExecutionGate = MockURLProtocolTestCase.enterTestExecutionGate()
        let audioDeliveryQueue = DispatchQueue(label: "com.clipboardtts.tests.quiesced-scope-delivery")
        let releaseResponse = DispatchSemaphore(value: 0)
        var activeTestIdentifier: String?
        defer {
            releaseResponse.signal()
            if let activeTestIdentifier {
                let endResult = MockURLProtocol.endTest(identifier: activeTestIdentifier, timeout: 2.0)
                if !endResult.didQuiesce {
                    MockURLProtocolTestCase.finishClosingScopeOrEndRun(identifier: activeTestIdentifier)
                }
            }
            if acquiredTestExecutionGate {
                MockURLProtocolTestCase.leaveTestExecutionGate()
            }
            MockURLProtocolTestCase.testExecutionLock.unlock()
        }

        activeTestIdentifier = MockURLProtocol.beginTest()

        let manager = TestNetworkFactory.makeManager(audioDeliveryQueue: audioDeliveryQueue)
        manager.updateSettings(
            baseURL: "https://mock.api/v1/audio/speech",
            apiKey: "test",
            model: "test",
            voice: "test",
            selectedProvider: "OpenAI"
        )
        let requestStarted = expectation(description: "Request started before queuing audio")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, nil)
        }

        manager.streamTTS(text: "quiesced scope delivery") { _ in }
        wait(for: [requestStarted], timeout: 1.0)
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected the manager to own a task before queuing test audio.")
            return
        }
        let terminalError = "The TTS service returned no playable audio. Please try again."
        manager.urlSession(manager.session, dataTask: task, didReceive: Data([0]))
        assertTerminalState(of: manager, expectedError: terminalError) {
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
        }
        releaseResponse.signal()

        guard let testIdentifier = activeTestIdentifier else {
            XCTFail("Expected the manual mock scope to remain active.")
            return
        }
        let endResult = MockURLProtocol.endTest(identifier: testIdentifier, timeout: 2.0)
        activeTestIdentifier = nil
        XCTAssertTrue(endResult.didQuiesce, "A scope whose delivery is not blocked must drain inside its deadline.")
        XCTAssertEqual(manager.lastError, terminalError, "Teardown must preserve the terminal error it revoked around.")

        let mainQueueDrained = expectation(description: "Main queue drained after the scope closed")
        DispatchQueue.main.async { mainQueueDrained.fulfill() }
        wait(for: [mainQueueDrained], timeout: 1.0)
        XCTAssertEqual(
            manager.lastError,
            terminalError,
            "A publication queued by the blocking half of revocation must be stale by the time the main queue runs it."
        )
        XCTAssertFalse(manager.isStreaming)
    }
}
