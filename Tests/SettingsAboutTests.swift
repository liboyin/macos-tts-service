import XCTest
import AppKit
@testable import ClipboardTTSApp

/// Covers the About panel's metadata and the Settings control that presents it.
///
/// Hosted Settings drives `NSHostingView` and the AppKit controls it builds, so every test here
/// runs on the main actor.
@MainActor
final class SettingsAboutTests: MockURLProtocolTestCase {

    func testDefaultBundleAboutMetadataReadsHostedApplicationInfoDictionary() throws {
        // WHY: The shipped About action must use the generated app bundle rather than a test-only
        // metadata source, so changing Info.plist metadata is reflected without source edits.
        let expectedName = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        let expectedVersion = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let metadata = BundleAboutMetadata()

        XCTAssertEqual(metadata.applicationName, expectedName)
        XCTAssertEqual(metadata.applicationVersion, expectedVersion)
    }

    func testBundleAboutMetadataReadsNameAndMarketingVersionFromInfoDictionary() {
        // WHY: The standard About panel must receive release metadata from the app bundle, so a
        // source-level version string cannot silently diverge from the packaged Info.plist.
        let metadata = BundleAboutMetadata(bundle: BundleInfoStub(values: [
            "CFBundleName": "Metadata Clipboard TTS",
            "CFBundleShortVersionString": "9.4"
        ]))

        XCTAssertEqual(metadata.applicationName, "Metadata Clipboard TTS")
        XCTAssertEqual(metadata.applicationVersion, "9.4")
    }

    func testSettingsFormExposesAboutButtonThatRoutesToPresenter() {
        // WHY: An injected action alone does not prove users can reach About; the rendered form
        // must keep the conventional control and route its click without opening AppKit UI in tests.
        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let defaults = makeOwnedDefaults()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        // Opening Settings on OpenAI fetches its model and voice suggestions.
        MockURLProtocol.installRequestHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{\"data\": []}".utf8))
        }
        let presenter = CapturingAboutPanelPresenter()
        let settings = HostedSettings(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            secretStore: secretStore,
            defaults: defaults,
            aboutAction: AboutAction(
                metadata: StaticAboutMetadata(applicationName: "Test Clipboard TTS", applicationVersion: "7.3"),
                presenter: presenter
            ),
            testCase: self
        )

        settings.click("About Clipboard TTS")

        XCTAssertEqual(presenter.presentedApplicationName, "Test Clipboard TTS")
        XCTAssertEqual(presenter.presentedApplicationVersion, "7.3")
        settings.release()
    }

    func testAboutActionPassesInjectedBundleMetadataWithoutPresentingSystemUI() {
        // WHY: The About command must route the bundle's marketing version to macOS's panel, not
        // a second hard-coded string, while tests must never present an interactive AppKit panel.
        // `showAbout` reads no lifecycle-managed state, so it needs no SwiftUI host.
        let secretStore = InMemorySecretStore()
        let audioPlayer = AudioPlayerManager()
        let defaults = makeOwnedDefaults()
        let networkManager = TestNetworkFactory.makeManager(secretStore: secretStore, defaults: defaults)
        let presenter = CapturingAboutPanelPresenter()
        let view = SettingsView(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            speechSession: SpeechSessionCoordinator(audioPlayer: audioPlayer, networkManager: networkManager),
            secretStore: secretStore,
            defaults: defaults,
            aboutAction: AboutAction(
                metadata: StaticAboutMetadata(applicationName: "Test Clipboard TTS", applicationVersion: "7.3"),
                presenter: presenter
            )
        )

        view.showAbout()

        XCTAssertEqual(presenter.presentedApplicationName, "Test Clipboard TTS")
        XCTAssertEqual(presenter.presentedApplicationVersion, "7.3")
    }

    func testStandardAboutPanelOptionsLinkToBundledLicense() throws {
        // WHY: “LICENSE” in About credits must open the exact resource users receive, rather than
        // leaving them with an unresolvable filename inside the app bundle.
        let expectedLicenseURL = try XCTUnwrap(Bundle.main.url(forResource: "LICENSE", withExtension: nil))
        let options = StandardAboutPanelPresenter().aboutPanelOptions(
            applicationName: "Test Clipboard TTS",
            applicationVersion: "7.3"
        )
        let credits = try XCTUnwrap(options[.credits] as? NSAttributedString)
        let licenseRange = (credits.string as NSString).range(of: "LICENSE")

        XCTAssertEqual(credits.attribute(.link, at: licenseRange.location, effectiveRange: nil) as? URL, expectedLicenseURL)
    }
}

private struct StaticAboutMetadata: AboutMetadataProviding {
    let applicationName: String
    let applicationVersion: String
}

private struct BundleInfoStub: BundleInfoReading {
    let values: [String: Any]

    func object(forInfoDictionaryKey key: String) -> Any? {
        values[key]
    }
}

private final class CapturingAboutPanelPresenter: AboutPanelPresenting {
    private(set) var presentedApplicationName: String?
    private(set) var presentedApplicationVersion: String?

    func showAbout(applicationName: String, applicationVersion: String) {
        presentedApplicationName = applicationName
        presentedApplicationVersion = applicationVersion
    }
}
