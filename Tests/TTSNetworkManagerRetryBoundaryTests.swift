import XCTest
@testable import ClipboardTTSApp

/// Covers every failure and cancellation that must still reach the user after a single attempt.
final class TTSNetworkManagerRetryBoundaryTests: MockURLProtocolTestCase {
    func testGeminiFailuresOtherThanATransientServerErrorMakeExactlyOneAttempt() {
        // WHY: Retrying a failure the user must act on — a wrong key, a rejected request, an
        // unreachable service — doubles the wait before the guidance appears and doubles the load on
        // a provider that already refused. Only the 500 Google documents as transient is repeatable.
        let cases: [(statusCode: Int?, expectedError: String)] = [
            (401, "Authentication failed (HTTP 401). Check your API key and try again."),
            (403, "Authentication failed (HTTP 403). Check your API key and try again."),
            (429, "Speech request failed (HTTP 429)."),
            (503, "Speech request failed (HTTP 503)."),
            (nil, "Couldn't reach the TTS service. Check your connection and try again.")
        ]
        for testCase in cases {
            let manager = TestNetworkFactory.makeManager()
            configureGeminiProvider(manager)
            let attempts = RequestAttemptLog()
            MockURLProtocol.installRequestHandler { request in
                attempts.record(request)
                guard let statusCode = testCase.statusCode else { throw URLError(.notConnectedToInternet) }
                return (mockHTTPResponse(for: request, statusCode: statusCode), nil)
            }

            assertTerminalState(of: manager, expectedError: testCase.expectedError) {
                manager.streamTTS(text: "Non-retryable Gemini failure") { _ in
                    XCTFail("A refused Gemini request must not deliver audio.")
                }
            }
            XCTAssertEqual(attempts.count, 1, "Gemini must not retry \"\(testCase.expectedError)\".")
            assertAfterMockQuiescence {
                XCTAssertEqual(attempts.count, 1, "No late retry may follow \"\(testCase.expectedError)\".")
            }
        }
    }

    func testGeminiServerErrorAccompaniedByATransportFailureIsNotRetried() {
        // WHY: A 500 whose connection also failed is not the documented "model returned text"
        // failure. Replaying the request over a link that just dropped only delays the message the
        // user can act on, so the transport rule wins over the status the response happened to carry.
        let manager = TestNetworkFactory.makeManager()
        configureGeminiProvider(manager)
        let attempts = RequestAttemptLog()
        let requestStarted = expectation(description: "Gemini request starts")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            // Only the first attempt is expected, so a second one must fail the attempt count
            // below rather than over-fulfilling this expectation.
            if attempts.record(request) == 1 { requestStarted.fulfill() }
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            return (mockHTTPResponse(for: request, statusCode: 500), nil)
        }
        guard let task = startGeminiRequest(manager, requestStarted: requestStarted, releaseResponse: releaseResponse) else {
            return
        }
        defer { releaseResponse.signal() }

