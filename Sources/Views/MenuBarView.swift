import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @ObservedObject var textExtraction: TextExtractionManager
    @ObservedObject var networkManager: TTSNetworkManager
    /// The app-lifetime owner of the deferred clipboard read; see `speakCopiedText()`.
    let deferredClipboardAction: DeferredClipboardAction
    /// The shared owner of what is speaking; the menu contributes only its own click policy.
    let speechSession: SpeechSessionCoordinator
    /// Owns reactivating the app and showing what a refused click must tell the user.
    ///
    /// Deliberately has no default, like `SettingsView`'s injected `UserDefaults`: a call site that
    /// forgot it would show a real modal panel from a test.
    let alertPresenter: MenuAlertPresenting

    @Environment(\.openWindow) var openWindow

    var errorMessage: String? {
        networkManager.lastError ?? audioPlayer.sampleRateError
    }

    var requestErrorView: RequestErrorView? {
        errorMessage.map(RequestErrorView.init)
    }

    /// Whether an idle, playable pipeline is available to start speech from the clipboard.
    ///
    /// Spelled out rather than derived from a shared "menu is idle" helper: what may be spoken is
    /// this view's only remaining gate, and it must not change as a side effect of some other
    /// control acquiring one.
    var isReadyForNewSpeech: Bool {
        !networkManager.isStreaming && !audioPlayer.hasAudio && audioPlayer.isReadyForNewStream
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Clipboard TTS")
                    .font(.headline)
                Spacer()
                Button(action: {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Image(systemName: "power")
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal)
            .padding(.top)

            Divider()

            HStack {
                Button(action: {
                    speakCopiedText()
                }) {
                    Text((networkManager.isStreaming || audioPlayer.hasAudio) ? "Clear Buffer" : "Speak Copied Text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            if let requestErrorView {
                requestErrorView
                    .padding(.horizontal)
            }

            HStack {
                Button(action: {
                    togglePlayPause()
                }) {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!audioPlayer.hasAudio)

                Slider(value: Binding(
                    get: { audioPlayer.playbackProgress },
                    set: { audioPlayer.seek(to: $0) }
                ), in: 0...max(0.01, audioPlayer.bufferDuration))
                .disabled(!audioPlayer.hasAudio)
            }
            .padding(.horizontal)

            HStack {
                Text("Speed:")
                Slider(value: $audioPlayer.playbackRate, in: 0.5...2.5, step: 0.1)
                Text(String(format: "%.1fx", audioPlayer.playbackRate))
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(width: 300)
    }

    func speakCopiedText() {
        if networkManager.isStreaming || audioPlayer.hasAudio {
            speechSession.cancel()
        } else {
            guard isReadyForNewSpeech else { return }
            NSApp.deactivate()
            // The 0.2-second delay lets the menu close before the pasteboard is read, so the
            // readiness observed above can be stale by the time it does: a Services request, a
            // Test Voice request, a Clear Buffer click, or a second Speak click can own the
            // pipeline by then. Starting speech now would replace that work without the Clear
            // Buffer click the two-click contract requires, so revalidate immediately before
            // reading the clipboard or changing any generation. The request generation carries
            // what the published state cannot: a request that already finished may still have
            // accepted audio in flight, which leaves both `isStreaming` and `hasAudio` false while
            // the pipeline is not this attempt's to take. Superseded attempts never arrive here at
            // all; `deferredClipboardAction` drops them.
            let pipelineGeneration = networkManager.currentRequestGeneration()
            deferredClipboardAction.schedule(after: 0.2) {
                guard networkManager.currentRequestGeneration() == pipelineGeneration,
                      isReadyForNewSpeech,
                      let text = textExtraction.getCopiedText() else { return }
                guard !refusesOversizedOpenAIText(text) else { return }
                speechSession.start(text: text)
            }
        }
    }

    /// The maximum `input` length OpenAI documents for every model its Speech API accepts.
    private static let openAICharacterLimit = 4096

    /// Reports oversized OpenAI clipboard text to the user, and answers whether speech must not start.
    ///
    /// A longer value buys a request that can only fail, and the provider's rejection reaches the
    /// user as the same generic HTTP failure any other error produces. Checking it here keeps the
    /// refusal local: no request, no second network call, and no delay for a value that fits.
    ///
    /// Only this click path checks it. Services and Settings' Test Voice are outside the boundary
    /// this rule was agreed for, and neither Gemini nor a Custom endpoint documents this limit.
    /// The provider identity comes from the manager rather than a second endpoint inference beside
    /// it, and is the one selected when the click was revalidated: a provider the user switches
    /// inside the request's own start window is out of scope, because a Settings edit advances no
    /// request generation for the deferred action to observe.
    private func refusesOversizedOpenAIText(_ text: String) -> Bool {
        guard networkManager.isCurrentProvider(APIKeyProvider.openAI.settingsValue) else { return false }
        // OpenAI documents the maximum as "characters" without naming a Unicode unit. Scalars are
        // the unit a code-point count reaches first: grapheme clusters would let text the provider
        // rejects through, while UTF-16 units or UTF-8 bytes would refuse non-Latin text the
        // provider accepts.
        let characterCount = text.unicodeScalars.count
        guard characterCount > Self.openAICharacterLimit else { return false }
        alertPresenter.presentAlert(
            title: Self.oversizedTextAlertTitle,
            message: Self.oversizedTextAlertMessage(characterCount: characterCount)
        )
        return true
    }

    private static let oversizedTextAlertTitle = "Copied text is too long"

    /// Builds the refusal message, which names the limit and how far past it the copied text is.
    ///
    /// Counts are grouped in `en_US` rather than the user's locale so the digits match the English
    /// sentence around them, which is the only form the app ships. The message reports a length,
    /// never any clipboard content.
    private static func oversizedTextAlertMessage(characterCount: Int) -> String {
        let locale = Locale(identifier: "en_US")
        let limit = openAICharacterLimit.formatted(.number.locale(locale))
        let count = characterCount.formatted(.number.locale(locale))
        return "OpenAI accepts at most \(limit) characters per request. The copied text is "
            + "\(count) characters. Copy a shorter passage and try again."
    }

    func togglePlayPause() {
        if audioPlayer.isPlaying {
            audioPlayer.pause()
        } else {
            audioPlayer.play()
        }
    }

}

/// An AppKit-backed, accessible request-failure label that wraps within the menu width.
struct RequestErrorView: NSViewRepresentable {
    let message: String

    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .systemRed
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setAccessibilityIdentifier("tts-request-error")
        return label
    }

    func updateNSView(_ label: NSTextField, context: Context) {
        label.stringValue = message
    }
}
