import XCTest
import AppKit
@testable import ClipboardTTSApp

/// Covers the click-time refusal of clipboard text longer than OpenAI's documented `input` maximum.
/// `MenuBarView` and the AppKit controls a hosted menu builds are main-actor isolated, so every
/// test here runs on the main actor.
@MainActor
final class MenuBarOpenAILimitTests: MockURLProtocolTestCase {
    private static let alertTitle = "Copied text is too long"

    private func expectedAlertMessage(characterCount: String) -> String {
        "OpenAI accepts at most 4,096 characters per request. The copied text is "
            + "\(characterCount) characters. Copy a shorter passage and try again."
    }

    /// Runs the main queue once, so a request start the manager deferred while it was publishing
    /// state has a turn to land.
    private func drainMainQueue() {
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2.0)
    }

    /// Reads the request generation once the main queue has stopped advancing it.
    ///
    /// A start the manager deferred because it was publishing state is re-queued onto the main
    /// queue, and the re-queued start may defer again, so sampling after a single drain observes a
    /// duplicate request only sometimes. Draining until two readings agree makes it deterministic.
    private func settledRequestGeneration(of networkManager: TTSNetworkManager) -> UInt64 {
        var previous = networkManager.currentRequestGeneration()
        for _ in 0..<5 {
            drainMainQueue()
            let current = networkManager.currentRequestGeneration()
            if current == previous { return current }
            previous = current
        }
        XCTFail("The request generation never stopped advancing, so no count can be trusted.")
        return previous
    }

    /// Asserts how many logical requests a click started, which no expectation can express.
    ///
    /// The manager advances its request generation once per `streamTTS` call and never on ordinary
    /// completion, so this counts started requests. A mock handler cannot: a duplicate request
    /// replaces the first, whose task may be cancelled before its handler ever runs, which makes a
    /// second fulfilment — and therefore an over-fulfilment failure — depend on timing.
    private func assertRequestsStarted(_ expected: UInt64,
                                       by networkManager: TTSNetworkManager,
                                       from generationBefore: UInt64,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        XCTAssertEqual(
            settledRequestGeneration(of: networkManager) &- generationBefore,
            expected,
            "The click must start exactly \(expected) request(s).",
            file: file,
            line: line
        )
    }

    private func makeOpenAIManager() -> TTSNetworkManager {
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(
            baseURL: "https://api.openai.com/v1/audio/speech",
            apiKey: "test",
            model: "tts-1",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )
        return networkManager
    }

    func testOversizedOpenAIClipboardTextPresentsTheLimitAlertInsteadOfRequestingSpeech() {
        // WHY: OpenAI documents one 4,096-character maximum for `input`, so a longer clipboard
        // value buys a request that can only fail, and the provider's rejection reaches the user as
        // the same generic HTTP failure every other error produces — no indication that the text
        // was simply too long. The click must say what is wrong before spending the request, and
        // must leave the pipeline idle so the next Speak click needs no Clear Buffer first.
        let audioPlayer = AudioPlayerManager()
        let pasteboard = FakePasteboardReader(text: String(repeating: "a", count: 4_097))
        let textExtraction = TextExtractionManager(pasteboard: pasteboard)
        let networkManager = makeOpenAIManager()
        MockURLProtocol.installRequestHandler { request in
            XCTFail("Oversized OpenAI text must not reach the provider.")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let deferral = CapturingDeferralScheduler()
        let alerts = RecordingMenuAlertPresenter()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler),
            alertPresenter: alerts
        )

        let generationBefore = networkManager.currentRequestGeneration()
        view.speakCopiedText()
        deferral.runDeferredActions()

        XCTAssertEqual(pasteboard.readCount, 1, "The refusal judges text the click had already read.")
        XCTAssertEqual(alerts.presentedTitles, [Self.alertTitle])
        XCTAssertEqual(alerts.presentedMessages, [expectedAlertMessage(characterCount: "4,097")])
        XCTAssertFalse(networkManager.isStreaming, "A refused click must start no request.")
        assertRequestsStarted(0, by: networkManager, from: generationBefore)
        XCTAssertFalse(audioPlayer.hasAudio, "A refused click must schedule no audio, so the button stays Speak.")
        XCTAssertNil(
            networkManager.lastError,
            "The pop-up owns this outcome; publishing it too would also render it inline in the menu."
        )
    }

    func testOpenAIClipboardTextAtTheDocumentedLimitStartsExactlyOneRequest() {
        // WHY: The limit is a maximum, not a threshold to stay under. Refusing text OpenAI accepts
        // would block work the user is entitled to, and this boundary is what an off-by-one in
        // either direction moves.
        let audioPlayer = AudioPlayerManager()
        let pasteboard = FakePasteboardReader(text: String(repeating: "a", count: 4_096))
        let textExtraction = TextExtractionManager(pasteboard: pasteboard)
        let networkManager = makeOpenAIManager()
        let requestStarted = expectation(description: "Text at the documented limit reaches the provider")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let deferral = CapturingDeferralScheduler()
        let alerts = RecordingMenuAlertPresenter()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler),
            alertPresenter: alerts
        )

        let generationBefore = networkManager.currentRequestGeneration()
        view.speakCopiedText()
        deferral.runDeferredActions()

        wait(for: [requestStarted], timeout: 2.0)
        assertRequestsStarted(1, by: networkManager, from: generationBefore)
        XCTAssertTrue(alerts.presentedTitles.isEmpty, "Text within the limit must raise no dialog.")
    }

    func testOpenAILimitRefusesFewerGraphemeClustersWhoseScalarsExceedIt() {
        // WHY: The unit is the whole rule. Swift's default `String.count` counts grapheme clusters,
        // so accented text written as a base letter plus a combining mark reads as half its scalar
        // length: this value is 2,049 clusters but 4,098 code points, which is what a provider
        // counting characters as code points sees. Counting clusters would send it and lose the
        // request the check exists to save.
        let combiningAccentText = String(repeating: "e\u{0301}", count: 2_049)
        XCTAssertEqual(combiningAccentText.count, 2_049, "The value must stay under the limit by cluster count.")
        XCTAssertEqual(combiningAccentText.unicodeScalars.count, 4_098, "It must exceed the limit by scalar count.")
        let audioPlayer = AudioPlayerManager()
        let pasteboard = FakePasteboardReader(text: combiningAccentText)
        let textExtraction = TextExtractionManager(pasteboard: pasteboard)
        let networkManager = makeOpenAIManager()
        MockURLProtocol.installRequestHandler { request in
            XCTFail("Text over the scalar limit must not reach the provider.")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let deferral = CapturingDeferralScheduler()
        let alerts = RecordingMenuAlertPresenter()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler),
            alertPresenter: alerts
        )

        let generationBefore = networkManager.currentRequestGeneration()
        view.speakCopiedText()
        deferral.runDeferredActions()

        XCTAssertEqual(alerts.presentedMessages, [expectedAlertMessage(characterCount: "4,098")])
        XCTAssertFalse(networkManager.isStreaming)
        assertRequestsStarted(0, by: networkManager, from: generationBefore)
    }

    func testOpenAILimitAcceptsScalarsWithinItDespiteMoreUTF16UnitsAndBytes() {
        // WHY: The trade-off of choosing a unit runs both ways. Non-BMP characters cost two UTF-16
        // units and four UTF-8 bytes each, so counting either would refuse this value — 4,096 code
        // points, the exact maximum — and every ordinary non-Latin passage far below the limit. A
        // false refusal blocks work OpenAI would have accepted, which no later failure can undo.
        let emojiText = String(repeating: "\u{1F600}", count: 4_096)
        XCTAssertEqual(emojiText.unicodeScalars.count, 4_096, "The value must sit exactly at the limit in scalars.")
        XCTAssertEqual(emojiText.utf16.count, 8_192, "It must exceed the limit in UTF-16 units.")
        XCTAssertEqual(emojiText.utf8.count, 16_384, "It must exceed the limit in UTF-8 bytes.")
        let audioPlayer = AudioPlayerManager()
        let textExtraction = TextExtractionManager(pasteboard: FakePasteboardReader(text: emojiText))
        let networkManager = makeOpenAIManager()
        let requestStarted = expectation(description: "Text within the scalar limit reaches the provider")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let deferral = CapturingDeferralScheduler()
        let alerts = RecordingMenuAlertPresenter()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler),
            alertPresenter: alerts
        )

        let generationBefore = networkManager.currentRequestGeneration()
        view.speakCopiedText()
        deferral.runDeferredActions()

        wait(for: [requestStarted], timeout: 2.0)
        assertRequestsStarted(1, by: networkManager, from: generationBefore)
        XCTAssertTrue(alerts.presentedTitles.isEmpty, "Only OpenAI's own maximum may refuse a click.")
    }

    func testOversizedGeminiClipboardTextStillStartsItsRequest() {
        // WHY: The limit is OpenAI's, not the app's. Gemini documents no such maximum, and the
        // user chose a provider-scoped check precisely so Gemini keeps its one-request, fastest
        // path. A guard that read the endpoint instead of the selected provider could refuse here.
        let audioPlayer = AudioPlayerManager()
        let textExtraction = TextExtractionManager(
            pasteboard: FakePasteboardReader(text: String(repeating: "a", count: 5_000))
        )
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "gemini-token",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Aoede",
            selectedProvider: "Gemini"
        )
        let requestStarted = expectation(description: "The Gemini request reaches the provider")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let deferral = CapturingDeferralScheduler()
        let alerts = RecordingMenuAlertPresenter()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler),
            alertPresenter: alerts
        )

        let generationBefore = networkManager.currentRequestGeneration()
        view.speakCopiedText()
        deferral.runDeferredActions()

        wait(for: [requestStarted], timeout: 2.0)
        assertRequestsStarted(1, by: networkManager, from: generationBefore)
        XCTAssertTrue(alerts.presentedTitles.isEmpty, "Gemini text must not meet OpenAI's limit.")
    }

    func testOversizedCustomClipboardTextStillStartsItsRequest() {
        // WHY: A Custom endpoint's limits belong to whoever runs it, and the default Custom base
        // URL is the same string as OpenAI's fixed endpoint. A check that inferred the provider
        // from the endpoint would silently refuse text a self-hosted service accepts.
        let audioPlayer = AudioPlayerManager()
        let textExtraction = TextExtractionManager(
            pasteboard: FakePasteboardReader(text: String(repeating: "a", count: 5_000))
        )
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(
            baseURL: "https://api.openai.com/v1/audio/speech",
            apiKey: "custom-token",
            model: "custom-model",
            voice: "custom-voice",
            selectedProvider: "Custom"
        )
        let requestStarted = expectation(description: "The Custom request reaches its endpoint")
        MockURLProtocol.installRequestHandler { request in
            requestStarted.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let deferral = CapturingDeferralScheduler()
        let alerts = RecordingMenuAlertPresenter()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler),
            alertPresenter: alerts
        )

        let generationBefore = networkManager.currentRequestGeneration()
        view.speakCopiedText()
        deferral.runDeferredActions()

        wait(for: [requestStarted], timeout: 2.0)
        assertRequestsStarted(1, by: networkManager, from: generationBefore)
        XCTAssertTrue(alerts.presentedTitles.isEmpty, "A Custom endpoint owns its own limits.")
    }

    func testStaleDeferredActionOverTheLimitPresentsNoAlert() {
        // WHY: A dropped attempt speaks for a click the pipeline no longer belongs to, so it must
        // stay silent in every direction: it may neither start speech nor interrupt whatever now
        // owns the pipeline with a modal panel about a clipboard read it never performed.
        let audioPlayer = AudioPlayerManager()
        let pasteboard = FakePasteboardReader(text: String(repeating: "a", count: 4_097))
        let textExtraction = TextExtractionManager(pasteboard: pasteboard)
        let networkManager = makeOpenAIManager()
        let onlyRequest = expectation(description: "Only the Services request reaches the provider")
        MockURLProtocol.installRequestHandler { request in
            onlyRequest.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let deferral = CapturingDeferralScheduler()
        let alerts = RecordingMenuAlertPresenter()
        let view = makeMenu(
            audioPlayer: audioPlayer,
            textExtraction: textExtraction,
            networkManager: networkManager,
            deferredClipboardAction: DeferredClipboardAction(scheduler: deferral.scheduler),
            alertPresenter: alerts
        )

        view.speakCopiedText()

        let center = NotificationCenter()
        let coordinator = ServicesCoordinator(
            speechSession: SpeechSessionCoordinator(audioPlayer: audioPlayer, networkManager: networkManager),
            notificationCenter: center
        )
        withExtendedLifetime(coordinator) {
            center.post(name: ServicesCoordinator.speakSelectedTextNotification, object: "Selected text")
            XCTAssertTrue(networkManager.isStreaming, "The Services request must own the pipeline.")

            deferral.runDeferredActions()

            XCTAssertEqual(pasteboard.readCount, 0, "A stale action reads no clipboard, so it may judge no length.")
            XCTAssertTrue(alerts.presentedTitles.isEmpty, "A stale action must raise no dialog.")
            wait(for: [onlyRequest], timeout: 2.0)
        }
    }
}
