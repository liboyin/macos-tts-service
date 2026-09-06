import XCTest
@testable import ClipboardTTSApp

/// Covers the Settings form's retained key storage: what it publishes about a storage failure,
/// and what a user edit or a migration retry changes about the keys it holds.
final class SettingsSecretStateTests: MockURLProtocolTestCase {
    func testASuccessfulRetryWithdrawsTheReadFailureItJustDisproved() {
        // WHY: The form's guidance must describe the storage the user can see now. Reading the
        // secured key back proves the Keychain answers again, so leaving the mount-time read
        // failure on screen would send the user after a problem the app has already watched resolve
        // — next to a recovery action that has just disappeared.
        let defaults = makeOwnedDefaults([
            SettingsKeys.legacyOpenAIAPIKey: "test-legacy-openai-key"
        ])
        let secretStore = ScriptedSecretStore()
        secretStore.failingProviders = [.openAI]
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: defaults)
        XCTAssertEqual(
            secretState.errorMessage,
            "Couldn't read the saved OpenAI API key. Check Keychain access and try again."
        )

        secretStore.failingProviders = []
        secretState.retryLegacyKeyMigration()

        XCTAssertEqual(secretState.pendingMigrationProviders, [])
        XCTAssertEqual(secretState.secret(for: .openAI), "test-legacy-openai-key")
        XCTAssertNil(secretState.errorMessage)
    }

    func testASuccessfulRetryReplacesItsOwnReadFailureWithTheNextUnresolvedOne() {
        // WHY: The form shows one storage failure at a time, so resolving whichever provider was
        // named first must not read as "storage works now" while another key is still unreadable.
        // The user would be left with no warning at all about a key they cannot use, next to a
        // recovery action that has just disappeared.
        let defaults = makeOwnedDefaults([
            SettingsKeys.legacyOpenAIAPIKey: "test-legacy-openai-key"
        ])
        let secretStore = ScriptedSecretStore()
        secretStore.failingProviders = [.openAI, .gemini]
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: defaults)
        XCTAssertEqual(
            secretState.errorMessage,
            "Couldn't read the saved OpenAI API key. Check Keychain access and try again."
        )

        secretStore.failingProviders = [.gemini]
        secretState.retryLegacyKeyMigration()

        XCTAssertEqual(secretState.pendingMigrationProviders, [])
        XCTAssertEqual(secretState.secret(for: .openAI), "test-legacy-openai-key")
        XCTAssertEqual(
            secretState.errorMessage,
            "Couldn't read the saved Gemini API key. Check Keychain access and try again."
        )
    }

    func testASuccessfulRetryLeavesAnUnfixedSaveFailureOnScreen() {
        // WHY: Securing an old key says nothing about the key the user just typed and the store
        // refused. Treating the retry as a general all-clear would drop the only sign that their
        // edit was never persisted, and they would go on believing it had been.
        let defaults = makeOwnedDefaults([
            SettingsKeys.legacyOpenAIAPIKey: "test-legacy-openai-key"
        ])
        let secretStore = ScriptedSecretStore()
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: defaults)
        secretStore.failingProviders = [.custom]
        secretState.saveSecret("test-typed-custom-key", for: .custom)
        let saveFailure = "Couldn't save the Custom API key. Check Keychain access and try again."
        XCTAssertEqual(secretState.errorMessage, saveFailure)

        secretStore.failingProviders = []
        secretState.retryLegacyKeyMigration()

        XCTAssertEqual(secretState.pendingMigrationProviders, [])
        XCTAssertEqual(secretState.secret(for: .openAI), "test-legacy-openai-key")
        XCTAssertEqual(secretState.errorMessage, saveFailure)
    }

    func testASecuredKeyIsAdoptedEvenWhenTheStoreRefusesEveryFurtherRead() {
        // WHY: Once the store confirms the write the plaintext is gone, so learning what was just
        // secured must not depend on asking the store again. A Keychain that fails in that window
        // would otherwise retire the recovery action while leaving the form and future requests
        // with no credential, and no plaintext left to migrate on a later attempt.
        let defaults = makeOwnedDefaults([
            SettingsKeys.legacyOpenAIAPIKey: "test-legacy-openai-key"
        ])
        let secretStore = ScriptedSecretStore()
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: defaults)
        // The migration's own read is the last one the store will answer.
        secretStore.allowedReadCount = 1

        secretState.retryLegacyKeyMigration()

        XCTAssertEqual(secretState.pendingMigrationProviders, [])
        XCTAssertEqual(secretState.secret(for: .openAI), "test-legacy-openai-key")
        XCTAssertEqual(secretStore.storedSecret(for: .openAI), "test-legacy-openai-key")
        XCTAssertNil(defaults.object(forKey: SettingsKeys.legacyOpenAIAPIKey))
    }

    func testClearingAKeyRetiresThePlaintextCopyThatWouldOtherwiseRestoreIt() {
        // WHY: Clearing the field is the user withdrawing a credential. While a failed migration's
        // plaintext copy outlives it, the very action offered to secure their keys would put the
        // withdrawn one back into the Keychain and into the next request — and so would the next
        // launch. The user's own edit is the newer statement of what this key is.
        let defaults = makeOwnedDefaults([
            SettingsKeys.legacyOpenAIAPIKey: "test-stale-legacy-key"
        ])
        let secretStore = ScriptedSecretStore()
        secretStore.seed("test-newer-keychain-key", for: .openAI)
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: defaults)
        XCTAssertEqual(secretState.pendingMigrationProviders, [.openAI])

        secretState.saveSecret("", for: .openAI)

        XCTAssertNil(defaults.object(forKey: SettingsKeys.legacyOpenAIAPIKey))
        XCTAssertEqual(secretState.pendingMigrationProviders, [])

        secretState.retryLegacyKeyMigration()

        XCTAssertNil(secretStore.storedSecret(for: .openAI))
        XCTAssertEqual(secretState.secret(for: .openAI), "")
    }

    func testAStoredEditReplacesItsOwnFailureWithTheNextUnresolvedOne() {
        // WHY: Storing one key proves nothing about another the app still cannot read. Treating an
        // edit as a general all-clear would leave that provider's field blank with no explanation,
        // which is the same silence the migration retry is careful to avoid.
        let secretStore = ScriptedSecretStore()
        secretStore.failingProviders = [.openAI, .gemini]
        let defaults = makeOwnedDefaults()
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: defaults)
        XCTAssertEqual(
            secretState.errorMessage,
            "Couldn't read the saved OpenAI API key. Check Keychain access and try again."
        )

        secretStore.failingProviders = [.gemini]
        secretState.saveSecret("test-typed-openai-key", for: .openAI)

        XCTAssertEqual(secretState.secret(for: .openAI), "test-typed-openai-key")
        XCTAssertEqual(
            secretState.errorMessage,
            "Couldn't read the saved Gemini API key. Check Keychain access and try again."
        )
    }

    func testAStoredEditWithdrawsTheSaveFailureItJustCorrected() {
        // WHY: The guidance has to follow the user's last attempt. Leaving the refused edit's
        // warning up after the store accepted the next one would report a failure that no longer
        // exists, and the user has no other way to tell whether their key is persisted.
        let secretStore = ScriptedSecretStore()
        let defaults = makeOwnedDefaults()
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: defaults)
        secretStore.failingProviders = [.custom]
        secretState.saveSecret("test-refused-custom-key", for: .custom)
        XCTAssertEqual(
            secretState.errorMessage,
            "Couldn't save the Custom API key. Check Keychain access and try again."
        )

        secretStore.failingProviders = []
        secretState.saveSecret("test-accepted-custom-key", for: .custom)

        XCTAssertEqual(secretStore.storedSecret(for: .custom), "test-accepted-custom-key")
        XCTAssertNil(secretState.errorMessage)
    }

    func testAnEarlierProvidersRefusedEditSurvivesALaterOnesFailureAndRecovery() {
        // WHY: The form shows one failure at a time, so a second refusal is the only thing on
        // screen. If that displaced the first as state too, correcting the second would report
        // everything as fine while the first provider's key was still never persisted — and the
        // user's only evidence of it is this line.
        let secretStore = ScriptedSecretStore()
        let defaults = makeOwnedDefaults()
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: defaults)
        secretStore.failingProviders = [.custom, .openAI]
        secretState.saveSecret("test-refused-custom-key", for: .custom)
        secretState.saveSecret("test-refused-openai-key", for: .openAI)
        XCTAssertEqual(
            secretState.errorMessage,
            "Couldn't save the OpenAI API key. Check Keychain access and try again."
        )

        secretStore.failingProviders = [.custom]
        secretState.saveSecret("test-accepted-openai-key", for: .openAI)

        XCTAssertEqual(secretStore.storedSecret(for: .openAI), "test-accepted-openai-key")
        XCTAssertNil(secretStore.storedSecret(for: .custom))
        XCTAssertEqual(
            secretState.errorMessage,
            "Couldn't save the Custom API key. Check Keychain access and try again."
        )
    }

    func testARefusedEditOutranksThatProvidersEarlierReadFailure() {
        // WHY: When one provider is both unreadable and unsaved, the refused edit is the newer
        // fact and the one the user can act on: they just tried to replace that key. Reporting the
        // older read failure instead would send them looking for a problem they were fixing.
        let secretStore = ScriptedSecretStore()
        secretStore.failingProviders = [.gemini]
        let defaults = makeOwnedDefaults()
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: defaults)
        secretState.saveSecret("test-refused-gemini-key", for: .gemini)
        secretStore.failingProviders = [.gemini, .openAI]
        secretState.saveSecret("test-refused-openai-key", for: .openAI)
        secretStore.failingProviders = [.gemini]

        secretState.saveSecret("test-accepted-openai-key", for: .openAI)

        XCTAssertEqual(
            secretState.errorMessage,
            "Couldn't save the Gemini API key. Check Keychain access and try again."
        )
    }

    func testAStoredEditKeepsAnotherProvidersUnfixedSaveFailureVisible() {
        // WHY: A key the store refused is still not persisted, whatever the user types next. Only
        // the provider whose write just succeeded may retire its own warning.
        let secretStore = ScriptedSecretStore()
        let defaults = makeOwnedDefaults()
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: defaults)
        secretStore.failingProviders = [.custom]
        secretState.saveSecret("test-refused-custom-key", for: .custom)
        let customSaveFailure = "Couldn't save the Custom API key. Check Keychain access and try again."
        XCTAssertEqual(secretState.errorMessage, customSaveFailure)

        secretStore.failingProviders = []
        secretState.saveSecret("test-typed-openai-key", for: .openAI)

        XCTAssertEqual(secretStore.storedSecret(for: .openAI), "test-typed-openai-key")
        XCTAssertNil(secretStore.storedSecret(for: .custom))
        XCTAssertEqual(secretState.errorMessage, customSaveFailure)
    }

    func testARefusedKeyEditKeepsThePlaintextCopyRecoverable() {
        // WHY: Retiring the plaintext is only safe once the store has accepted the user's own
        // value. Dropping it after a refused edit would destroy the one copy of a key the Keychain
        // never took, which is precisely the loss the migration contract exists to prevent.
        let defaults = makeOwnedDefaults([
            SettingsKeys.legacyOpenAIAPIKey: "test-stale-legacy-key"
        ])
        let secretStore = ScriptedSecretStore()
        let secretState = SettingsSecretState(secretStore: secretStore, defaults: defaults)
        secretStore.failingProviders = [.openAI]

        secretState.saveSecret("test-typed-openai-key", for: .openAI)

        XCTAssertEqual(
            defaults.string(forKey: SettingsKeys.legacyOpenAIAPIKey),
            "test-stale-legacy-key"
        )
        XCTAssertEqual(secretState.pendingMigrationProviders, [.openAI])
        XCTAssertNil(secretStore.storedSecret(for: .openAI))
    }
}
