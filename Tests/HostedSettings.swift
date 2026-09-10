import XCTest
import SwiftUI
import AppKit
@testable import ClipboardTTSApp

/// Hosts `SettingsView` through a real SwiftUI lifecycle and drives the controls it renders.
///
/// Constructing `SettingsView` as a value leaves its lifecycle storage uninstalled. SwiftUI then
/// builds a fresh `SettingsSecretState` on every `@StateObject` access and discards `@State` writes,
/// so an unhosted test exercises different state identity from the production window and can pass
/// for a reason production never reproduces. Hosting installs that storage once, which is also the
/// only way a test can observe one retained secret state across several edits and actions.
///
/// Every member must be used from the main thread: `NSHostingView`, the AppKit controls it builds,
/// and the main-queue turns that order SwiftUI's updates all require it.
@MainActor
final class HostedSettings {
    /// A plain (non-secure) text field, addressed by its position among the fields its form renders.
    enum PlainTextField {
        case providerModel
        case providerVoice
        case customModel
        case customSampleRate

        /// The field's index among its form's plain text fields, in rendering order. OpenAI and
        /// Gemini render Model then Voice; Custom renders Base URL, Model, Voice, PCM Sample Rate.
        /// Each form's API key is excluded because it is secure.
        var position: Int {
            switch self {
            case .providerModel:
                return 0
            case .providerVoice:
                return 1
            case .customModel:
                return 1
            case .customSampleRate:
                return 3
            }
        }
    }

    /// A suggestion control the form renders: the choices it offers and the one it shows selected.
    struct SuggestionControl: Equatable {
        let choices: [String]
        /// The choice the control displays, which is absent when it shows none.
        let selection: String?
    }

    private var host: NSHostingView<SettingsView>?
    /// The store the mounted form is bound to, so `selectProvider` drives the same domain it reads.
    private let defaults: UserDefaults

    /// Mounts the form. `defaults` has no default value for the same reason `SettingsView`'s does
    /// not: the form displays, writes, and migrates whichever domain it is handed, so a test states
    /// the storage it owns and normally passes the very store it gave `TestNetworkFactory`, letting
    /// the form retry the migration that manager attempted. Pass a second store to separate them
    /// deliberately.
    init(networkManager: TTSNetworkManager,
         audioPlayer: AudioPlayerManager,
         secretStore: SecretStoring,
         defaults: UserDefaults,
         aboutAction: AboutAction = AboutAction(),
         testCase: XCTestCase,
         file: StaticString = #filePath,
         line: UInt = #line) {
        self.defaults = defaults
        let view = SettingsView(
            networkManager: networkManager,
            audioPlayer: audioPlayer,
            // The session owner production wires: one instance over this form's own manager pair.
            speechSession: SpeechSessionCoordinator(audioPlayer: audioPlayer, networkManager: networkManager),
            secretStore: secretStore,
            defaults: defaults,
            aboutAction: aboutAction
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 350)
        self.host = host
        // A test that exits before releasing the host — including by throwing — must still not
        // leave its settings observers alive. This block retains the helper deliberately: under a
        // weak capture the test's own reference is the only strong one, so an early exit
        // deinitializes the helper first and the fallback then finds nothing to release, skipping
        // the main-queue drain. XCTest runs teardown blocks before `tearDown()`, so this still
        // lands before the mock scope invalidates its session.
        testCase.addTeardownBlock {
            self.release(file: file, line: line)
        }
        settle(file: file, line: line)
    }

    /// Presses the Settings control carrying this title.
    func click(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let button = host?.descendantButton(titled: title) else {
            XCTFail("Settings must render a \(title) button.", file: file, line: line)
            return
        }
        button.performClick(nil)
        settle(file: file, line: line)
    }

    /// Returns whether Settings currently offers a control carrying this title.
    ///
    /// `click` fails a missing control, which cannot express the case a conditional action needs:
    /// that the form deliberately renders nothing to press.
    func rendersButton(titled title: String) -> Bool {
        host?.descendantButton(titled: title) != nil
    }

