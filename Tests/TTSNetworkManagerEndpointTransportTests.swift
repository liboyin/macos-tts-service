import XCTest
@testable import ClipboardTTSApp

/// Covers what the endpoint transport rule does to a real request: which endpoints still send the
/// complete contract, and which are refused before a task or a credential can exist.
/// `EndpointTransportPolicyTests` owns the rule itself.
final class TTSNetworkManagerEndpointTransportTests: MockURLProtocolTestCase {
    private static let insecureTransportError =
        "The TTS endpoint must use HTTPS unless it runs on localhost. Update Settings and try again."
    private static let invalidConfigurationError =
        "TTS configuration is invalid. Check the API endpoint and try again."

    func testHTTPSAndLoopbackCustomEndpointsSendTheCompleteRequestContract() {
        // WHY: Refusing cleartext must not quietly narrow what a supported Custom endpoint may be.
        // HTTPS and a loopback local engine both still send the whole documented contract, key
        // included, so the rule cannot be "satisfied" by dropping requests the user expects to run.
        let endpoints = [
            "https://custom.api/v1/audio/speech",
            "http://localhost:8080/v1/audio/speech",
            "http://127.0.0.1:8080/v1/audio/speech",
            "http://[::1]:8080/v1/audio/speech"
        ]

        for endpoint in endpoints {
            let manager = TestNetworkFactory.makeManager()
            manager.updateSettings(
                baseURL: endpoint,
                apiKey: "test-custom-api-key",
                model: "test-model",
                voice: "test-voice",
                selectedProvider: "Custom"
            )
            let requestEmitted = expectation(description: "\(endpoint) emits its request")
            MockURLProtocol.installRequestHandler { request in
                XCTAssertEqual(request.url?.absoluteString, endpoint)
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-custom-api-key")
                XCTAssertFalse(request.url?.absoluteString.contains("test-custom-api-key") ?? true)
                let body = requestBodyData(from: request)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String]
                XCTAssertEqual(body?["model"], "test-model")
                XCTAssertEqual(body?["voice"], "test-voice")
                XCTAssertEqual(body?["input"], "Speak through \(endpoint)")
                XCTAssertEqual(body?["response_format"], "pcm")
                requestEmitted.fulfill()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data([0, 1]))
            }

