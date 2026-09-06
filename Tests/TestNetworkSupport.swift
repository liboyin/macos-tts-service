import Foundation
import XCTest
import AppKit
import Combine
@testable import ClipboardTTSApp

/// Returns a request body whether URLSession retained it as data or exposed it as a stream.
func requestBodyData(from request: URLRequest) -> Data? {
    if let httpBody = request.httpBody {
        return httpBody
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
        let bytesRead = stream.read(&buffer, maxLength: buffer.count)
        guard bytesRead > 0 else { break }
        body.append(buffer, count: bytesRead)
    }
    return body
}

/// Creates sessions and network managers whose requests are always routed through MockURLProtocol.
enum TestNetworkFactory {
    /// Creates a mock-routed manager. `defaults` is fresh test-owned storage unless the caller
    /// passes its own, so a manager reads and migrates nothing the developer configured, and a test
    /// that must share one domain between the manager and a hosted form passes that domain here.
    static func makeManager(
        secretStore: SecretStoring = InMemorySecretStore(),
        defaults: UserDefaults = InMemoryDefaults(),
        requestBodyEncoder: @escaping (Data) throws -> Data = { $0 },
        audioDeliveryQueue: DispatchQueue = DispatchQueue(label: "com.clipboardtts.tests.audiodelivery"),
        callbackAuthority: CallbackAuthorityLocking = RecursiveCallbackAuthority()
    ) -> TTSNetworkManager {
        let testIdentifier = MockURLProtocol.beginManagerConstructionForCurrentTest()
        defer { MockURLProtocol.managerConstructionDidFinish(forTestIdentifier: testIdentifier) }
        let manager = TTSNetworkManager(
            configuration: makeConfiguration(testIdentifier: testIdentifier),
            sessionCreated: { MockURLProtocol.register(session: $0, forTestIdentifier: testIdentifier) },
            sessionInvalidated: { MockURLProtocol.sessionDidInvalidate($0, forTestIdentifier: testIdentifier) },
            secretStore: secretStore,
            defaults: defaults,
            requestBodyEncoder: requestBodyEncoder,
            audioDeliveryQueue: audioDeliveryQueue,
            callbackAuthority: callbackAuthority
        )
        MockURLProtocol.register(
            audioDeliveryQueue: audioDeliveryQueue,
            releasePendingDelivery: { manager.stopStreaming() },
            finishRevocation: { revokePendingDelivery(for: manager) },
            forTestIdentifier: testIdentifier
        )
        return manager
    }

    /// Revokes queued callbacks while preserving a terminal error during main-thread teardown.
    static func revokePendingDelivery(for manager: TTSNetworkManager) {
        guard Thread.isMainThread else {
            // Timeout recovery must neither wait for a main thread that is waiting for it nor
            // leave a publication behind on it. `revokeActiveRequest()` advances the generation
            // synchronously and queues nothing, so the manager keeps whatever terminal state its
            // test observed and can no longer authorize a callback.
            manager.revokeActiveRequest()
            return
        }
        let cancel: @Sendable () -> Void = {
            let terminalError = manager.lastError
            manager.stopStreaming()
            if let terminalError {
                manager.publishFailure(terminalError)
            }
        }
        cancel()
    }

    static func makeSession() -> URLSession {
        let testIdentifier = MockURLProtocol.currentTestIdentifier()
        let delegate = TestSessionDelegate(testIdentifier: testIdentifier)
        let session = URLSession(
            configuration: makeConfiguration(testIdentifier: testIdentifier),
            delegate: delegate,
            delegateQueue: nil
        )
        MockURLProtocol.register(session: session, delegate: delegate, forTestIdentifier: testIdentifier)
        return session
    }

    private static func makeConfiguration(testIdentifier: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpAdditionalHeaders = [
            MockURLProtocol.testIdentifierHeader: testIdentifier
        ]
        return configuration
    }
}

/// Signals when a factory-created session has invalidated, completing its test scope's barrier.
private final class TestSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    private let testIdentifier: String

    init(testIdentifier: String) {
        self.testIdentifier = testIdentifier
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        MockURLProtocol.sessionDidInvalidate(session, forTestIdentifier: testIdentifier)
    }
}