        receive(manager, response: mockHTTPResponse(for: task, statusCode: 500), for: task)
        assertTerminalState(of: manager, expectedError: "Speech request failed (HTTP 500).") {
            manager.urlSession(manager.session, task: task, didCompleteWithError: URLError(.networkConnectionLost))
        }
        XCTAssertEqual(attempts.count, 1, "A broken connection must not be retried alongside its status.")
    }

    func testStopBeforeAFailedGeminiAttemptCompletesPreventsItsRetry() {
        // WHY: A user who cleared the buffer or started something else has ended this request. The
        // retry must not restart it behind them, and the failure they never waited for must not
        // surface over whatever they did next.
        let manager = TestNetworkFactory.makeManager()
        configureGeminiProvider(manager)
        let attempts = RequestAttemptLog()
        let requestStarted = expectation(description: "Gemini request starts")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            // Only the first attempt is expected, so a second one must fail the attempt count
            // below rather than over-fulfilling this expectation.
            if attempts.record(request) == 1 { requestStarted.fulfill() }
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            return (mockHTTPResponse(for: request, statusCode: 500), nil)
        }
        guard let task = startGeminiRequest(manager, requestStarted: requestStarted, releaseResponse: releaseResponse) else {
            return
        }
        defer { releaseResponse.signal() }

        receive(manager, response: mockHTTPResponse(for: task, statusCode: 500), for: task)
        manager.stopStreaming()
        manager.urlSession(manager.session, task: task, didCompleteWithError: nil)

        XCTAssertEqual(attempts.count, 1, "A stopped request must not start the retry its failure would have earned.")
        XCTAssertNil(manager.lastError, "A stopped request must not publish the failure it never finished reporting.")
        XCTAssertFalse(manager.isStreaming)
    }

    func testARetryCannotStartOnceItsRequestGenerationWasRevoked() {
        // WHY: A failed attempt releases the active request before its retry installs one. A stop or
        // a replacement landing in that window already owns the pipeline, so starting the retry
        // there would speak text the user cancelled or fight the request that replaced it. No mock
        // handler is installed, so a request that did escape also fails this test's scope teardown.
        let manager = TestNetworkFactory.makeManager()
        configureGeminiProvider(manager)
        let revokedGeneration = manager.currentRequestGeneration()
        manager.stopStreaming()
        XCTAssertNotEqual(manager.currentRequestGeneration(), revokedGeneration, "Stopping must revoke the captured generation.")

        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:streamGenerateContent?alt=sse"
        let attempt = TTSNetworkManager.RetryAttempt(
            request: URLRequest(url: URL(string: endpoint)!),
            provider: .gemini,
            requestGeneration: revokedGeneration,
            client: SpeechStreamClient(
                didReceiveAudio: { _ in XCTFail("A revoked retry must not deliver audio.") },
                didTerminate: { _ in XCTFail("A revoked retry must not end a session it never owned.") }
            )
        )

        XCTAssertFalse(manager.startRetryAttempt(attempt), "A retry whose generation was revoked must report that it did not start.")
        XCTAssertNil(manager.activeTaskForTesting, "A rejected retry must leave no active request behind.")
    }

    func testOnlyGeminiRetriesAServerError() {
        // WHY: The transient failure is documented for Google's TTS model. OpenAI-compatible and
        // Custom endpoints promise nothing about a second attempt, so resending the user's text
        // there would be a guess made on their behalf with their credentials and quota.
        let providers = [
            (baseURL: "https://mock.api/v1/audio/speech", selectedProvider: "OpenAI"),
            (baseURL: "https://custom.api/v1/audio/speech", selectedProvider: "Custom")
        ]
        for provider in providers {
            let manager = TestNetworkFactory.makeManager()
            manager.updateSettings(
                baseURL: provider.baseURL,
                apiKey: "fake-key",
                model: "test",
                voice: "test",
                selectedProvider: provider.selectedProvider
            )
            let attempts = RequestAttemptLog()
            MockURLProtocol.installRequestHandler { request in
                attempts.record(request)
                return (mockHTTPResponse(for: request, statusCode: 500), nil)
            }

            assertTerminalState(of: manager, expectedError: "Speech request failed (HTTP 500).") {
                manager.streamTTS(text: "Non-Gemini server error") { _ in
                    XCTFail("A rejected \(provider.selectedProvider) request must not deliver audio.")
                }
            }
            XCTAssertEqual(attempts.count, 1, "\(provider.selectedProvider) must not inherit Gemini's retry.")
            assertAfterMockQuiescence {
                XCTAssertEqual(attempts.count, 1, "No late \(provider.selectedProvider) retry may follow its failure.")
            }
        }
    }

    /// Starts a request and returns the task the manager retained, signalling the mock on failure.
    private func startGeminiRequest(_ manager: TTSNetworkManager,
                                    requestStarted: XCTestExpectation,
                                    releaseResponse: DispatchSemaphore) -> URLSessionDataTask? {
        manager.streamTTS(text: "Gemini request the test drives directly") { _ in
            XCTFail("A failed Gemini attempt must not deliver audio.")
        }
        wait(for: [requestStarted], timeout: 1.0)
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected streamTTS to retain its Gemini task.")
            releaseResponse.signal()
            return nil
        }
        return task
    }

    private func receive(_ manager: TTSNetworkManager,
                         response: HTTPURLResponse,
                         for task: URLSessionDataTask) {
        manager.urlSession(manager.session, dataTask: task, didReceive: response) { disposition in
            XCTAssertEqual(disposition, .allow)
        }
    }
}
