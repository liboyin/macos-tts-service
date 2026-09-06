import XCTest
@testable import ClipboardTTSApp

/// Covers which suggestions a provider's Settings form may offer and how its selection stays valid.
///
/// Hosted Settings drives `NSHostingView` and the AppKit controls it builds, so every test here
/// runs on the main actor.
@MainActor
final class SettingsVoiceMetadataTests: MockURLProtocolTestCase {
    func testSettingsSuggestsTheCompleteDocumentedGeminiVoiceCatalog() {
        // WHY: Settings is where a user types a voice, and since the menu stopped offering one it is
        // the only surface a documented voice can reach. Publishing a subset of the provider
        // contract would put a documented voice out of reach entirely, so this drives the rendered
        // Settings form and reads back the voice suggestions it actually shows.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Gemini"
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

        XCTAssertEqual(networkManager.voiceSuggestions.values, documentedGeminiTTSVoices)
        XCTAssertEqual(
            settings.suggestionLists().filter { $0 == documentedGeminiTTSVoices }.count,
            1,
            "Settings must offer the documented Gemini voices in exactly one suggestion control."
        )
        settings.release()
    }

    func testFormOffersNoSuggestionListPublishedForAnotherProvider() {
        // WHY: A published catalog outlives the request that fetched it, and the form renders a
        // newly selected provider's saved values one render before its own `onChange` can
        // resynchronize the manager. Offering that other provider's choices would both misdescribe
        // this provider's contract and leave the picker's selection without a matching tag, which
        // SwiftUI documents as undefined. Custom is what holds that state still: it fetches no
        // metadata, so nothing replaces the OpenAI lists this manager already published.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.apiBaseURL: "https://custom.api/v1/audio/speech",
            SettingsKeys.customModel: "custom-model",
            SettingsKeys.customVoice: "custom-voice"
        ])

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        networkManager.modelSuggestions = ProviderSuggestions(provider: "OpenAI", values: ["tts-1", "tts-1-hd"])
        networkManager.voiceSuggestions = ProviderSuggestions(provider: "OpenAI", values: ["alloy", "nova"])

        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        XCTAssertEqual(settings.suggestionControls(), [], "A Custom form must offer no OpenAI choice.")
        // Without these the assertion above could pass because the lists were replaced or cleared,
        // which is a different guarantee from refusing to render another provider's list.
        XCTAssertEqual(networkManager.modelSuggestions.values, ["tts-1", "tts-1-hd"])
        XCTAssertEqual(networkManager.voiceSuggestions.values, ["alloy", "nova"])
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.customModel), "custom-model")
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.customVoice), "custom-voice")
        settings.release()
    }

    func testFieldsOfferChoicesForTheProviderTheyRenderNotTheOneTheManagerHolds() {
        // WHY: A provider switch renders the new provider's fields once before `onChange`
        // resynchronizes the manager. That render is the defect's whole window, and SwiftUI commits
        // no AppKit state for it — by the time a hosted form can be read, the manager has already
        // been resynchronized and its stale lists cleared. Rendering the fields directly is what
        // holds that configuration still, so the rule stays enforceable: the choices must follow
        // the provider being rendered, never whichever provider the manager is synchronized to.
        let networkManager = TestNetworkFactory.makeManager()
        networkManager.updateSettings(
            baseURL: "https://api.openai.com/v1/audio/speech",
            apiKey: "test-key",
            model: "tts-1",
            voice: "alloy",
            selectedProvider: "OpenAI"
        )
        networkManager.modelSuggestions = ProviderSuggestions(provider: "OpenAI", values: ["tts-1", "tts-1-hd"])
        networkManager.voiceSuggestions = ProviderSuggestions(provider: "OpenAI", values: ["alloy", "nova"])

        let switchedFields = HostedModelVoiceFields(
            networkManager: networkManager,
            provider: "Gemini",
            model: "gemini-3.1-flash-tts-preview",
            voice: "Aoede",
            testCase: self
        )

        XCTAssertEqual(switchedFields.suggestionControls(), [], "A Gemini render must offer no OpenAI choice.")
        switchedFields.release()

        // The same manager state must still offer its own provider's choices, so the assertion
        // above cannot pass merely because these fields render no picker at all.
        let openAIFields = HostedModelVoiceFields(
            networkManager: networkManager,
            provider: "OpenAI",
            model: "tts-1",
            voice: "alloy",
            testCase: self
        )

        XCTAssertEqual(
            openAIFields.suggestionControls(),
            [
                HostedSettings.SuggestionControl(choices: ["tts-1", "tts-1-hd"], selection: "tts-1"),
                HostedSettings.SuggestionControl(choices: ["alloy", "nova"], selection: "alloy")
            ]
        )
        openAIFields.release()
    }

    func testTypedOffCatalogModelAndVoiceStaySelectedBesideTheDocumentedCatalog() throws {
        // WHY: A model or voice the documented catalog does not list is still the user's choice, so
        // the form must keep each exactly as typed and speak with it, while offering the catalog it
        // can be corrected from. Dropping either from its picker would leave that selection without
        // a matching tag; replacing it with a catalog entry would send a request the user never
        // configured. Both fields are driven because each renders its own picker.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Gemini"
        ])
        let secretStore = InMemorySecretStore()
        try secretStore.saveSecret("test-gemini-api-key", for: .gemini)
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)

        let requestEmitted = expectation(description: "Test Voice sends the typed Gemini model and voice")
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let url = try XCTUnwrap(request.url?.absoluteString)
            XCTAssertTrue(url.contains("/models/gemini-3.1-pro-tts-preview:"), url)
            let bodyData = try XCTUnwrap(requestBodyData(from: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            XCTAssertEqual(geminiVoiceName(in: body), "Unlisted-Preview-Voice")
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

        settings.type("gemini-3.1-pro-tts-preview", into: .providerModel, expecting: "gemini-3.1-flash-tts-preview")
        settings.type("Unlisted-Preview-Voice", into: .providerVoice, expecting: "Aoede")

        XCTAssertEqual(
            settings.suggestionControls(),
            [
                HostedSettings.SuggestionControl(
                    choices: ["gemini-3.1-pro-tts-preview", "gemini-3.1-flash-tts-preview"],
                    selection: "gemini-3.1-pro-tts-preview"
                ),
                HostedSettings.SuggestionControl(
                    choices: ["Unlisted-Preview-Voice"] + documentedGeminiTTSVoices,
                    selection: "Unlisted-Preview-Voice"
                )
            ]
        )
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.geminiModel), "gemini-3.1-pro-tts-preview")
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.geminiVoice), "Unlisted-Preview-Voice")

        settings.click("Test Voice")

        wait(for: [requestEmitted], timeout: 2.0)
        settings.release()
    }

    func testProviderSwitchOffersOnlyTheNewProviderCatalogWithItsOwnSavedValues() {
        // WHY: This is the switch that rendered Gemini's saved model and voice against OpenAI's
        // still-published lists. Afterwards the form must offer only Gemini's choices, must still
        // show the values saved for Gemini rather than one carried over from the provider it left,
        // and each picker must display its own selection.
        let defaults = makeOwnedDefaults([
            SettingsKeys.geminiVoice: "Sulafat"
        ])

        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{ \"data\": [{\"id\": \"tts-1\"}, {\"id\": \"tts-1-hd\"}] }".utf8))
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )

        XCTAssertEqual(settings.suggestionLists().first, ["tts-1", "tts-1-hd"])

        settings.selectProvider("Gemini")

        XCTAssertEqual(
            settings.suggestionControls(),
            [
                HostedSettings.SuggestionControl(
                    choices: ["gemini-3.1-flash-tts-preview"],
                    selection: "gemini-3.1-flash-tts-preview"
                ),
                HostedSettings.SuggestionControl(choices: documentedGeminiTTSVoices, selection: "Sulafat")
            ]
        )
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.geminiVoice), "Sulafat")
        settings.release()
    }
}

/// Reads the voice a Gemini speech request asks for out of its nested request body.
private func geminiVoiceName(in body: [String: Any]) -> String? {
    let generationConfig = body["generationConfig"] as? [String: Any]
    let speechConfig = generationConfig?["speechConfig"] as? [String: Any]
    let voiceConfig = speechConfig?["voiceConfig"] as? [String: Any]
    let prebuiltVoiceConfig = voiceConfig?["prebuiltVoiceConfig"] as? [String: Any]
    return prebuiltVoiceConfig?["voiceName"] as? String
}