/// Serializes tests using MockURLProtocol and clears its process-global handler at each boundary.
class MockURLProtocolTestCase: XCTestCase {
    private static let testExecutionGate = DispatchSemaphore(value: 1)
    private static let testExecutionGateDepthKey = "com.clipboardtts.tests.mockurlprotocol.gatedepth"
    static let testExecutionLock = NSRecursiveLock()
    private var testIdentifier: String?
    private var acquiredTestExecutionGate = false
    private var postQuiescenceAssertions: [() -> Void] = []

    /// Queues an assertion that runs after the mock scope has revoked and drained owned delivery work.
    func assertAfterMockQuiescence(_ assertion: @escaping () -> Void) {
        postQuiescenceAssertions.append(assertion)
    }

    override func setUp() {
        super.setUp()
        MockURLProtocolTestCase.testExecutionLock.lock()
        acquiredTestExecutionGate = MockURLProtocolTestCase.enterTestExecutionGate()
        testIdentifier = MockURLProtocol.beginTest()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        guard let testIdentifier else {
            XCTFail("MockURLProtocol test scope was not created.")
            MockURLProtocolTestCase.leaveTestExecutionGate()
            MockURLProtocolTestCase.testExecutionLock.unlock()
            super.tearDown()
            return
        }

        MockURLProtocol.reset()
        let unhandledRequests = MockURLProtocol.endTest(identifier: testIdentifier)
        XCTAssertTrue(
            unhandledRequests.didQuiesce,
            "Mock-routed sessions, protocol loads, manager construction, or audio delivery did not finish before the test scope ended."
        )
        XCTAssertEqual(
            unhandledRequests.observedUnhandledRequestCount,
            unhandledRequests.expectedUnhandledRequestCount,
            "Unexpected mock-routed request without an installed handler."
        )
        if unhandledRequests.didQuiesce {
            postQuiescenceAssertions.forEach { $0() }
            MockURLProtocolTestCase.leaveTestExecutionGate()
        } else {
            if acquiredTestExecutionGate {
                MockURLProtocolTestCase.abandonTestExecutionGateUntilRecovery()
            } else {
                MockURLProtocolTestCase.leaveTestExecutionGate()
            }
            let shouldReleaseGateAfterRecovery = acquiredTestExecutionGate
            DispatchQueue.global(qos: .userInitiated).async {
                MockURLProtocolTestCase.finishClosingScopeOrEndRun(identifier: testIdentifier)
                if shouldReleaseGateAfterRecovery {
                    MockURLProtocolTestCase.testExecutionGate.signal()
                }
            }
        }
        postQuiescenceAssertions.removeAll()
        self.testIdentifier = nil
        MockURLProtocolTestCase.testExecutionLock.unlock()
        super.tearDown()
    }

    /// Finishes a closing scope, ending the run when the recovery bound expires instead.
    ///
    /// Every caller is about to release the mock-test gate, and a scope that did not quiesce still
    /// owns work that can deliver into whatever runs next: there is nothing safe to hand the
    /// following test, so the run ends where the cause is still visible.
    /// Use `MockURLProtocol.finishClosingTestWhenQuiescent` directly only to observe that bound.
    static func finishClosingScopeOrEndRun(identifier: String) {
        guard MockURLProtocol.finishClosingTestWhenQuiescent(identifier: identifier) else {
            fatalError(
                """
                Mock test scope \(identifier) did not quiesce within the recovery bound: session, \
                protocol-load, manager-construction, delivery-revocation, or delivery-queue work is \
                still outstanding. The mock-test gate stays closed rather than hand a live \
                callback owner to the next test.
                """
            )
        }
    }

    /// Enters the process-wide mock-test gate, supporting the nested lifecycle test scope.
    static func enterTestExecutionGate() -> Bool {
        let threadDictionary = Thread.current.threadDictionary
        let depth = threadDictionary[testExecutionGateDepthKey] as? Int ?? 0
        if depth == 0 {
            testExecutionGate.wait()
        }
        threadDictionary[testExecutionGateDepthKey] = depth + 1
        return depth == 0
    }

