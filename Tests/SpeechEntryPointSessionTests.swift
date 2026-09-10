import Combine
import XCTest
@testable import ClipboardTTSApp

/// Every speech entry point speaks through the shared session owner rather than sequencing the two
/// managers itself.
///
/// The suites that own each entry point cover its own policy — the menu's deferred clipboard read
/// and length refusal, Settings' configuration synchronization and request payload — and all of
/// those still pass against the direct manager sequence this change replaced, because it started
/// the same request and buffered the same PCM. The recorded ending is the one observable difference,
/// so these are the tests a reverted call site has to fail. The macOS Services entry point is
/// covered by `ServicesCoordinatorTests`, which owns its notification handoff.
///
/// Both entry points drive AppKit and the main-confined player, so this suite runs on the main
/// actor. Each player holds its deferred automatic start instead of running it, because these tests
/// observe what a session records rather than what it plays.
@MainActor
final class SpeechEntryPointSessionTests: MockURLProtocolTestCase {

    func testSpeakCopiedTextEndsItsSessionOnThePlayerItSpokeInto() {
        // WHY: The menu speaks through the shared session owner, and the recorded ending is the
        // only thing that distinguishes that from the direct manager sequence it replaced. A click
        // path reverted to requesting audio alone would still start a request and still buffer the
        // PCM this suite's other tests observe, so nothing but the ending would notice.
        let audioPlayer = AudioPlayerManager(automaticPlaybackScheduler: ManualAutomaticPlaybackScheduler().schedule)
        defer { audioPlayer.stop() }
        let textExtraction = TextExtractionManager(pasteboard: FakePasteboardReader(text: "Speak me"))
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(
            baseURL: "https://mock.api/v1/audio/speech",
            apiKey: "test",
            model: "test",
            voice: "test",
            selectedProvider: "OpenAI"
        )
        MockURLProtocol.installRequestHandler { request in
            (mockHTTPResponse(for: request, statusCode: 200), Data(repeating: 0, count: 2_048))
        }
        let sessionEnded = expectation(description: "The menu's session records how its request ended")
        sessionEnded.assertForOverFulfill = false
        let observation = audioPlayer.$streamTermination.sink { if $0 != nil { sessionEnded.fulfill() } }
        defer { observation.cancel() }

        let view = makeMenu(audioPlayer: audioPlayer, textExtraction: textExtraction, networkManager: networkManager)
        view.speakCopiedText()

        // The click defers its clipboard read by 0.2 seconds before the request can even start.
        wait(for: [sessionEnded], timeout: 3.0)
        XCTAssertEqual(audioPlayer.streamTermination, .finished)
        XCTAssertTrue(audioPlayer.hasAudio, "A finished session keeps the speech it delivered.")
    }

    func testTestVoiceEndsItsSessionOnThePlayerItSpokeInto() {
        // WHY: Test Voice speaks through the shared session owner, and the recorded ending is what
        // that buys over the direct manager sequence it replaced. The suites above prove the form
        // synchronizes its configuration and emits the request; a call site reverted to requesting
        // audio alone would satisfy every one of them while discarding the ending.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.apiBaseURL: "https://custom.api/v1/audio/speech",
            SettingsKeys.customModel: "custom-model",
            SettingsKeys.customVoice: "custom-voice"
        ])
        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager(automaticPlaybackScheduler: ManualAutomaticPlaybackScheduler().schedule)
        defer { audioPlayer.stop() }
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        MockURLProtocol.installRequestHandler { request in
            (mockHTTPResponse(for: request, statusCode: 200), Data(repeating: 0, count: 2_048))
        }
        let sessionEnded = expectation(description: "Test Voice records how its request ended")
        sessionEnded.assertForOverFulfill = false
        let observation = audioPlayer.$streamTermination.sink { if $0 != nil { sessionEnded.fulfill() } }
        defer { observation.cancel() }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        settings.click("Test Voice")

        wait(for: [sessionEnded], timeout: 3.0)
        XCTAssertEqual(audioPlayer.streamTermination, .finished)
        XCTAssertTrue(audioPlayer.hasAudio, "A finished session keeps the speech it delivered.")
        settings.release()
    }
}