    /// Types `newText` into a form field after proving the position still addresses it.
    ///
    /// Neither a placeholder nor an accessibility identifier survives into the AppKit layer of a
    /// windowless host, so position is the only address available. `expecting` is what makes that
    /// safe: a reordered form fails this anchor instead of silently editing a different field.
    func type(_ newText: String,
              into field: PlainTextField,
              expecting currentText: String,
              file: StaticString = #filePath,
              line: UInt = #line) {
        let plainFields = editableTextFields().filter { !($0 is NSSecureTextField) }
        guard field.position < plainFields.count else {
            XCTFail(
                "The current form renders \(plainFields.count) plain text fields, so position \(field.position) is absent.",
                file: file,
                line: line
            )
            return
        }
        let control = plainFields[field.position]
        guard control.stringValue == currentText else {
            XCTFail(
                """
                Plain text field \(field.position) holds "\(control.stringValue)" rather than the \
                expected "\(currentText)", so the form order no longer matches this address.
                """,
                file: file,
                line: line
            )
            return
        }
        edit(control, to: newText, file: file, line: line)
    }

    /// Types a new API key into the form's key field, which is the only secure field it renders.
    func typeAPIKey(_ newText: String, file: StaticString = #filePath, line: UInt = #line) {
        let secureFields = editableTextFields().compactMap { $0 as? NSSecureTextField }
        guard secureFields.count == 1, let control = secureFields.first else {
            XCTFail(
                "Settings must render exactly one API-key field; the host renders \(secureFields.count).",
                file: file,
                line: line
            )
            return
        }
        edit(control, to: newText, file: file, line: line)
    }

    /// Returns every suggestion control the form currently renders, in rendering order.
    func suggestionControls() -> [SuggestionControl] {
        var controls: [SuggestionControl] = []
        host?.collectSuggestionControls(into: &controls)
        return controls
    }

    /// Returns the choices offered by each suggestion control the form currently renders.
    func suggestionLists() -> [[String]] {
        suggestionControls().map(\.choices)
    }

    /// Switches provider the way the sidebar does, by writing the setting its selection is bound to.
    ///
    /// The sidebar `List` is bound to the form's provider `@AppStorage`, so writing that key in the
    /// store the form was mounted with drives the installed view through the same binding and
    /// `onChange` production uses. The row itself is drawn by SwiftUI and backs no AppKit control a
    /// test could select.
    func selectProvider(_ provider: String, file: StaticString = #filePath, line: UInt = #line) {
        defaults.set(provider, forKey: SettingsKeys.ttsProvider)
        settle(file: file, line: line)
    }

    /// Releases the hosted view graph and drains the main queue.
    ///
    /// The hosted view owns settings observers, so releasing it before `MockURLProtocol` invalidates
    /// the test's session is what stops a deferred observer from starting a metadata request after
    /// its scope closed. Calling this more than once is safe.
    func release(file: StaticString = #filePath, line: UInt = #line) {
        guard host != nil else { return }
        host = nil
        drainMainQueue(file: file, line: line)
    }

    /// Replaces a field's text the way typing does, so SwiftUI's binding runs its setter.
    ///
    /// SwiftUI's macOS text fields observe their `NSTextField` through a coordinator implementing
    /// `controlTextDidChange(_:)`. Assigning `stringValue` alone changes only what AppKit displays,
    /// so the notification below is what carries the edit into the installed lifecycle storage.
    private func edit(_ control: NSTextField, to newText: String, file: StaticString, line: UInt) {
        guard let coordinator = control.delegate else {
            XCTFail(
                "The hosted text field has no SwiftUI coordinator, so an edit cannot reach its binding.",
                file: file,
                line: line
            )
            return
        }
        control.stringValue = newText
        coordinator.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: control))
        settle(file: file, line: line)
    }

    private func editableTextFields() -> [NSTextField] {
        var fields: [NSTextField] = []
        host?.collectEditableTextFields(into: &fields)
        return fields
    }

    private func settle(file: StaticString, line: UInt) {
        settleHostedView(host, file: file, line: line)
    }

    private func drainMainQueue(file: StaticString, line: UInt) {
        drainHostedMainQueue(file: file, line: line)
    }
}

