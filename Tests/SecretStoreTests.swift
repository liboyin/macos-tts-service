import XCTest
@testable import ClipboardTTSApp

final class SecretStoreTests: MockURLProtocolTestCase {
    func testInMemorySecretStoreCreatesReadsUpdatesAndDeletesSecrets() throws {
        // WHY: Settings needs one store contract for all providers, so this proves an edit replaces
        // rather than duplicates a key and clearing the field removes it from future requests.
        let store = InMemorySecretStore()

        XCTAssertNil(try store.secret(for: .openAI))
        try store.saveSecret("test-openai-key-one", for: .openAI)
        XCTAssertEqual(try store.secret(for: .openAI), "test-openai-key-one")

        try store.saveSecret("test-openai-key-two", for: .openAI)
        XCTAssertEqual(try store.secret(for: .openAI), "test-openai-key-two")

        try store.deleteSecret(for: .openAI)
        XCTAssertNil(try store.secret(for: .openAI))
    }

    func testMigrationPreservesLegacyPreferenceAndMapsAStoreFailureToActionableGuidance() throws {
        // WHY: Migration is allowed to delete a plaintext key only after Keychain confirms its
        // write. Retaining it on failure lets the user recover instead of losing their only key.
        let store = InMemorySecretStore()
        let legacySecret = "test-legacy-openai-key"
        let defaults = makeOwnedDefaults([
            SettingsKeys.legacyOpenAIAPIKey: legacySecret
        ])
        store.nextError = .unavailable

        let outcome = APIKeyMigrationService(secretStore: store).migrateLegacyAPIKeys(defaults: defaults)

        XCTAssertEqual(outcome.pendingProviders, [.openAI])
        XCTAssertEqual(outcome.securedSecrets, [:])
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.legacyOpenAIAPIKey), legacySecret)
        XCTAssertNil(try store.secret(for: .openAI))
        XCTAssertEqual(
            APIKeyMigrationService.failureMessage(for: .openAI),
            "Couldn't secure the saved OpenAI API key. It remains in Settings; check Keychain access and try again."
        )
    }

    func testStartupPublishesMigrationFailureWhilePreservingLegacySecret() {
        // WHY: A retained legacy key is only recoverable if startup exposes a safe, actionable
        // warning. Otherwise migration can fail silently and leave plaintext credentials behind.
        let store = InMemorySecretStore()
        let legacySecret = "test-legacy-custom-key"
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.legacyCustomAPIKey: legacySecret
        ])
        store.nextError = .unavailable

        let manager = TestNetworkFactory.makeManager(secretStore: store, defaults: defaults)

        XCTAssertEqual(
            manager.lastError,
            "Couldn't secure the saved Custom API key. It remains in Settings; check Keychain access and try again."
        )
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.legacyCustomAPIKey), legacySecret)
        XCTAssertNil(try? store.secret(for: .custom))
    }

    func testPendingProvidersNameOnlyTheKeysAMigrationRetryStillHasToSecure() {
        // WHY: Settings decides from this set whether to offer recovery at all. A key the store
        // already accepted must not invite a retry that touches the Keychain again, and an empty
        // legacy value carries no secret to rescue — only a retained plaintext key can still be
        // lost, which is exactly what a failed migration leaves behind.
        let store = InMemorySecretStore()
        let defaults = makeOwnedDefaults([
            SettingsKeys.legacyOpenAIAPIKey: "test-legacy-openai-key",
            SettingsKeys.legacyGeminiAPIKey: "",
            SettingsKeys.legacyCustomAPIKey: "test-legacy-custom-key"
        ])
        store.nextError = .unavailable

        XCTAssertEqual(APIKeyMigrationService.pendingProviders(defaults: defaults), [.openAI, .custom])

        // The scheduled failure lands on the first provider the migration touches.
        let outcome = APIKeyMigrationService(secretStore: store).migrateLegacyAPIKeys(defaults: defaults)

        XCTAssertEqual(outcome.pendingProviders, [.openAI])
        XCTAssertEqual(outcome.securedSecrets, [.custom: "test-legacy-custom-key"])
        XCTAssertEqual(APIKeyMigrationService.pendingProviders(defaults: defaults), [.openAI])
    }

    func testMigrationMovesLegacySecretOnceAndDoesNotRewriteOnTheNextLaunch() throws {
        // WHY: A completed migration must remove the plaintext source, so a later launch neither
        // exposes it through UserDefaults nor overwrites the Keychain value again.
        let store = InMemorySecretStore()
        let legacySecret = "test-legacy-gemini-key"
        let defaults = makeOwnedDefaults([
            SettingsKeys.legacyGeminiAPIKey: legacySecret
        ])
        let migration = APIKeyMigrationService(secretStore: store)

        XCTAssertEqual(migration.migrateLegacyAPIKeys(defaults: defaults), APIKeyMigrationOutcome(securedSecrets: [.gemini: legacySecret]))
        XCTAssertEqual(try store.secret(for: .gemini), legacySecret)
        XCTAssertNil(defaults.object(forKey: SettingsKeys.legacyGeminiAPIKey))

        XCTAssertEqual(migration.migrateLegacyAPIKeys(defaults: defaults), APIKeyMigrationOutcome())
        XCTAssertEqual(try store.secret(for: .gemini), legacySecret)
        XCTAssertNil(defaults.object(forKey: SettingsKeys.legacyGeminiAPIKey))
    }

    func testMigrationPreservesAnExistingKeychainSecretOverStalePlaintext() throws {
        // WHY: A user can save a replacement after a failed migration. A later launch must remove
        // the stale plaintext value without overwriting the newer Keychain credential.
        let store = InMemorySecretStore()
        try store.saveSecret("test-new-keychain-key", for: .openAI)
        let defaults = makeOwnedDefaults([
            SettingsKeys.legacyOpenAIAPIKey: "test-stale-legacy-key"
        ])

        XCTAssertEqual(
            APIKeyMigrationService(secretStore: store).migrateLegacyAPIKeys(defaults: defaults),
            APIKeyMigrationOutcome(securedSecrets: [.openAI: "test-new-keychain-key"])
        )
        XCTAssertEqual(try store.secret(for: .openAI), "test-new-keychain-key")
        XCTAssertNil(defaults.object(forKey: SettingsKeys.legacyOpenAIAPIKey))
    }
}
