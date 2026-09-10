import XCTest
@testable import ClipboardTTSApp

/// The terminal half of a speech session's handoff: exactly one event per request, ordered behind
/// every byte of PCM that request delivered, and withdrawn once the session loses the pipeline.
final class TTSNetworkManagerStreamTerminationTests: MockURLProtocolTestCase {

    func testTerminationCannotOvertakeThePCMItsRequestAlreadyDelivered() {
        // WHY: This is the ordering the whole terminal event exists to provide. A client that hears
        // "the stream ended" before the last chunk it was sent would treat delivered speech as
        // audio that never arrived. Holding the PCM handler open across the completion callback is
        // what distinguishes a genuinely ordered handoff from one that merely usually wins the race.
        let manager = makeOpenAIManager()
        let events = SessionEventLog()
        let audioDelivered = expectation(description: "The request's PCM reaches its client")
        audioDelivered.assertForOverFulfill = false
        let terminated = expectation(description: "The session is terminated")
        terminated.assertForOverFulfill = false
        let releaseAudioHandler = DispatchSemaphore(value: 0)
        let client = SpeechStreamClient(
            didReceiveAudio: { data in
                events.record(.audio(data))
                audioDelivered.fulfill()
                _ = releaseAudioHandler.wait(timeout: .now() + 2.0)
            },
            didTerminate: { termination in
                events.record(.terminated(termination))
                terminated.fulfill()
            }
        )

        withStartedRequest(on: manager, client: client) { task in
            manager.urlSession(manager.session, dataTask: task, didReceive: Data([0x01, 0x02]))
            wait(for: [audioDelivered], timeout: 2.0)
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)

            XCTAssertEqual(
                events.recorded,
                [.audio(Data([0x01, 0x02]))],
                "The completion callback must not reach the client while its PCM handler is still running."
            )
            releaseAudioHandler.signal()
            wait(for: [terminated], timeout: 2.0)
        }