            manager.streamTTS(text: "Speak through \(endpoint)") { _ in }
            wait(for: [requestEmitted], timeout: 2.0)
        }
    }

    func testCleartextEndpointsAreRefusedBeforeAnyRequestOrCredentialLeaves() {
        // WHY: A cleartext remote endpoint would put the saved key and the user's clipboard text on
        // the wire, so the app must refuse it itself, before a task exists, rather than rely on a
        // transport layer it does not configure. Each entry reaches a host that is not this
        // machine's loopback interface, however local it reads. No handler is installed here: this
        // scope's unhandled-request accounting fails the test if any of them creates a request.
        let key = "conspicuous-cleartext-key-4242"
        let refusals = [
            (endpoint: "http://tts.example.com/v1/audio/speech",
             provider: "Custom", message: Self.insecureTransportError),
            (endpoint: "http://192.168.1.10:8080/v1/audio/speech",
             provider: "Custom", message: Self.insecureTransportError),
            (endpoint: "http://localhost.example.com/v1/audio/speech",
             provider: "Custom", message: Self.insecureTransportError),
            (endpoint: "http://127.0.0.1.example.com/v1/audio/speech",
             provider: "Custom", message: Self.insecureTransportError),
            (endpoint: "http://127.0.0.1@example.com/v1/audio/speech",
             provider: "Custom", message: Self.insecureTransportError),
            (endpoint: "http://generativelanguage.googleapis.com/v1beta",
             provider: "Gemini", message: Self.insecureTransportError),
            (endpoint: "http:///v1/audio/speech",
             provider: "Custom", message: Self.invalidConfigurationError),
            (endpoint: "ftp://localhost/v1/audio/speech",
             provider: "Custom", message: Self.invalidConfigurationError)
        ]

        for refusal in refusals {
            let defaults = makeOwnedDefaults()
            let manager = TestNetworkFactory.makeManager(defaults: defaults)
            manager.updateSettings(
                baseURL: refusal.endpoint,
                apiKey: key,
                model: "test-model",
                voice: "test-voice",
                selectedProvider: refusal.provider
            )

            manager.streamTTS(text: "Speak through \(refusal.endpoint)") { _ in
                XCTFail("A refused endpoint must not produce audio.")
            }

            XCTAssertEqual(manager.lastError, refusal.message, "\(refusal.endpoint) must publish its own refusal.")
            XCTAssertFalse(manager.isStreaming, "\(refusal.endpoint) must not report an active stream.")
            XCTAssertFalse(manager.lastError?.contains(key) ?? true, "A refusal must not disclose the key.")
            XCTAssertFalse(
                manager.lastError?.contains(refusal.endpoint) ?? true,
                "A refusal must not echo a user-controlled endpoint."
            )
            XCTAssertFalse(
                SettingsKeys.allUserDefaultsKeys.contains { defaults.string(forKey: $0) == key },
                "A refused request must not leave the key it would have carried in preferences."
            )
        }
    }

    func testACleartextRedirectIsRefusedAndReportedAsATransportFailure() {
        // WHY: URLSession follows redirects on its own, and a 307 or 308 replays the original
        // method and body — the user's clipboard text — at whatever endpoint the response names.
        // Checking only the configured endpoint would let a provider move a started request onto
        // cleartext, and the user must be told that rather than shown its redirect status.
        let manager = makeCustomManager()
        let releaseResponse = DispatchSemaphore(value: 0)
        guard let task = startBlockedRequest(on: manager, releasedBy: releaseResponse, dataHandler: { _ in
            XCTFail("A refused redirect must not produce audio.")
        }) else { return }
        defer { releaseResponse.signal() }

        var didAnswerRedirect = false
        var followedRequest: URLRequest?
        manager.urlSession(
            manager.session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(for: task),
            newRequest: URLRequest(url: URL(string: "http://tts.example.com/v1/audio/speech")!)
        ) { request in
            didAnswerRedirect = true
            followedRequest = request
        }

        XCTAssertTrue(didAnswerRedirect, "The redirect decision must be answered so the task can finish.")
        XCTAssertNil(followedRequest, "A cleartext redirect target must not be followed.")
        assertTerminalState(of: manager, expectedError: Self.insecureTransportError) {
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
        }
    }

    func testARedirectToAnotherHTTPSEndpointIsStillFollowed() {
        // WHY: The rule refuses unprotected transport, not redirection. A provider that moves its
        // speech endpoint to another HTTPS host must keep working, or the guard would break an
        // ordinary provider migration while protecting nothing.
        let manager = makeCustomManager()
        let releaseResponse = DispatchSemaphore(value: 0)
        let audioDelivered = expectation(description: "The followed redirect still delivers audio")
        guard let task = startBlockedRequest(on: manager, releasedBy: releaseResponse, dataHandler: { data in
            XCTAssertEqual(data, Data([0, 1]))
            audioDelivered.fulfill()
        }) else { return }
        defer { releaseResponse.signal() }

        let relocated = URL(string: "https://relocated.custom.api/v1/audio/speech")!
        var followedRequest: URLRequest?
        manager.urlSession(
            manager.session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(for: task),
            newRequest: URLRequest(url: relocated)
        ) { followedRequest = $0 }

        XCTAssertEqual(followedRequest?.url, relocated, "A protected redirect target must be followed unchanged.")
        manager.urlSession(
            manager.session,
            dataTask: task,
            didReceive: HTTPURLResponse(url: relocated, statusCode: 200, httpVersion: nil, headerFields: nil)!
        ) { _ in }
        manager.urlSession(manager.session, dataTask: task, didReceive: Data([0, 1]))
        wait(for: [audioDelivered], timeout: 2.0)

        assertTerminalState(of: manager, expectedError: nil) {
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
        }
    }

    func testACleartextRedirectOfADiscoveryRequestIsAlsoRefused() {
        // WHY: URLSession consults this delegate for the completion-handler tasks discovery uses,
        // and those requests carry the same bearer key. The refusal must not depend on the task
        // being the active speech request, which a guard written only for speech would.
        let manager = makeCustomManager()
        let requestStarted = expectation(description: "The discovery request starts")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!
            return (response, nil)
        }
        manager.fetchAvailableModels(
            baseURL: "https://custom.api/v1/audio/speech",
            apiKey: "test-custom-api-key",
            selectedProvider: "Custom"
        )
        wait(for: [requestStarted], timeout: 2.0)
        defer { releaseResponse.signal() }
        guard let task = manager.modelMetadataTaskForTesting() else {
            XCTFail("The started discovery request must own a metadata task.")
            return
        }

        var followedRequest: URLRequest?
        manager.urlSession(
            manager.session,
            task: task,
            willPerformHTTPRedirection: redirectResponse(for: task),
            newRequest: URLRequest(url: URL(string: "http://models.example.com/v1/models")!)
        ) { followedRequest = $0 }

        XCTAssertNil(followedRequest, "A discovery redirect to cleartext must not be followed.")
        XCTAssertEqual(manager.modelSuggestions.values, [], "A refused discovery redirect must publish nothing.")
    }

    /// Returns a manager whose future requests use one protected Custom endpoint.
    private func makeCustomManager() -> TTSNetworkManager {
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(
            baseURL: "https://custom.api/v1/audio/speech",
            apiKey: "test-custom-api-key",
            model: "test-model",
            voice: "test-voice",
            selectedProvider: "Custom"
        )
        return manager
    }

    /// Starts a speech request whose response is withheld, so its task stays active for the test.
    private func startBlockedRequest(on manager: TTSNetworkManager,
                                     releasedBy releaseResponse: DispatchSemaphore,
                                     dataHandler: @escaping @Sendable (Data) -> Void) -> URLSessionDataTask? {
        let requestStarted = expectation(description: "The speech request starts")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!
            return (response, nil)
        }
        manager.streamTTS(text: "Speak through a redirecting endpoint", dataHandler: dataHandler)
        wait(for: [requestStarted], timeout: 2.0)
        guard let task = manager.activeTaskForTesting else {
            XCTFail("The started request must own the active task.")
            releaseResponse.signal()
            return nil
        }
        return task
    }

    /// Builds the redirect response a provider would send for a task's own endpoint.
    private func redirectResponse(for task: URLSessionTask) -> HTTPURLResponse {
        let url = task.originalRequest?.url ?? URL(string: "https://custom.api/v1/audio/speech")!
        return HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!
    }
}
