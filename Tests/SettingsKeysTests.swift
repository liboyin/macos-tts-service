import XCTest
@testable import ClipboardTTSApp

final class SettingsKeysTests: XCTestCase {
    func testAllUserDefaultsKeysContainsEachDeclaredKeyExactlyOnce() {
        // WHY: the credential-leak regressions sweep `allUserDefaultsKeys` to prove a key or token
        // reached no persisted setting. Omitting a newly added key would silently narrow that
        // sweep to the settings someone remembered, which is exactly the kind of gap the sweep
        // exists to close; a duplicate would hide a missing one behind an unchanged count.
        let declaredKeys = [
            SettingsKeys.ttsProvider,
            SettingsKeys.apiBaseURL,
            SettingsKeys.openAIModel,
            SettingsKeys.openAIVoice,
            SettingsKeys.geminiModel,
            SettingsKeys.geminiVoice,
            SettingsKeys.customModel,
            SettingsKeys.customVoice,
            SettingsKeys.customSampleRate,
            SettingsKeys.legacyOpenAIAPIKey,
            SettingsKeys.legacyGeminiAPIKey,
            SettingsKeys.legacyCustomAPIKey
        ]

        XCTAssertEqual(Set(SettingsKeys.allUserDefaultsKeys), Set(declaredKeys))
        XCTAssertEqual(SettingsKeys.allUserDefaultsKeys.count, declaredKeys.count)
        XCTAssertEqual(Set(SettingsKeys.allUserDefaultsKeys).count, SettingsKeys.allUserDefaultsKeys.count)
    }
}
