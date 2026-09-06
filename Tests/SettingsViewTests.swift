import XCTest
@testable import ClipboardTTSApp

/// Covers how the Settings form configures audio format, credentials, and the next speech request.
///
/// Hosted Settings drives `NSHostingView` and the AppKit controls it builds, so every test here
/// runs on the main actor.
@MainActor
final class SettingsViewTests: MockURLProtocolTestCase {

    func testCustomSampleRatePersistsAndOtherProvidersResetTo24KHz() {
        // WHY: Only Custom PCM may use a user override. Switching away must reset the live graph
        // to the documented provider format so a later OpenAI or Gemini response is never decoded
        // at the previous Custom rate.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.customSampleRate: 48_000.0
        ])

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        // Selecting OpenAI also fetches its model and voice suggestions.
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{ \"data\": [] }".utf8))
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        XCTAssertEqual(audioPlayer.sampleRate, 48_000)

        settings.selectProvider("OpenAI")

        XCTAssertEqual(audioPlayer.sampleRate, 24_000)
        settings.release()
    }

    func testInvalidCustomSampleRateIsReportedWithoutStartingTestVoice() {
        // WHY: The Settings field must refuse invalid PCM rates before a Test Voice request can
        // stream bytes into an unchanged graph, and its established error is rendered inline.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.customSampleRate: 48_001.0
        ])

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        MockURLProtocol.installRequestHandler { _ in
            XCTFail("An invalid PCM rate must not start Test Voice")
            return (HTTPURLResponse(), Data())
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        settings.click("Test Voice")

        XCTAssertEqual(audioPlayer.sampleRate, 24_000)
        XCTAssertEqual(audioPlayer.sampleRateError, "PCM sample rate must be a finite value from 8,000 to 48,000 Hz.")
        XCTAssertFalse(networkManager.isStreaming)
        settings.release()
    }

    func testInvalidCustomSampleRateEditKeepsTheLastKnownGoodPersistedValue() {
        // WHY: A malformed draft must remain visible for correction without becoming startup
        // configuration. Otherwise a relaunch could silently decode Custom PCM at the default rate.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.customSampleRate: 24_000.0
        ])

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        settings.type("48001", into: .customSampleRate, expecting: "24000")

        XCTAssertEqual(defaults.double(forKey: SettingsKeys.customSampleRate), 24_000)
        XCTAssertFalse(audioPlayer.hasValidSampleRateConfiguration)
        XCTAssertEqual(audioPlayer.sampleRateError, "PCM sample rate must be a finite value from 8,000 to 48,000 Hz.")
        settings.release()
    }

    func testInvalidCustomSampleRateDraftBlocksTestVoiceAndSubsequentSettingsSync() {
        // WHY: A visible invalid draft must remain the active validation state until corrected.
        // Otherwise a later sync could silently recover the saved 24-kHz graph and speak despite
        // the field still showing a Custom format the app refuses to decode.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom"
        ])
        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        MockURLProtocol.installRequestHandler { _ in
            XCTFail("An invalid Custom PCM draft must not start Test Voice")
            return (HTTPURLResponse(), Data())
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        settings.type("48001", into: .customSampleRate, expecting: "24000")
        // Editing the model runs the same settings sync an endpoint or provider edit runs, so the
        // invalid draft has to survive a sync it did not initiate.
        settings.type("custom-model", into: .customModel, expecting: "")

        XCTAssertEqual(audioPlayer.sampleRateError, "PCM sample rate must be a finite value from 8,000 to 48,000 Hz.")
        XCTAssertFalse(networkManager.isStreaming)

        settings.click("Test Voice")

        XCTAssertEqual(audioPlayer.sampleRateError, "PCM sample rate must be a finite value from 8,000 to 48,000 Hz.")
        XCTAssertFalse(networkManager.isStreaming)
        settings.release()
    }

    func testTestVoiceDoesNotStartRequestWhenDefaultRateEngineCannotRecover() {
        // WHY: A sample rate can match the selected provider while its graph failed to start.
        // Test Voice must retry that graph and keep its failure visible instead of sending a TTS
        // request that cannot play.
        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager(engineStarter: { _ in throw EngineStartFailure.failed })
        let defaults = makeOwnedDefaults()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        // Opening Settings on OpenAI fetches its model and voice suggestions, so only a request to
        // the speech endpoint would mean Test Voice ignored the stopped graph.
        MockURLProtocol.installRequestHandler { request in
            XCTAssertNotEqual(
                request.url?.absoluteString,
                "https://api.openai.com/v1/audio/speech",
                "A stopped audio graph must not start Test Voice"
            )
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{ \"data\": [] }".utf8))
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        settings.click("Test Voice")

        XCTAssertEqual(audioPlayer.sampleRate, 24_000)
        XCTAssertEqual(audioPlayer.sampleRateError, "Couldn't start audio playback. Try again.")
        XCTAssertFalse(networkManager.isStreaming)
        settings.release()
    }

    func testCustomTestVoiceEmitsConfiguredOpenAICompatiblePayload() {
        // WHY: Test Voice must synchronize persisted Custom settings into the production request
        // path, so an endpoint test proves the same model/voice contract as normal speech.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.legacyCustomAPIKey: "test-custom-key",
            SettingsKeys.apiBaseURL: "https://custom.api/v1/audio/speech",
            SettingsKeys.customModel: "custom-model",
            SettingsKeys.customVoice: "custom-voice"
        ])

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        // Constructing the manager first migrates the legacy plaintext key into the store, which is
        // where the form then reads it.
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)

        let requestEmitted = expectation(description: "Custom Test Voice request is emitted")
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://custom.api/v1/audio/speech")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-custom-key")
            let bodyData = try XCTUnwrap(requestBodyData(from: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: String])
            XCTAssertEqual(Set(body.keys), ["model", "input", "voice", "response_format"])
            XCTAssertEqual(body["model"], "custom-model")
            XCTAssertEqual(body["voice"], "custom-voice")
            XCTAssertEqual(body["response_format"], "pcm")
            requestEmitted.fulfill()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data([0, 1]))
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        settings.click("Test Voice")

        wait(for: [requestEmitted], timeout: 2.0)
        settings.release()
    }

    func testCustomTestVoiceRejectsWhitespaceConfigurationWithoutStartingARequest() {
        // WHY: Test Voice must use the same Custom validation as clipboard and Services speech.
        // Otherwise a test action could contact an endpoint with a configuration normal speech
        // correctly rejects, making Settings appear to work while it uses a different contract.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.apiBaseURL: "https://custom.api/v1/audio/speech",
            SettingsKeys.customModel: "\n\t ",
            SettingsKeys.customVoice: "custom-voice"
        ])

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        MockURLProtocol.installRequestHandler { _ in
            XCTFail("Invalid Custom Test Voice configuration must not contact the endpoint")
            return (HTTPURLResponse(), Data())
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        assertTerminalState(
            of: networkManager,
            expectedError: "Custom TTS requires a model and voice. Update Settings and try again."
        ) {
            settings.click("Test Voice")
        }
        settings.release()
    }

    func testCustomTestVoiceRejectsACleartextEndpointWithoutStartingARequest() {
        // WHY: Settings is where the Custom endpoint is typed, so Test Voice is the first action
        // that would send the saved key to it. It must refuse cleartext with the same message and
        // the same no-request outcome as clipboard and Services speech.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.legacyCustomAPIKey: "test-custom-key",
            SettingsKeys.apiBaseURL: "http://custom.api/v1/audio/speech",
            SettingsKeys.customModel: "custom-model",
            SettingsKeys.customVoice: "custom-voice"
        ])

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        MockURLProtocol.installRequestHandler { _ in
            XCTFail("A cleartext Custom endpoint must not be contacted")
            return (HTTPURLResponse(), Data())
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        assertTerminalState(
            of: networkManager,
            expectedError: "The TTS endpoint must use HTTPS unless it runs on localhost. Update Settings and try again."
        ) {
            settings.click("Test Voice")
        }
        settings.release()
    }

    func testProviderSwitchRetargetsTestVoiceAtTheNewlySelectedProvider() throws {
        // WHY: After the user selects a provider, Test Voice must resolve that provider's endpoint
        // and send its own documented credential header. Gemini is the case worth driving from the
        // form, because it is the one provider whose endpoint and header both differ from the
        // OpenAI-compatible default, so a per-provider mistake in either reaches users as a key
        // sent to the wrong host or a request that cannot authenticate.
        let secretStore = InMemorySecretStore()
        try secretStore.saveSecret("test-gemini-api-key", for: .gemini)
        let audioPlayer = AudioPlayerManager()
        let defaults = makeOwnedDefaults()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)

        let requestEmitted = expectation(description: "Test Voice reaches the newly selected Gemini endpoint")
        MockURLProtocol.installRequestHandler { request in
            let url = request.url?.absoluteString ?? ""
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            // Opening Settings on OpenAI first fetches its model and voice suggestions.
            guard url.contains(":streamGenerateContent") else {
                return (response, Data("{ \"data\": [] }".utf8))
            }
            XCTAssertTrue(url.hasPrefix("https://generativelanguage.googleapis.com/v1beta/models/"), url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-gemini-api-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            requestEmitted.fulfill()
            return (response, Data())
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        settings.selectProvider("Gemini")
        settings.click("Test Voice")

        wait(for: [requestEmitted], timeout: 2.0)
        settings.release()
    }

    func testSettingsKeepsOneRetainedSecretStateAcrossEditsAndActions() throws {
        // WHY: Settings holds the user's typed keys in one state object that reads the secret store
        // once. A form that rebuilt that object per access — which is exactly what an uninstalled
        // view does — would re-read storage instead of retaining the edit, so a later action could
        // speak with a key the user never typed here. Changing the store behind the form is what
        // separates the retained object from one rebuilt on demand.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.apiBaseURL: "https://custom.api/v1/audio/speech",
            SettingsKeys.customModel: "custom-model",
            SettingsKeys.customVoice: "custom-voice"
        ])

        let secretStore = InMemorySecretStore()
        try secretStore.saveSecret("test-stored-key", for: .custom)
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)

        let requestEmitted = expectation(description: "Test Voice uses the key retained by the form")
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-typed-key")
            requestEmitted.fulfill()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data([0, 1]))
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        settings.typeAPIKey("test-first-key")
        settings.typeAPIKey("test-typed-key")
        // Nothing in the app rewrites the key behind an open form. This stands in for the rebuilt
        // state an uninstalled view produced, which would read this value instead of the edit.
        try secretStore.saveSecret("test-out-of-band-key", for: .custom)

        settings.click("Test Voice")

        wait(for: [requestEmitted], timeout: 2.0)
        XCTAssertEqual(try secretStore.secret(for: .custom), "test-out-of-band-key")
        settings.release()
    }
}

private enum EngineStartFailure: Error {
    case failed
}