        XCTAssertEqual(
            events.recorded,
            [.audio(Data([0x01, 0x02])), .terminated(.finished)],
            "A request that published no failure must end its session behind the PCM it delivered."
        )
    }

    func testAFailedRequestEndsItsSessionAsFailed() {
        // WHY: The session has to be able to tell speech that finished from speech that stopped
        // because the request broke. Publishing the failure to the menu bar alone leaves the client
        // holding a stream it cannot classify, which is the distinction underrun recovery turns on.
        let manager = makeOpenAIManager()
        let events = SessionEventLog()
        let terminated = expectation(description: "The failed request terminates its session")

        withStartedRequest(on: manager, client: makeLoggingClient(events, terminated: terminated)) { task in
            manager.urlSession(manager.session, dataTask: task, didReceive: mockHTTPResponse(for: task, statusCode: 500)) { _ in }
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
            wait(for: [terminated], timeout: 2.0)
        }

        XCTAssertEqual(events.recorded, [.terminated(.failed)])
    }

    func testARequestRefusedBeforeItOwnsATaskStillEndsItsSession() {
        // WHY: The caller took an audio generation before calling, so a session exists even when no
        // task ever will. Terminating only requests that reached the network would leave a rejected
        // endpoint's session waiting forever for PCM, which is the one state it must never be in.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(
            baseURL: "http://insecure.example.com/v1/audio/speech",
            apiKey: "test",
            model: "test",
            voice: "test",
            selectedProvider: "Custom"
        )
        let events = SessionEventLog()
        let terminated = expectation(description: "The refused request terminates its session")

        manager.streamTTS(text: "Refused before it starts", client: makeLoggingClient(events, terminated: terminated))
        wait(for: [terminated], timeout: 2.0)

        XCTAssertEqual(events.recorded, [.terminated(.failed)])
        XCTAssertEqual(manager.lastError, TTSNetworkManager.insecureTransportFailure)
    }

    func testAStopBeforeCompletionLeavesThatCompletionNoSessionToEnd() {
        // WHY: A cancelled session is torn down by whoever cancelled it, so the completion that
        // arrives afterwards must find nothing to report. The stop releases the active request, so
        // this is the staleness check rather than the delivery queue's generation guard; the test
        // below covers the guard, and both have to hold for a cancelled session to stay silent.
        let manager = makeOpenAIManager()
        let events = SessionEventLog()
        let client = SpeechStreamClient(
            didReceiveAudio: { data in events.record(.audio(data)) },
            didTerminate: { termination in events.record(.terminated(termination)) }
        )

        withStartedRequest(on: manager, client: client) { task in
            manager.stopStreaming()
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
            drainAudioDelivery(of: manager)
        }

        XCTAssertEqual(events.recorded, [], "A stopped session must be told nothing about the request it released.")
    }

    func testATerminationIsWithdrawnWhenItsRequestLosesThePipelineBeforeItRuns() {
        // WHY: The delivery queue's generation check is the only thing between an already-queued
        // terminal event and the session that replaced its request, and a stop that lands before
        // completion never queues one to check. A handler is allowed to release its own stream
        // synchronously, which advances the generation from inside the delivery queue itself —
        // after the completion callback queued this request's ending, and before that ending can
        // run. Nothing may be told the request ended, because its session is already gone.
        let manager = makeOpenAIManager()
        let events = SessionEventLog()
        let audioDelivered = expectation(description: "The request's PCM reaches its client")
        audioDelivered.assertForOverFulfill = false
        let releaseAudioHandler = DispatchSemaphore(value: 0)
        let client = SpeechStreamClient(
            didReceiveAudio: { data in
                events.record(.audio(data))
                audioDelivered.fulfill()
                _ = releaseAudioHandler.wait(timeout: .now() + 2.0)
                // Legal here, and the point of the test: callback authority is recursive precisely
                // so a handler can release its own stream, and that is what supersedes the
                // generation the ending queued behind this handler was authorized against.
                manager.stopStreaming()
            },
            didTerminate: { termination in events.record(.terminated(termination)) }
        )

        withStartedRequest(on: manager, client: client) { task in
            manager.urlSession(manager.session, dataTask: task, didReceive: Data([0x01, 0x02]))
            wait(for: [audioDelivered], timeout: 2.0)
            // Queues this request's ending behind the handler that is still holding the queue.
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
            releaseAudioHandler.signal()
            drainAudioDelivery(of: manager)
        }

        XCTAssertEqual(
            events.recorded,
            [.audio(Data([0x01, 0x02]))],
            "An ending queued for a request that no longer owns the pipeline must be withdrawn, not delivered."
        )
    }

    func testOnlyOneTerminationReachesASessionHoweverOftenItsTaskCompletes() {
        // WHY: URLSession is not the only caller: a refused redirect, a revoked Gemini stream, and
        // the delegate itself can all reach completion for one task. The client's contract is one
        // terminal event per session, so a second completion must find nothing left to report.
        let manager = makeOpenAIManager()
        let events = SessionEventLog()
        let terminated = expectation(description: "The request terminates its session")

        withStartedRequest(on: manager, client: makeLoggingClient(events, terminated: terminated)) { task in
            manager.urlSession(manager.session, dataTask: task, didReceive: Data([0x01, 0x02]))
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
            wait(for: [terminated], timeout: 2.0)
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
            drainAudioDelivery(of: manager)
        }

        XCTAssertEqual(
            events.recorded,
            [.audio(Data([0x01, 0x02])), .terminated(.finished)],
            "A completion for a task that no longer owns the request must terminate nobody."
        )
    }

    func testTheAutomaticRetryDoesNotEndTheSessionItsFirstAttemptLeftOpen() {
        // WHY: The retry continues the same logical request, so the session is still live while it
        // runs. Terminating on the first attempt's completion would tell the client the speech
        // ended at the very moment the app is transparently asking for it again.
        let manager = TestNetworkFactory.makeManager()
        configureGeminiProvider(manager)
        let attempts = RequestAttemptLog()
        let secondAttemptStarted = expectation(description: "The retry attempt reaches the provider")
        let releaseRetryResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            guard attempts.record(request) > 1 else {
                // The documented transient failure, which is the only one the retry answers.
                return (mockHTTPResponse(for: request, statusCode: 500), nil)
            }
            secondAttemptStarted.fulfill()
            // Held open so the session can be inspected while its retry is genuinely in flight.
            _ = releaseRetryResponse.wait(timeout: .now() + 2.0)
            return (mockHTTPResponse(for: request, statusCode: 500), nil)
        }
        let events = SessionEventLog()
        let sessionEnded = expectation(description: "The retry's own completion ends the session")

        manager.streamTTS(text: "Retry keeps the session open", client: makeLoggingClient(events, terminated: sessionEnded))
        wait(for: [secondAttemptStarted], timeout: 2.0)
        defer { releaseRetryResponse.signal() }
        drainAudioDelivery(of: manager)

        XCTAssertEqual(attempts.count, 2, "The transient failure must have earned its one retry.")
        XCTAssertEqual(events.recorded, [], "A retry that started owns the rest of the session, so nothing ended it.")
        XCTAssertTrue(manager.isStreaming, "The session stays live while its retry runs.")

        // Letting the retry finish is what proves the session is ended by the attempt that owns it
        // rather than left open: the handoff has to survive the swap from one attempt to the next.
        releaseRetryResponse.signal()
        wait(for: [sessionEnded], timeout: 2.0)
        drainAudioDelivery(of: manager)

        XCTAssertEqual(
            events.recorded,
            [.terminated(.failed)],
            "The retry's completion must end the session once, and the first attempt's must not have ended it too."
        )
    }

    func testAMalformedGeminiStreamEndsTheSessionItRevoked() {
        // WHY: A fatal parse revokes the request generation from inside the data callback, so the
        // guard that withdraws stale deliveries would silently withdraw this terminal event too.
        // The session it orphaned still holds whatever PCM already arrived and must be told that
        // nothing more is coming.
        let manager = TestNetworkFactory.makeManager()
        configureGeminiProvider(manager)
        let events = SessionEventLog()
        let terminated = expectation(description: "The revoked Gemini session is terminated")

        withStartedRequest(on: manager, client: makeLoggingClient(events, terminated: terminated), text: "Gemini") { task in
            manager.urlSession(manager.session, dataTask: task, didReceive: mockHTTPResponse(for: task, statusCode: 200)) { _ in }
            manager.urlSession(manager.session, dataTask: task, didReceive: Data("data: not json\r\n\r\n".utf8))
            wait(for: [terminated], timeout: 2.0)
        }

        XCTAssertEqual(events.recorded, [.terminated(.failed)])
        XCTAssertEqual(manager.lastError, "The TTS service returned no playable audio. Please try again.")
    }

    func testRevokingWaitsForAnAuthorizedTerminalCallbackToReturn() {
        // WHY: Callback authority spans the terminal event's authorization through the client call,
        // exactly as it spans a PCM delivery. Without it a stop or replacement would return while
        // the superseded session's terminal callback was still running, so the caller that believes
        // it now owns the pipeline would be racing a handler it was told had been cancelled. The
        // generation check alone cannot provide this: it decides whether a callback runs, not
        // whether cancellation may return before one that already started has finished.
        let authority = WaitObservingCallbackAuthority()
        let manager = makeOpenAIManager(callbackAuthority: authority)
        let events = SessionEventLog()
        let terminationStarted = expectation(description: "The terminal callback has begun")
        terminationStarted.assertForOverFulfill = false
        let releaseTermination = DispatchSemaphore(value: 0)
        let terminalCallbackReturned = LockedValue(false)
        let revocationSawItReturn = LockedValue(false)
        let client = SpeechStreamClient(
            didReceiveAudio: { data in events.record(.audio(data)) },
            didTerminate: { termination in
                events.record(.terminated(termination))
                terminationStarted.fulfill()
                _ = releaseTermination.wait(timeout: .now() + 2.0)
                terminalCallbackReturned.withValue { $0 = true }
            }
        )

        withStartedRequest(on: manager, client: client) { task in
            manager.urlSession(manager.session, dataTask: task, didReceive: Data([0x01, 0x02]))
            manager.urlSession(manager.session, task: task, didCompleteWithError: nil)
            wait(for: [terminationStarted], timeout: 2.0)

            let revocationWaited = expectation(description: "Revocation had to wait for callback authority")
            authority.observeNextWait { revocationWaited.fulfill() }
            let revocationReturned = expectation(description: "Revocation returned")
            DispatchQueue.global(qos: .userInitiated).async {
                manager.stopStreaming()
                revocationSawItReturn.withValue { $0 = terminalCallbackReturned.value }
                revocationReturned.fulfill()
            }

            // Releasing only after the revocation is provably blocked is what keeps this from
            // passing because the stop simply arrived late.
            wait(for: [revocationWaited], timeout: 2.0)
            releaseTermination.signal()
            wait(for: [revocationReturned], timeout: 2.0)
        }

        XCTAssertTrue(
            revocationSawItReturn.value,
            "Revocation must not return while an authorized terminal callback is still running."
        )
        XCTAssertEqual(events.recorded, [.audio(Data([0x01, 0x02])), .terminated(.finished)])
    }

    // MARK: - Support

    private func makeOpenAIManager(
        callbackAuthority: CallbackAuthorityLocking = RecursiveCallbackAuthority()
    ) -> TTSNetworkManager {
        let manager = TestNetworkFactory.makeManager(callbackAuthority: callbackAuthority)
        manager.updateSettings(
            baseURL: "https://mock.api/v1/audio/speech",
            apiKey: "test",
            model: "test",
            voice: "test",
            selectedProvider: "OpenAI"
        )
        return manager
    }

    /// A client that logs what it receives and reports the first ending it is handed.
    ///
    /// Over-fulfilment is deliberately not an error here. Every caller asserts the exact events it
    /// recorded, so a regression that terminated a session twice has to fail that assertion — and
    /// be readable in its message — rather than raise XCTest's over-fulfilment exception, which
    /// aborts the whole run before any of it is reported.
    private func makeLoggingClient(_ events: SessionEventLog, terminated: XCTestExpectation) -> SpeechStreamClient {
        terminated.assertForOverFulfill = false
        return SpeechStreamClient(
            didReceiveAudio: { data in events.record(.audio(data)) },
            didTerminate: { termination in
                events.record(.terminated(termination))
                terminated.fulfill()
            }
        )
    }

    /// Starts a request whose response is held open, and hands `body` the task to drive directly.
    ///
    /// Driving the delegate is what makes the order of a chunk and a completion a decision this
    /// test makes rather than one the URL loading system happens to produce.
    private func withStartedRequest(on manager: TTSNetworkManager,
                                    client: SpeechStreamClient,
                                    text: String = "Terminal event test",
                                    body: (URLSessionDataTask) -> Void) {
        let requestStarted = expectation(description: "The request reaches the provider")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2.0)
            return (mockHTTPResponse(for: request, statusCode: 200), nil)
        }

        manager.streamTTS(text: text, client: client)
        wait(for: [requestStarted], timeout: 2.0)
        defer { releaseResponse.signal() }
        guard let task = manager.activeTaskForTesting else {
            XCTFail("Expected streamTTS to retain the task it started.")
            return
        }
        body(task)
    }

    /// Waits for every callback already queued on the manager's delivery queue to run.
    ///
    /// The absence assertions need a point after which nothing further can arrive; a delay would
    /// only make the window likely rather than closed.
    private func drainAudioDelivery(of manager: TTSNetworkManager) {
        let drained = expectation(description: "Queued session callbacks have run")
        manager.audioDeliveryQueue.async { drained.fulfill() }
        wait(for: [drained], timeout: 2.0)
    }
}