    /// Leaves one nested mock-test gate scope, releasing the next test at the outermost boundary.
    static func leaveTestExecutionGate() {
        let threadDictionary = Thread.current.threadDictionary
        let depth = threadDictionary[testExecutionGateDepthKey] as? Int ?? 0
        precondition(depth > 0, "MockURLProtocol test gate was released without a matching acquisition.")
        if depth == 1 {
            threadDictionary.removeObject(forKey: testExecutionGateDepthKey)
            testExecutionGate.signal()
        } else {
            threadDictionary[testExecutionGateDepthKey] = depth - 1
        }
    }

    /// Removes the current thread's gate ownership while an asynchronous timeout recovery retains it.
    static func abandonTestExecutionGateUntilRecovery() {
        let threadDictionary = Thread.current.threadDictionary
        let depth = threadDictionary[testExecutionGateDepthKey] as? Int ?? 0
        precondition(depth == 1, "Only an outermost mock-test scope can defer its gate release.")
        threadDictionary.removeObject(forKey: testExecutionGateDepthKey)
    }
}

final class MockURLProtocolConstructionTests: XCTestCase {
    func testClosingScopeWaitsForManagerInitializationBeforeItCanQuiesce() {
        // WHY: TTSNetworkManager reads and migrates settings before it registers its URLSession.
        // Treating that interval as quiescent would release the mock-test gate while migration is
        // still active, letting the late initializer run inside the next test's scope.
        MockURLProtocolTestCase.testExecutionLock.lock()
        let acquiredTestExecutionGate = MockURLProtocolTestCase.enterTestExecutionGate()
        defer {
            if acquiredTestExecutionGate {
                MockURLProtocolTestCase.leaveTestExecutionGate()
            }
            MockURLProtocolTestCase.testExecutionLock.unlock()
        }

        let testIdentifier = MockURLProtocol.beginTest()
        _ = MockURLProtocol.beginManagerConstructionForCurrentTest()

        let endResult = MockURLProtocol.endTest(identifier: testIdentifier, timeout: 0)

        XCTAssertFalse(endResult.didQuiesce, "An initializing manager must keep its scope from closing.")
        MockURLProtocol.managerConstructionDidFinish(forTestIdentifier: testIdentifier)
        MockURLProtocolTestCase.finishClosingScopeOrEndRun(identifier: testIdentifier)
    }

    func testClosingScopeRevokesAudioOwnerRegisteredDuringManagerConstruction() {
        // WHY: A manager claims construction before it registers its queue. Closing in that
        // interval must still revoke the newly registered owner before releasing the scope.
        MockURLProtocolTestCase.testExecutionLock.lock()
        let acquiredTestExecutionGate = MockURLProtocolTestCase.enterTestExecutionGate()
        defer {
            if acquiredTestExecutionGate {
                MockURLProtocolTestCase.leaveTestExecutionGate()
            }
            MockURLProtocolTestCase.testExecutionLock.unlock()
        }

        let testIdentifier = MockURLProtocol.beginTest()
        _ = MockURLProtocol.beginManagerConstructionForCurrentTest()
        let endResult = MockURLProtocol.endTest(identifier: testIdentifier, timeout: 0)
        XCTAssertFalse(endResult.didQuiesce)

        let revocationSteps = LockedValue<[String]>([])
        MockURLProtocol.register(
            audioDeliveryQueue: DispatchQueue(label: "com.clipboardtts.tests.late-delivery-owner"),
            releasePendingDelivery: {
                revocationSteps.withValue { $0.append("release") }
            },
            finishRevocation: {
                revocationSteps.withValue { $0.append("finish") }
            },
            forTestIdentifier: testIdentifier
        )
        MockURLProtocol.managerConstructionDidFinish(forTestIdentifier: testIdentifier)
        MockURLProtocolTestCase.finishClosingScopeOrEndRun(identifier: testIdentifier)

        XCTAssertEqual(
            revocationSteps.value,
            ["release", "finish"],
            "A late-registered owner must be released before teardown finishes its revocation."
        )
    }
}

final class FakePasteboardReader: PasteboardReading {
    private let text: String?
    /// Counts reads so a test can prove a dropped clipboard action never touched the pasteboard.
    /// Written and read on the main queue, where the menu's clipboard flow runs.
    private(set) var readCount = 0

    init(text: String? = nil) {
        self.text = text
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        readCount += 1
        return text
    }
}
