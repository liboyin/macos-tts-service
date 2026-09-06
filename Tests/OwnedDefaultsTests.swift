import XCTest
@testable import ClipboardTTSApp

final class MockURLProtocolSettingsIsolationTests: MockURLProtocolTestCase {
    func testFactoryManagerReadsAndMigratesOnlyTheStoreItWasGiven() {
        // WHY: the unit-test bundle is hosted inside the app, so a manager that resolved settings
        // through `.standard` would start up on the developer's own configuration and its legacy
        // migration would delete their plaintext key. The seeded values are conspicuous precisely
        // so they cannot come from a real installation: reading them back through the production
        // request seam is what names the domain the manager actually used.
        let secretStore = InMemorySecretStore()
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.apiBaseURL: "https://owned.example/v1/audio/speech",
            SettingsKeys.customModel: "owned-model",
            SettingsKeys.customVoice: "owned-voice",
            SettingsKeys.legacyCustomAPIKey: "owned-legacy-credential"
        ])

        let manager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)

        let settings = manager.requestSettingsSnapshot()
        XCTAssertEqual(settings.baseURL, "https://owned.example/v1/audio/speech")
        XCTAssertEqual(settings.model, "owned-model")
        XCTAssertEqual(settings.voice, "owned-voice")
        XCTAssertEqual(settings.apiKey, "owned-legacy-credential")
        XCTAssertEqual(settings.provider, .custom)
        XCTAssertNil(
            defaults.object(forKey: SettingsKeys.legacyCustomAPIKey),
            "Startup migration must consume the legacy key from the store the manager was given."
        )
        assertAfterMockQuiescence {
            XCTAssertNil(
                defaults.object(forKey: SettingsKeys.legacyCustomAPIKey),
                "No late startup work may restore a legacy key the migration already secured."
            )
        }
    }

    func testOwnedSettingsStorageIsPrivateToItsOwnerAndIsNotTheAppDomain() {
        // WHY: every regression in this bundle now states its settings through owned storage, so
        // that storage carries the isolation the old snapshot-and-restore lifecycle used to. Two
        // properties make it sound: one owner's values reach no other owner, and no owner is ever
        // handed the app's own domain.
        //
        // Comparing identity is not a preference access — it names the object without asking it
        // for a stored value — and it is the only way to state the second property without
        // reading the developer's settings to prove they were left alone.
        let first = makeOwnedDefaults([SettingsKeys.customModel: "first-only"])
        let second = makeOwnedDefaults()

        // Naming the domain is not accessing it: identity asks the object for no stored value.
        // swiftlint:disable:next process_default_settings_store
        XCTAssertFalse(first === UserDefaults.standard, "Owned storage must never be the app's own defaults domain.")
        XCTAssertFalse(first === second, "Each owner must receive storage of its own.")
        XCTAssertEqual(first.string(forKey: SettingsKeys.customModel), "first-only")
        XCTAssertNil(second.object(forKey: SettingsKeys.customModel), "One owner's settings must not reach another's.")
        // The aggregate view has to answer for this owner too. Inherited, it reports the process's
        // whole search list — the app's own domain and NSGlobalDomain included — which is both a
        // read of the developer's settings and the wrong answer about owned storage.
        XCTAssertEqual(
            first.dictionaryRepresentation() as? [String: String],
            [SettingsKeys.customModel: "first-only"],
            "Owned storage must report only what its owner put there."
        )
        XCTAssertTrue(second.dictionaryRepresentation().isEmpty, "Unseeded owned storage must report nothing at all.")
    }

    func testOwnedStorageAnswersForItselfWhenAskedToNameADomain() {
        // WHY: the named-domain members are the widest inherited door out of owned storage — the
        // name they take could be the installed app's own, and answering from it is both a read of
        // the developer's settings and the wrong answer about this store. The global domain is the
        // discriminator because it is always populated: inherited, this call returns its contents;
        // owned, it returns nothing and reads nothing.
        let owned = makeOwnedDefaults()

        // swiftlint:disable:next process_default_settings_store
        let globalDomain = owned.persistentDomain(forName: UserDefaults.globalDomain)

        XCTAssertNil(globalDomain, "Owned storage must report no persistent domain, whichever domain it is asked to name.")
    }

    func testOwnedStorageRefusesToShareRegisteredOrVolatileValues() {
        // WHY: registration and the volatile domains are the two pieces of defaults state
        // Foundation shares across the whole process, so they are how one test's values would
        // reach the next one's — or reach production code reading the standard domain.
        //
        // The observer has to be an ordinary store, not a second owned one: owned storage answers
        // these members from itself, so it would hide the very leak this test looks for. Reading
        // shared state is the only way to show it stayed clean, and this reads no persisted
        // setting — the registration and volatile domains live in memory for the process.
        let first = makeOwnedDefaults()
        // swiftlint:disable:next process_default_settings_store
        let processState = UserDefaults(suiteName: "com.clipboardtts.owned-defaults.observer")!

        // swiftlint:disable:next process_default_settings_store
        first.register(defaults: [SettingsKeys.geminiVoice: "registered-by-first"])
        // swiftlint:disable:next process_default_settings_store
        first.setVolatileDomain([SettingsKeys.customVoice: "volatile-in-first"], forName: "com.clipboardtts.probe")

        // swiftlint:disable:next process_default_settings_store
        let registered = processState.volatileDomain(forName: UserDefaults.registrationDomain)
        // swiftlint:disable:next process_default_settings_store
        let volatileNames = processState.volatileDomainNames

        XCTAssertNil(registered[SettingsKeys.geminiVoice], "A registration must not reach shared process state.")
        XCTAssertFalse(
            volatileNames.contains("com.clipboardtts.probe"),
            "A volatile domain must not reach shared process state."
        )
    }
}