/// Hosts the shared model and voice fields alone, in a configuration Settings itself only passes
/// through inside one SwiftUI update.
///
/// A provider switch renders the new provider's fields once before `onChange` resynchronizes the
/// manager, and SwiftUI commits no AppKit state for that render: by the time a hosted form can be
/// inspected, the manager has already been resynchronized and its stale lists cleared. Rendering
/// these fields directly is therefore the only way a test can hold that configuration still.
@MainActor
final class HostedModelVoiceFields {
    private var host: NSHostingView<ModelVoiceConfigurationView>?

    /// Mounts the fields for `provider` with fixed values, because this host exists to render one
    /// configuration rather than to drive edits; `HostedSettings` owns editing and synchronization.
    init(networkManager: TTSNetworkManager,
         provider: String,
         model: String,
         voice: String,
         testCase: XCTestCase,
         file: StaticString = #filePath,
         line: UInt = #line) {
        let view = ModelVoiceConfigurationView(
            ttsModel: .constant(model),
            ttsVoice: .constant(voice),
            networkManager: networkManager,
            provider: provider,
            onSync: {}
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
        self.host = host
        testCase.addTeardownBlock {
            self.release(file: file, line: line)
        }
        settleHostedView(host, file: file, line: line)
    }

    /// Returns every suggestion control these fields currently render, in rendering order.
    func suggestionControls() -> [HostedSettings.SuggestionControl] {
        var controls: [HostedSettings.SuggestionControl] = []
        host?.collectSuggestionControls(into: &controls)
        return controls
    }

    /// Releases the hosted view graph and drains the main queue. Calling it twice is safe.
    func release(file: StaticString = #filePath, line: UInt = #line) {
        guard host != nil else { return }
        host = nil
        drainHostedMainQueue(file: file, line: line)
    }
}

/// Runs the main-queue turns SwiftUI needs to apply a change and rebuild its AppKit controls.
///
/// One turn delivers the observation a change produced; the next runs the work its updated body
/// scheduled. Laying out around them forces the controls a later lookup addresses to exist now
/// rather than at some arbitrary later moment, which is what replaces a timing delay here.
@MainActor
private func settleHostedView(_ host: NSView?, file: StaticString, line: UInt) {
    for _ in 0..<2 {
        host?.layoutSubtreeIfNeeded()
        drainHostedMainQueue(file: file, line: line)
    }
    host?.layoutSubtreeIfNeeded()
}

@MainActor
private func drainHostedMainQueue(file: StaticString, line: UInt) {
    let drained = XCTestExpectation(description: "Hosted view completed a main-queue turn")
    DispatchQueue.main.async { drained.fulfill() }
    guard XCTWaiter().wait(for: [drained], timeout: 2.0) == .completed else {
        XCTFail("The hosted view did not complete a main-queue turn within 2 seconds.", file: file, line: line)
        return
    }
}

@MainActor
private extension NSView {
    func descendantButton(titled title: String) -> NSButton? {
        if let button = self as? NSButton, button.title == title {
            return button
        }
        return subviews.lazy.compactMap { $0.descendantButton(titled: title) }.first
    }

    /// Collects every editable field in rendering order, so a caller can address one by position.
    func collectEditableTextFields(into fields: inout [NSTextField]) {
        if let field = self as? NSTextField, field.isEditable {
            fields.append(field)
        }
        subviews.forEach { $0.collectEditableTextFields(into: &fields) }
    }

    /// Collects every descendant pop-up button, which is how the form renders its model and voice
    /// suggestions, as the choices it offers and the choice it currently displays.
    func collectSuggestionControls(into controls: inout [HostedSettings.SuggestionControl]) {
        if let popUpButton = self as? NSPopUpButton {
            controls.append(
                HostedSettings.SuggestionControl(
                    choices: popUpButton.itemTitles,
                    selection: popUpButton.titleOfSelectedItem
                )
            )
        }
        subviews.forEach { $0.collectSuggestionControls(into: &controls) }
    }
}
