import SwiftUI
import AppKit

/// Identifies XCTest's hosted app process without importing XCTest into the production target.
enum HostedTestProcess {
    static var isActive: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
    }
}

/// The dependencies that must be created before the app scene owns its manager instances.
///
/// The hosted XCTest app is initialized before individual test setup. It therefore receives a
/// fresh defaults suite and in-memory secrets so no startup initializer can access, migrate, or
/// delete a developer's configuration before the test's own isolation lifecycle starts.
struct AppStartupDependencies {
    let defaults: UserDefaults
    let secretStore: SecretStoring
    let audioPlayer: AudioPlayerManager
    let textExtraction: TextExtractionManager
    let networkManager: TTSNetworkManager
    let speechSession: SpeechSessionCoordinator
    let servicesCoordinator: ServicesCoordinator

    /// Builds production dependencies or an entirely test-owned hosted-test dependency graph.
    static func make(
        isHostedTest: Bool = HostedTestProcess.isActive,
        // This is the composition root, and these two lines are the only place in the app that
        // names a defaults domain rather than being handed one. Everything downstream requires an
        // explicit store, which is what keeps the installed app's own preferences out of reach of
        // a test and out of reach of any later `Sources` code that would otherwise write there.
        // swiftlint:disable:next process_default_settings_store
        productionDefaults: () -> UserDefaults = { .standard },
        productionSecretStore: () -> SecretStoring = { KeychainSecretStore() },
        // swiftlint:disable:next process_default_settings_store
        testDefaults: () -> UserDefaults = { UserDefaults(suiteName: "com.clipboardtts.hosted-tests.\(UUID().uuidString)")! },
        testSecretStore: () -> SecretStoring = { InMemorySecretStore() }
    ) -> AppStartupDependencies {
        let defaults: UserDefaults
        let secretStore: SecretStoring
        if isHostedTest {
            defaults = testDefaults()
            secretStore = testSecretStore()
        } else {
            defaults = productionDefaults()
            secretStore = productionSecretStore()
        }

        let persistedProvider = APIKeyProvider(
            selectedProvider: defaults.string(forKey: SettingsKeys.ttsProvider) ?? "OpenAI"
        )
        let persistedCustomSampleRate: Double
        if let storedSampleRate = defaults.object(forKey: SettingsKeys.customSampleRate) {
            persistedCustomSampleRate = storedSampleRate as? Double ?? .nan
        } else {
            persistedCustomSampleRate = AudioPlayerManager.defaultSampleRate
        }
        let initialSampleRate = persistedProvider == .custom
            ? persistedCustomSampleRate
            : AudioPlayerManager.defaultSampleRate
        let audioPlayer = AudioPlayerManager(sampleRate: initialSampleRate)
        let networkManager = TTSNetworkManager(secretStore: secretStore, defaults: defaults)
        // Built here so every entry point speaks through one session owner holding one manager
        // pair, rather than each surface pairing whichever instances it happens to be handed.
        let speechSession = SpeechSessionCoordinator(audioPlayer: audioPlayer, networkManager: networkManager)

        return AppStartupDependencies(
            defaults: defaults,
            secretStore: secretStore,
            audioPlayer: audioPlayer,
            textExtraction: TextExtractionManager(),
            networkManager: networkManager,
            speechSession: speechSession,
            servicesCoordinator: ServicesCoordinator(speechSession: speechSession)
        )
    }
}

@main
struct ClipboardTTSApp: App {
    @StateObject private var audioPlayer: AudioPlayerManager
    @StateObject private var textExtraction: TextExtractionManager
    @StateObject private var networkManager: TTSNetworkManager

    // Owns what is speaking for the app's lifetime. A @StateObject for the same reason as the
    // managers below: first-wins lifecycle keeps this pointing at the very manager pair the scene
    // renders, which a plain stored property could not promise if the App value were rebuilt.
    @StateObject private var speechSession: SpeechSessionCoordinator

    // Owns the Services-notification subscription for the app's lifetime, so the Services flow
    // works before the menu bar dropdown (and thus MenuBarView) is ever built. Held as a
    // @StateObject (like the managers) so all four share first-wins lifecycle semantics and can
    // never end up pointing at different manager instances.
    @StateObject private var servicesCoordinator: ServicesCoordinator

    // Owns the menu's pending deferred clipboard read for the app's lifetime. A @StateObject for
    // the same reason as the managers: SwiftUI rebuilds the MenuBarExtra content on every publish,
    // and a per-view instance could not drop an attempt an earlier view value scheduled.
    @StateObject private var deferredClipboardAction = DeferredClipboardAction()
    /// Reactivates the app and shows a menu refusal the user must acknowledge before speech starts.
    private let menuAlertPresenter = AppKitMenuAlertPresenter()
    private let secretStore: SecretStoring
    /// The same preferences the startup manager migrated legacy keys from, so the Settings retry
    /// works on that domain rather than whichever one `.standard` names in this process.
    private let defaults: UserDefaults

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        let dependencies = AppStartupDependencies.make()
        self.secretStore = dependencies.secretStore
        self.defaults = dependencies.defaults
        _audioPlayer = StateObject(wrappedValue: dependencies.audioPlayer)
        _textExtraction = StateObject(wrappedValue: dependencies.textExtraction)
        _networkManager = StateObject(wrappedValue: dependencies.networkManager)
        _speechSession = StateObject(wrappedValue: dependencies.speechSession)
        _servicesCoordinator = StateObject(wrappedValue: dependencies.servicesCoordinator)
    }

    var body: some Scene {
        MenuBarExtra("Clipboard TTS", systemImage: "waveform.circle") {
            MenuBarView(
                audioPlayer: audioPlayer,
                textExtraction: textExtraction,
                networkManager: networkManager,
                deferredClipboardAction: deferredClipboardAction,
                speechSession: speechSession,
                alertPresenter: menuAlertPresenter
            )
        }
        .menuBarExtraStyle(.window)

        // Opens at the size the content's former fixed frame enforced; the content now fills
        // whatever size the window takes.
        Window("Settings", id: "settings") {
            SettingsView(
                networkManager: networkManager,
                audioPlayer: audioPlayer,
                speechSession: speechSession,
                secretStore: secretStore,
                defaults: defaults
            )
        }
        .defaultSize(width: 600, height: 350)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = ServicesProvider()
    }
}

class ServicesProvider: NSObject {
    @objc func handleServices(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        if let text = pasteboard.string(forType: .string) {
            NotificationCenter.default.post(name: ServicesCoordinator.speakSelectedTextNotification, object: text)
        }
    }
}
