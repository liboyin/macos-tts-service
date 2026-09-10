import XCTest
@testable import ClipboardTTSApp

final class ServicesCoordinatorTests: MockURLProtocolTestCase {

    func testServiceNotificationDoesNotStartWhenThePersistedCustomRateIsInvalid() {
        // WHY: Services can arrive before Settings has ever appeared. A corrupt persisted Custom
        // rate must therefore block this normal speech path instead of decoding streamed PCM using
        // a silent 24-kHz fallback.
        let audioPlayer = AudioPlayerManager(sampleRate: 48_001)
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "OpenAI")
        MockURLProtocol.installRequestHandler { _ in
            XCTFail("An invalid Custom PCM rate must not start a Services request")
            return (HTTPURLResponse(), Data())
        }

        let center = NotificationCenter()
        let coordinator = ServicesCoordinator(
            speechSession: SpeechSessionCoordinator(audioPlayer: audioPlayer, networkManager: networkManager),
            notificationCenter: center
        )

        withExtendedLifetime(coordinator) {
            center.post(name: ServicesCoordinator.speakSelectedTextNotification, object: "Speak me")
        }

        XCTAssertEqual(audioPlayer.sampleRateError, "PCM sample rate must be a finite value from 8,000 to 48,000 Hz.")
        XCTAssertFalse(networkManager.isStreaming)
    }

    func testOversizedOpenAISelectedTextStillReachesTheProvider() {
        // WHY: The 4,096-character refusal belongs to the menu click the user asked it for, not to
        // every entry point. Services carries a selection the user made in another app, where no
        // dialog of ours is expected, so putting the rule in `streamTTS` would silently change this
        // path too. Long selected text must still reach the provider and fail there, as it does now.
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(
            baseURL: "https://api.openai.com/v1/audio/speech",
            apiKey: "test",
            model: "tts-1",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )
        let requestStarted = expectation(description: "Oversized selected text reaches the provider")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let center = NotificationCenter()
        let coordinator = ServicesCoordinator(
            speechSession: SpeechSessionCoordinator(audioPlayer: audioPlayer, networkManager: networkManager),
            notificationCenter: center
        )

        withExtendedLifetime(coordinator) {
            center.post(
                name: ServicesCoordinator.speakSelectedTextNotification,
                object: String(repeating: "a", count: 5_000)
            )
            wait(for: [requestStarted], timeout: 2.0)
        }
    }

    func testServiceNotificationStreamsSelectedTextToAudio() {
        // WHY: The macOS Services entry point ("Speak Selected Text with Clipboard TTS") must work
        // from app launch, before the menu bar dropdown (and thus MenuBarView) is ever built. The
        // coordinator now owns the subscription that used to live on the lazily-built view, so
        // posting the notification alone — with no view in existence — must drive selected text ->
        // network -> scheduled audio. hasAudio flipping true proves that whole chain ran.
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "OpenAI")
        MockURLProtocol.installRequestHandler { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(repeating: 0, count: 2048))
        }

        let center = NotificationCenter()
        let coordinator = ServicesCoordinator(
            speechSession: SpeechSessionCoordinator(audioPlayer: audioPlayer, networkManager: networkManager),
            notificationCenter: center
        )

        withExtendedLifetime(coordinator) {
            center.post(name: ServicesCoordinator.speakSelectedTextNotification, object: "Speak me")

            let expectation = XCTestExpectation(description: "Service text streamed to audio")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                XCTAssertTrue(audioPlayer.hasAudio)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 3.0)
        }
    }

    func testBackgroundServiceNotificationUsesTheMainActionHandoff() {
        // WHY: AppKit Services normally arrives on main, but NotificationCenter permits another
        // posting thread. Playback state and AVAudioEngine control are main-confined, so a
        // background post must use the coordinator's full main-action handoff before speaking.
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "OpenAI")
        let requestReceived = expectation(description: "Main action starts its speech request")
        MockURLProtocol.installRequestHandler { request in
            requestReceived.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let center = NotificationCenter()
        let speechRanOnMain = expectation(description: "Production main handoff runs speech on main")
        let coordinator = ServicesCoordinator(
            speechSession: SpeechSessionCoordinator(audioPlayer: audioPlayer, networkManager: networkManager),
            notificationCenter: center,
            speechActionObserver: {
                XCTAssertTrue(Thread.isMainThread)
                speechRanOnMain.fulfill()
            }
        )

        withExtendedLifetime(coordinator) {
            DispatchQueue.global().async {
                center.post(name: ServicesCoordinator.speakSelectedTextNotification, object: "Speak me")
            }
            wait(for: [speechRanOnMain, requestReceived], timeout: 1.0)
        }
    }

    func testServiceNotificationWithoutStringObjectIsIgnored() {
        // WHY: handleServices only posts when the pasteboard holds a string, but the coordinator
        // must still defensively drop a malformed notification (non-String object) rather than
        // start a stream with garbage. If the guard regressed and fed a non-String payload into
        // the pipeline, streamTTS would fire a real network request — MockURLProtocol's XCTFail
        // handler makes that regression fail the test rather than silently hit the live API.
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "OpenAI")
        MockURLProtocol.installRequestHandler { request in
            XCTFail("Malformed notification must not start a network request")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let center = NotificationCenter()
        let coordinator = ServicesCoordinator(
            speechSession: SpeechSessionCoordinator(audioPlayer: audioPlayer, networkManager: networkManager),
            notificationCenter: center
        )

        withExtendedLifetime(coordinator) {
            center.post(name: ServicesCoordinator.speakSelectedTextNotification, object: 42)

            // Drain the main/network queues so a regressed request would have reached the protocol.
            let settled = XCTestExpectation(description: "No stream started")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
            wait(for: [settled], timeout: 1.0)
        }

        XCTAssertFalse(networkManager.isStreaming)
        XCTAssertFalse(audioPlayer.hasAudio)
    }
}
