import Combine
import XCTest
@testable import ClipboardTTSApp

/// Covers the recovery path that runs off the tearing-down thread after a scope missed its deadline.
///
/// `MockURLProtocolAudioScopeTests` owns what closing a scope revokes; this file owns what recovery
/// may take, and what it may leave behind, once the tearing-down thread has already given up.
final class MockURLProtocolRecoveryTests: XCTestCase {
    func testRecoveryStopsWaitingForARevocationThatNeverReturns() {
        // WHY: Recovery holds the mock-test gate closed while it waits, and the release it waits
        // for calls a client handler. Waiting without a bound
        // turned a handler that never returns into a suite that hangs in a later test's gate
        // acquisition, where nothing points back at the scope that caused it.
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
            audioDeliveryQueue: DispatchQueue(label: "com.clipboardtts.tests.unbounded-revocation"),
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
        XCTAssertFalse(MockURLProtocol.endTest(identifier: testIdentifier, timeout: 0.2).didQuiesce)
        wait(for: [revocationStarted], timeout: 1.0)

        let startedAt = Date()
        let didClose = MockURLProtocol.finishClosingTestWhenQuiescent(identifier: testIdentifier, timeout: 0.3)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertFalse(didClose, "Recovery must report a scope it could not revoke instead of closing it.")
        XCTAssertLessThan(
            elapsed,
            2.0,
            "Recovery must stop waiting at its own bound rather than for a handler that never returns."
        )

        releaseRevocation.signal()
        let scopeClosed = expectation(description: "Scope closes once the revocation returns")
        DispatchQueue.global(qos: .userInitiated).async {
            MockURLProtocolTestCase.finishClosingScopeOrEndRun(identifier: testIdentifier)
            scopeClosed.fulfill()
        }
        wait(for: [scopeClosed], timeout: 5.0)
        activeTestIdentifier = nil
        XCTAssertEqual(
            revocationSteps.value,
            ["release", "finish"],
            "A scope the bound gave up on must keep its owner, so its finishing half still runs."
        )
    }

    func testBackgroundDeliveryRevocationQueuesNoPublicationIntoALaterTest() {
        // WHY: Recovery revokes off-main, where `stopStreaming()` queues `clearLastError` and
        // `setStreaming` to the main queue at the generation it has just advanced to. Nothing can
        // make those stale, so they run after the scope is released and erase the terminal state
        // the finished test asserted — inside whichever test is running by then.
        MockURLProtocolTestCase.testExecutionLock.lock()
        let acquiredTestExecutionGate = MockURLProtocolTestCase.enterTestExecutionGate()
        var activeTestIdentifier: String?
        defer {
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
        let manager = TestNetworkFactory.makeManager()
        let terminalError = "The TTS service returned no playable audio. Please try again."
        manager.publishFailure(terminalError)

        let publicationCount = LockedValue(0)
        let subscription = manager.objectWillChange.sink { _ in
            publicationCount.withValue { $0 += 1 }
        }
        defer { subscription.cancel() }

        let revocationFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            TestNetworkFactory.revokePendingDelivery(for: manager)
            revocationFinished.signal()
        }
        XCTAssertEqual(
            revocationFinished.wait(timeout: .now() + 1.0),
            .success,
            "Off-main revocation must finish without waiting for main-thread service."
        )

        let mainQueueDrained = expectation(description: "Main queue drained after off-main revocation")
        DispatchQueue.main.async { mainQueueDrained.fulfill() }
        wait(for: [mainQueueDrained], timeout: 1.0)

        let observedPublications = publicationCount.value
        XCTAssertEqual(
            observedPublications,
            0,
            "Off-main revocation must leave nothing on the main queue that a later test could observe."
        )
        XCTAssertEqual(
            manager.lastError,
            terminalError,
            "Recovery must not erase the terminal state its own test read after quiescence."
        )
    }

    func testBackgroundDeliveryRevocationDoesNotWaitForTheMainThread() {
        // WHY: Timeout recovery runs off-main while the tearing-down thread can be waiting on the
        // main thread. Revocation must advance callback authority without a cycle.
        MockURLProtocolTestCase.testExecutionLock.lock()
        let acquiredTestExecutionGate = MockURLProtocolTestCase.enterTestExecutionGate()
        var activeTestIdentifier: String?
        let audioDeliveryQueue = DispatchQueue(label: "com.clipboardtts.tests.background-revocation")
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
        let deliveryBlocked = expectation(description: "Background revocation delivery queue is blocked")
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
        let requestStarted = expectation(description: "Request is active during background revocation")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, nil)
        }

        let callbackRan = LockedValue(false)
        manager.streamTTS(text: "background teardown") { _ in
            callbackRan.withValue { $0 = true }
        }
        wait(for: [requestStarted], timeout: 1.0)
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected an active task before testing background delivery revocation.")
            return
        }
        manager.urlSession(manager.session, dataTask: task, didReceive: Data([0, 1]))

        let backgroundRevocationFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            TestNetworkFactory.revokePendingDelivery(for: manager)
            backgroundRevocationFinished.signal()
        }
        XCTAssertEqual(
            backgroundRevocationFinished.wait(timeout: .now() + 1.0),
            .success,
            "Background teardown must revoke delivery without waiting for main-thread service."
        )

        releaseDelivery.signal()
        audioDeliveryQueue.sync {}
        XCTAssertFalse(callbackRan.value, "Background revocation must invalidate queued delivery before it runs.")
        releaseResponse.signal()
    }
}
