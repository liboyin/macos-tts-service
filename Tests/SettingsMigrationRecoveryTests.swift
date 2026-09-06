import XCTest
@testable import ClipboardTTSApp

/// Covers recovering in Settings from a legacy API key that migration could not secure.
///
/// Hosted Settings drives `NSHostingView` and the AppKit controls it builds, so every test here
/// runs on the main actor.
@MainActor
final class SettingsMigrationRecoveryTests: MockURLProtocolTestCase {

    func testFailedMigrationOffersARetryThatSecuresTheKeyForTheNextRequest() throws {
        // WHY: The failure message tells the user to try again, but migration otherwise reruns only
        // when a new manager is created, so "again" would mean an undocumented relaunch. Recovery
        // has to be reachable where the guidance appears, and it is finished only when the secured
        // key is what the next request sends — not merely when the warning disappears.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.apiBaseURL: "https://custom.api/v1/audio/speech",
            SettingsKeys.customModel: "custom-model",
            SettingsKeys.customVoice: "custom-voice",
            SettingsKeys.legacyCustomAPIKey: "test-legacy-custom-key"
        ])

        let secretStore = ScriptedSecretStore()
        secretStore.failingProviders = [.custom]
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        XCTAssertEqual(networkManager.lastError, APIKeyMigrationService.failureMessage(for: .custom))
        secretStore.failingProviders = []

        let requestEmitted = expectation(description: "The secured key reaches the next request")
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-legacy-custom-key")
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

        XCTAssertTrue(settings.rendersButton(titled: "Retry Securing Saved Keys"))
        XCTAssertNil(secretStore.storedSecret(for: .custom))
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.legacyCustomAPIKey), "test-legacy-custom-key")

        settings.click("Retry Securing Saved Keys")

        XCTAssertEqual(secretStore.storedSecret(for: .custom), "test-legacy-custom-key")
        XCTAssertNil(defaults.object(forKey: SettingsKeys.legacyCustomAPIKey))
        XCTAssertFalse(settings.rendersButton(titled: "Retry Securing Saved Keys"))
        XCTAssertNil(networkManager.lastError)

        // A clipboard or Services request reaches the manager directly, so it proves the retry
        // itself refreshed the credentials rather than the next Settings action doing it.
        networkManager.streamTTS(text: "Speech started after the key was secured") { _ in }

        wait(for: [requestEmitted], timeout: 2.0)
        settings.release()
    }

    func testTheRetryMigratesThePreferencesItWasGivenRatherThanAnotherDomain() {
        // WHY: The form migrates whichever domain it is handed, and the app hands it the domain
        // startup migrated — a private one under test, `UserDefaults.standard` in production. A
        // retry that reached for some other domain instead would leave the key it was given
        // exposed while deleting one belonging to a different configuration.
        let injectedDefaults = InMemoryDefaults()
        let otherDefaults = makeOwnedDefaults()
        let secretStore = ScriptedSecretStore()
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: otherDefaults)
        // Each domain holds a different provider's key, so a form that read the wrong one would
        // both rescue the wrong secret and leave the one it was given behind. Both are seeded after
        // the manager is built, because a manager migrates its own store as it starts up.
        injectedDefaults.set("test-injected-legacy-key", forKey: SettingsKeys.legacyOpenAIAPIKey)
        otherDefaults.set("test-other-domain-legacy-key", forKey: SettingsKeys.legacyCustomAPIKey)

        let requestEmitted = expectation(description: "The injected domain's key reaches the next request")
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            // Opening Settings on OpenAI also fetches its model and voice suggestions.
            guard request.url?.absoluteString == "https://api.openai.com/v1/audio/speech" else {
                return (response, Data("{ \"data\": [] }".utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-injected-legacy-key")
            requestEmitted.fulfill()
            return (response, Data([0, 1]))
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: injectedDefaults,
            testCase: self
        )

        XCTAssertTrue(settings.rendersButton(titled: "Retry Securing Saved Keys"))

        settings.click("Retry Securing Saved Keys")

        XCTAssertEqual(secretStore.storedSecret(for: .openAI), "test-injected-legacy-key")
        XCTAssertNil(injectedDefaults.string(forKey: SettingsKeys.legacyOpenAIAPIKey))
        XCTAssertNil(secretStore.storedSecret(for: .custom))
        XCTAssertEqual(
            otherDefaults.string(forKey: SettingsKeys.legacyCustomAPIKey),
            "test-other-domain-legacy-key"
        )
        XCTAssertFalse(settings.rendersButton(titled: "Retry Securing Saved Keys"))

        networkManager.streamTTS(text: "Speech started after the injected key was secured") { _ in }

        wait(for: [requestEmitted], timeout: 2.0)
        settings.release()
    }

    func testAFailedRetryLosesNothingAndASecondOneKeepsTheNewerSavedKey() throws {
        // WHY: A Keychain that is still unavailable must cost the user nothing: the plaintext key
        // has to survive for the next attempt and the recovery must keep advertising itself rather
        // than look as though it worked. When the store does accept the retry, the same rule that
        // protects a launch applies — a key the user saved after the failure is newer than the
        // plaintext, so securing must remove the stale value without overwriting the good one.
        let defaults = makeOwnedDefaults([
            SettingsKeys.legacyOpenAIAPIKey: "test-stale-legacy-key"
        ])

        let secretStore = ScriptedSecretStore()
        secretStore.seed("test-newer-keychain-key", for: .openAI)
        secretStore.failingProviders = [.openAI]
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        secretStore.failingProviders = []

        let requestEmitted = expectation(description: "Test Voice still uses the newer saved key")
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            // Opening Settings on OpenAI also fetches its model and voice suggestions.
            guard request.url?.absoluteString == "https://api.openai.com/v1/audio/speech" else {
                return (response, Data("{ \"data\": [] }".utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-newer-keychain-key")
            requestEmitted.fulfill()
            return (response, Data([0, 1]))
        }
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            testCase: self
        )
        secretStore.failingProviders = [.openAI]

        settings.click("Retry Securing Saved Keys")

        XCTAssertEqual(defaults.string(forKey: SettingsKeys.legacyOpenAIAPIKey), "test-stale-legacy-key")
        XCTAssertEqual(secretStore.storedSecret(for: .openAI), "test-newer-keychain-key")
        XCTAssertTrue(settings.rendersButton(titled: "Retry Securing Saved Keys"))
        XCTAssertEqual(networkManager.lastError, APIKeyMigrationService.failureMessage(for: .openAI))

        secretStore.failingProviders = []
        settings.click("Retry Securing Saved Keys")

        XCTAssertEqual(secretStore.storedSecret(for: .openAI), "test-newer-keychain-key")
        XCTAssertNil(defaults.object(forKey: SettingsKeys.legacyOpenAIAPIKey))
        XCTAssertFalse(settings.rendersButton(titled: "Retry Securing Saved Keys"))
        XCTAssertNil(networkManager.lastError)

        settings.click("Test Voice")

        wait(for: [requestEmitted], timeout: 2.0)
        settings.release()
    }

    func testPartialMigrationSuccessKeepsOnlyTheStillFailingProviderPending() throws {
        // WHY: One provider's Keychain refusal must not strand the keys that were secured, and a
        // provider that is now safe must not keep claiming the user has plaintext to rescue. The
        // one that failed keeps both its value and a warning that names it, because a warning left
        // naming the recovered provider would send the user looking in the wrong place.
        let defaults = makeOwnedDefaults([
            SettingsKeys.legacyOpenAIAPIKey: "test-legacy-openai-key",
            SettingsKeys.legacyGeminiAPIKey: "test-legacy-gemini-key"
        ])

        let secretStore = ScriptedSecretStore()
        secretStore.failingProviders = [.openAI, .gemini]
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        XCTAssertEqual(networkManager.lastError, APIKeyMigrationService.failureMessage(for: .openAI))
        secretStore.failingProviders = []
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
        secretStore.failingProviders = [.gemini]

        settings.click("Retry Securing Saved Keys")

        XCTAssertEqual(secretStore.storedSecret(for: .openAI), "test-legacy-openai-key")
        XCTAssertNil(defaults.object(forKey: SettingsKeys.legacyOpenAIAPIKey))
        XCTAssertNil(secretStore.storedSecret(for: .gemini))
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.legacyGeminiAPIKey), "test-legacy-gemini-key")
        XCTAssertTrue(settings.rendersButton(titled: "Retry Securing Saved Keys"))
        XCTAssertEqual(networkManager.lastError, APIKeyMigrationService.failureMessage(for: .gemini))
        settings.release()
    }

    func testSavingAKeyOverAPendingMigrationRetiresBothTheRecoveryAndItsWarning() throws {
        // WHY: Typing a key resolves that provider as completely as securing it does, so the menu
        // bar must stop warning about plaintext the app no longer holds and Settings must stop
        // offering to rescue it. Otherwise the user is told to act on a problem they just fixed.
        let defaults = makeOwnedDefaults([
            SettingsKeys.legacyOpenAIAPIKey: "test-legacy-openai-key"
        ])
        let secretStore = ScriptedSecretStore()
        secretStore.failingProviders = [.openAI]
        let audioPlayer = AudioPlayerManager()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        XCTAssertEqual(networkManager.lastError, APIKeyMigrationService.failureMessage(for: .openAI))
        secretStore.failingProviders = []
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
        XCTAssertTrue(settings.rendersButton(titled: "Retry Securing Saved Keys"))

        settings.typeAPIKey("test-typed-openai-key")

        XCTAssertEqual(secretStore.storedSecret(for: .openAI), "test-typed-openai-key")
        XCTAssertNil(defaults.object(forKey: SettingsKeys.legacyOpenAIAPIKey))
        XCTAssertFalse(settings.rendersButton(titled: "Retry Securing Saved Keys"))
        XCTAssertNil(networkManager.lastError)
        settings.release()
    }

    func testALaunchWithNoUnsecuredKeyOffersNoRetryAndWritesNoSecret() throws {
        // WHY: The recovery must be evidence of a real problem. Offering it when nothing is pending
        // invites a Keychain prompt for nothing, and a launch that writes to the store at all could
        // replace a credential it was only ever supposed to read.
        let secretStore = ScriptedSecretStore()
        secretStore.seed("test-openai-key", for: .openAI)
        let audioPlayer = AudioPlayerManager()
        let defaults = makeOwnedDefaults()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
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

        XCTAssertFalse(settings.rendersButton(titled: "Retry Securing Saved Keys"))
        XCTAssertNil(networkManager.lastError)
        XCTAssertEqual(secretStore.savedProviders, [])
        XCTAssertEqual(secretStore.deletedProviders, [])
        XCTAssertEqual(secretStore.storedSecret(for: .openAI), "test-openai-key")
        settings.release()
    }
}
