import XCTest
import AppKit
@testable import ClipboardTTSApp

/// Captures deferred clipboard actions so a test owns exactly when each one executes.
///
/// Confined to the main queue, like the menu flow whose scheduler it replaces. Internal because
/// `MenuBarOpenAILimitTests` drives the same deferred action; this file owns the double.
final class CapturingDeferralScheduler {
    private(set) var deferredActions: [() -> Void] = []
    private(set) var requestedDelays: [TimeInterval] = []

    var scheduler: DeferredClipboardAction.Scheduler {
        { [weak self] delay, action in
            self?.requestedDelays.append(delay)
            self?.deferredActions.append(action)
        }
    }

    func runDeferredActions() {
        let actions = deferredActions
        deferredActions.removeAll()
        actions.forEach { $0() }
    }
}

/// `MenuBarView` and the AppKit controls a hosted menu builds are main-actor isolated, so every
/// test here runs on the main actor.
@MainActor
final class MenuBarDeferredClipboardActionTests: MockURLProtocolTestCase {
    func testDeferredClipboardActionDropsAfterAServicesRequestClaimsThePipeline() {
        // WHY: The menu checks readiness before its 0.2-second clipboard delay, and a Services
        // request can claim the pipeline inside that window. Speaking now would replace work the
        // user just started without the Clear Buffer click the two-click contract requires, so the
        // stale action must not read the clipboard, start a request, or revoke the generation that
        // authorizes the Services stream's audio.
        let servicesAudioPublished = expectation(description: "Services audio stays authorized")
        servicesAudioPublished.assertForOverFulfill = false
        let audioPlayer = AudioPlayerManager(audioStateObserver: { servicesAudioPublished.fulfill() })
        let pasteboard = FakePasteboardReader(text: "Clipboard text")
        let textExtraction = TextExtractionManager(pasteboard: pasteboard)
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "OpenAI")
        let onlyRequest = expectation(description: "Only the Services request reaches the provider")
        MockURLProtocol.installRequestHandler { request in
            onlyRequest.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(repeating: 0, count: 2048))
        }
        let deferral = CapturingDeferralScheduler()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler)
        )

        view.speakCopiedText()
        XCTAssertEqual(deferral.requestedDelays, [0.2], "The clipboard read keeps its deactivation delay.")
        XCTAssertEqual(pasteboard.readCount, 0, "The pasteboard must not be read before the delay elapses.")

        let center = NotificationCenter()
        let coordinator = ServicesCoordinator(
            speechSession: SpeechSessionCoordinator(audioPlayer: audioPlayer, networkManager: networkManager),
            notificationCenter: center
        )
        withExtendedLifetime(coordinator) {
            // Runs synchronously on this thread, so the request owns the pipeline before the
            // stale action executes and no publication can land between the two.
            center.post(name: ServicesCoordinator.speakSelectedTextNotification, object: "Selected text")
            XCTAssertTrue(networkManager.isStreaming, "The Services request must be active when the stale action runs.")

            deferral.runDeferredActions()

            XCTAssertEqual(pasteboard.readCount, 0, "A stale clipboard action must not read the pasteboard.")
            XCTAssertTrue(networkManager.isStreaming, "The stale action must not stop the Services request.")
            wait(for: [onlyRequest, servicesAudioPublished], timeout: 2.0)
        }

        XCTAssertTrue(audioPlayer.hasAudio, "The Services stream's audio must still be authorized.")
        XCTAssertEqual(pasteboard.readCount, 0)
    }

    func testRapidRepeatedSpeakClicksReadTheClipboardOnce() {
        // WHY: Two quick clicks are one user intent, and both pass the pre-delay readiness check.
        // Only the newest attempt may act. A configuration failure leaves the pipeline idle again,
        // so an older attempt that survived would read the clipboard again and start a second
        // attempt from a click the user made before any result was visible.
        let audioPlayer = AudioPlayerManager()
        let pasteboard = FakePasteboardReader(text: "Clipboard text")
        let textExtraction = TextExtractionManager(pasteboard: pasteboard)
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(
            baseURL: "not a valid endpoint",
            apiKey: "test",
            model: "test",
            voice: "test",
            selectedProvider: "OpenAI"
        )
        let deferral = CapturingDeferralScheduler()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler)
        )

        view.speakCopiedText()
        view.speakCopiedText()
        XCTAssertEqual(deferral.requestedDelays, [0.2, 0.2], "Each click defers its own attempt.")

        deferral.runDeferredActions()

        XCTAssertEqual(pasteboard.readCount, 1, "Only the newest attempt may read the clipboard.")
        XCTAssertEqual(
            networkManager.lastError,
            "TTS configuration is invalid. Check the API endpoint and try again.",
            "The surviving attempt must still run; dropping every attempt would speak nothing."
        )
    }

    func testRapidRepeatedSpeakClicksReadTheClipboardOnceWithNothingToSpeak() {
        // WHY: The pasteboard read is a side effect on the user's own data, and a burst of clicks
        // is one intent. When the read finds nothing to speak no request starts, so the pipeline
        // never changes hands and nothing downstream can tell the older attempt it is stale. Only
        // the owner's newest-attempt token can, which is why it is not redundant.
        let audioPlayer = AudioPlayerManager()
        let pasteboard = FakePasteboardReader()
        let textExtraction = TextExtractionManager(pasteboard: pasteboard)
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "OpenAI")
        let deferral = CapturingDeferralScheduler()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler)
        )

        view.speakCopiedText()
        view.speakCopiedText()
        deferral.runDeferredActions()

        XCTAssertEqual(pasteboard.readCount, 1, "A burst of clicks may read the user's clipboard once.")
        XCTAssertFalse(networkManager.isStreaming, "An empty clipboard starts no request.")
    }

    func testSpeakAfterClearingAnActiveStreamStartsANewRequest() {
        // WHY: Dropping stale attempts must not wedge the menu. After the Clear Buffer click the
        // two-click contract requires, the next explicit Speak click must still read the clipboard
        // and start a request.
        let audioPlayer = AudioPlayerManager()
        let pasteboard = FakePasteboardReader(text: "Clipboard text")
        let textExtraction = TextExtractionManager(pasteboard: pasteboard)
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "OpenAI")
        let requestStarted = expectation(description: "The explicit second click starts a request")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let deferral = CapturingDeferralScheduler()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler)
        )

        // Set the view's Clear Buffer branch condition without scheduling live AVAudioEngine work.
        audioPlayer.hasAudio = true
        view.speakCopiedText()
        XCTAssertFalse(audioPlayer.hasAudio, "The first click clears the retained buffer.")
        XCTAssertTrue(deferral.requestedDelays.isEmpty, "Clearing must not queue a clipboard read.")

        view.speakCopiedText()
        deferral.runDeferredActions()

        XCTAssertEqual(pasteboard.readCount, 1, "The idle pipeline must accept the explicit second click.")
        wait(for: [requestStarted], timeout: 2.0)
    }

    func testDeferredClipboardActionDropsAfterAnInterveningRequestFinishes() {
        // WHY: Published state cannot describe the moment a request finishes. `isStreaming` goes
        // false as soon as the task completes, while audio that request already had accepted is
        // still travelling the delivery queue toward `hasAudio`, so the pipeline reads as idle
        // while it is not this attempt's to take: speaking there would revoke the intervening
        // stream's audio and replace it. The request generation records that somebody else owned
        // the pipeline, whichever way those two publications happen to be ordered.
        let audioPlayer = AudioPlayerManager()
        let pasteboard = FakePasteboardReader(text: "Clipboard text")
        let textExtraction = TextExtractionManager(pasteboard: pasteboard)
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "OpenAI")
        let onlyRequest = expectation(description: "Only the intervening request reaches the provider")
        MockURLProtocol.installRequestHandler { request in
            onlyRequest.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let deferral = CapturingDeferralScheduler()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler)
        )

        view.speakCopiedText()
        XCTAssertEqual(deferral.requestedDelays, [0.2])

        let center = NotificationCenter()
        let coordinator = ServicesCoordinator(
            speechSession: SpeechSessionCoordinator(audioPlayer: audioPlayer, networkManager: networkManager),
            notificationCenter: center
        )
        withExtendedLifetime(coordinator) {
            assertTerminalState(
                of: networkManager,
                expectedError: "The TTS service returned no playable audio. Please try again."
            ) {
                center.post(name: ServicesCoordinator.speakSelectedTextNotification, object: "Selected text")
            }

            XCTAssertFalse(networkManager.isStreaming, "The intervening request has finished.")
            XCTAssertFalse(audioPlayer.hasAudio, "It left no buffer, so only the generation marks the attempt stale.")

            deferral.runDeferredActions()
        }

        XCTAssertEqual(pasteboard.readCount, 0, "A finished intervening request still makes the attempt stale.")
        wait(for: [onlyRequest], timeout: 2.0)
    }

    func testClearBufferClickDropsAnAttemptScheduledBeforeThePipelineBecameBusy() {
        // WHY: Work can claim the pipeline inside a Speak click's delay, which turns the next click
        // into Clear Buffer. That click asks for silence, and the idle pipeline it leaves behind is
        // exactly the state the waiting attempt would otherwise be allowed to speak in. Releasing
        // the pipeline advances the request generation, which is what makes the attempt stale.
        let audioPlayer = AudioPlayerManager()
        let pasteboard = FakePasteboardReader(text: "Clipboard text")
        let textExtraction = TextExtractionManager(pasteboard: pasteboard)
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "OpenAI")
        let deferral = CapturingDeferralScheduler()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler)
        )

        view.speakCopiedText()
        XCTAssertEqual(deferral.requestedDelays, [0.2])
        // Stand in for work that claimed the pipeline inside the delay, without live audio work.
        audioPlayer.hasAudio = true

        view.speakCopiedText()
        XCTAssertFalse(audioPlayer.hasAudio, "The second click clears rather than speaks.")

        deferral.runDeferredActions()

        XCTAssertEqual(pasteboard.readCount, 0, "A cleared attempt must not read the pasteboard.")
        XCTAssertFalse(networkManager.isStreaming, "Clear Buffer must leave the pipeline silent.")
    }

    func testDeferredClipboardActionDropsWhenTheAudioConfigurationBecomesInvalid() {
        // WHY: Settings can invalidate the PCM graph inside the delay window. Reading the clipboard
        // then would request audio the engine cannot play at the configured rate, so the stale
        // action must drop and leave the sample-rate failure as the state the user sees.
        let audioPlayer = AudioPlayerManager()
        let pasteboard = FakePasteboardReader(text: "Clipboard text")
        let textExtraction = TextExtractionManager(pasteboard: pasteboard)
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "OpenAI")
        let deferral = CapturingDeferralScheduler()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler)
        )

        view.speakCopiedText()
        XCTAssertEqual(deferral.requestedDelays, [0.2])
        XCTAssertEqual(audioPlayer.setSampleRate(48_001), .invalid)

        deferral.runDeferredActions()

        XCTAssertEqual(pasteboard.readCount, 0, "An unplayable audio configuration must stop the deferred read.")
        XCTAssertFalse(networkManager.isStreaming, "No request may start once the audio graph is unusable.")
        XCTAssertEqual(audioPlayer.sampleRateError, "PCM sample rate must be a finite value from 8,000 to 48,000 Hz.")
    }
}
