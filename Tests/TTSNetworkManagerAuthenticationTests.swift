import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerAuthenticationTests: MockURLProtocolTestCase {
    func testUnknownPersistedProviderUsesOpenAIConfigurationBeforeSettingsOpen() throws {
        // WHY: Services can start speech before Settings is constructed. A corrupted provider value
        // must not combine one provider's Keychain key with another provider's persisted endpoint.
        let store = InMemorySecretStore()
        try store.saveSecret("test-openai-api-key", for: .openAI)
        try store.saveSecret("test-custom-api-key", for: .custom)
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Unexpected",
            SettingsKeys.apiBaseURL: "https://custom.example/v1/audio/speech"
        ])

        let manager = TestNetworkFactory.makeManager(secretStore: store, defaults: defaults)
        let requestEmitted = expectation(description: "A normalized OpenAI request is emitted")
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/speech")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-openai-api-key")
            XCTAssertFalse(request.url?.absoluteString.contains("test-openai-api-key") ?? true)
            requestEmitted.fulfill()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data([0, 1]))
        }

        manager.streamTTS(text: "Normalize persisted provider") { _ in }
        wait(for: [requestEmitted], timeout: 2.0)
    }

    // Hosted Settings drives `NSHostingView` and the AppKit controls it builds, so this test runs
    // on the main actor; the rest of this class does not use it.
    @MainActor
    func testSettingsNormalizesUnknownProviderBeforeTestingVoice() throws {
        // WHY: Opening Settings must preserve the same safe provider normalization as startup;
        // otherwise Test Voice could disclose a provider key to a corrupted Custom endpoint.
        let store = InMemorySecretStore()
        try store.saveSecret("test-openai-api-key", for: .openAI)
        try store.saveSecret("test-custom-api-key", for: .custom)
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Unexpected",
            SettingsKeys.apiBaseURL: "https://custom.example/v1/audio/speech"
        ])

        let audioPlayer = AudioPlayerManager()
        let manager = TestNetworkFactory.makeManager(secretStore: store, defaults: defaults)
        let requestEmitted = expectation(description: "Settings uses a normalized OpenAI request")
        MockURLProtocol.installRequestHandler { request in
            let url = request.url?.absoluteString ?? ""
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            // Opening Settings also fetches the normalized provider's model and voice suggestions,
            // which carry the same key and so must not reach the corrupted endpoint either.
            guard url == "https://api.openai.com/v1/audio/speech" else {
                XCTAssertFalse(url.contains("custom.example"), "Settings must not contact the corrupted Custom endpoint.")
                return (response, Data("{ \"data\": [] }".utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-openai-api-key")
            XCTAssertFalse(url.contains("test-openai-api-key"))
            requestEmitted.fulfill()
            return (response, Data([0, 1]))
        }
        let settings = HostedSettings(
            networkManager: manager,
            audioPlayer: audioPlayer,
            secretStore: store,
            defaults: defaults,
            testCase: self
        )

        settings.click("Test Voice")

        wait(for: [requestEmitted], timeout: 2.0)
        settings.release()
    }

    func testFailedSettingsSecretEditRetainsItsActionableError() throws {
        // WHY: A failed Keychain write must remain visible. Retrying an automatic restoration used
        // to erase the warning even though the user's new key was never saved.
        let store = InMemorySecretStore()
        try store.saveSecret("test-original-custom-key", for: .custom)
        let defaults = makeOwnedDefaults()
        let secretState = SettingsSecretState(secretStore: store, defaults: defaults)
        store.nextError = .unavailable

        secretState.saveSecret("test-new-custom-key", for: .custom)

        XCTAssertEqual(
            secretState.errorMessage,
            "Couldn't save the Custom API key. Check Keychain access and try again."
        )
        XCTAssertEqual(try store.secret(for: .custom), "test-original-custom-key")
    }

    func testSecuringEveryPendingKeyWithdrawsTheStartupMigrationWarning() {
        // WHY: The warning is the app's own claim that a saved key is still sitting in preferences.
        // Leaving it up after the user's retry secured every one of them would send them back to a
        // Keychain problem they already solved.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.legacyCustomAPIKey: "test-legacy-custom-key"
        ])
        let store = InMemorySecretStore()
        store.nextError = .unavailable
        let manager = TestNetworkFactory.makeManager(secretStore: store, defaults: defaults)
        XCTAssertEqual(manager.lastError, APIKeyMigrationService.failureMessage(for: .custom))

        manager.updateMigrationFailureWarning(for: nil)

        XCTAssertNil(manager.lastError)
    }

    func testWithdrawingTheMigrationWarningCannotEraseANewerRequestFailure() {
        // WHY: Migration guidance and request failures share one menu-bar channel. Securing a key
        // resolves nothing about a request that failed afterwards, so withdrawing the warning must
        // not silence the guidance the user still needs to make the app speak.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.legacyCustomAPIKey: "test-legacy-custom-key"
        ])
        let store = InMemorySecretStore()
        store.nextError = .unavailable
        let manager = TestNetworkFactory.makeManager(secretStore: store, defaults: defaults)
        XCTAssertEqual(manager.lastError, APIKeyMigrationService.failureMessage(for: .custom))
        let requestFailure = "The TTS endpoint must use HTTPS unless it runs on localhost. Update Settings and try again."
        manager.updateSettings(
            baseURL: "http://custom.api/v1/audio/speech",
            apiKey: "test-custom-key",
            model: "custom-model",
            voice: "custom-voice",
            selectedProvider: "Custom"
        )
        assertTerminalState(of: manager, expectedError: requestFailure) {
            manager.streamTTS(text: "Speech a cleartext endpoint must refuse") { _ in }
        }

        manager.updateMigrationFailureWarning(for: nil)

        XCTAssertEqual(manager.lastError, requestFailure)
    }

    func testProviderCredentialsUseOnlyTheirDocumentedHeaders() {
        // WHY: Keys in a URL can escape through proxies and diagnostics. Each provider must send
        // its token only in its authentication header, while app-owned state remains secret-free.
        let providers = [
            (name: "OpenAI", baseURL: "https://mock.api/v1/audio/speech", selectedProvider: "OpenAI", header: "Authorization", value: "Bearer test-openai-api-key"),
            (name: "Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta", selectedProvider: "Gemini", header: "x-goog-api-key", value: "test-gemini-api-key"),
            (name: "Custom", baseURL: "https://custom.api/v1/audio/speech", selectedProvider: "Custom", header: "Authorization", value: "Bearer test-custom-api-key")
        ]

        for provider in providers {
            let defaults = makeOwnedDefaults()
            let manager = TestNetworkFactory.makeManager(defaults: defaults)
            let token = provider.value.replacingOccurrences(of: "Bearer ", with: "")
            manager.updateSettings(
                baseURL: provider.baseURL,
                apiKey: token,
                model: "test-model",
                voice: "test-voice",
                selectedProvider: provider.selectedProvider
            )
            let requestEmitted = expectation(description: "\(provider.name) request is emitted")
            MockURLProtocol.installRequestHandler { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: provider.header), provider.value)
                XCTAssertFalse(request.url?.absoluteString.contains(token) ?? true)
                if provider.name == "Gemini" {
                    XCTAssertEqual(request.url?.query, "alt=sse")
                    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                } else {
                    XCTAssertNil(request.url?.query)
                    XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
                }
                requestEmitted.fulfill()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data([0, 1]))
            }

            manager.streamTTS(text: "Verify \(provider.name) authentication") { _ in }
            wait(for: [requestEmitted], timeout: 2.0)
            XCTAssertFalse(SettingsKeys.allUserDefaultsKeys.contains { defaults.string(forKey: $0) == token })
        }
    }
}
