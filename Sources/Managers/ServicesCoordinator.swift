import Foundation

/// Wires the macOS Services flow into the TTS pipeline from app launch.
///
/// `ServicesProvider.handleServices` posts `speakSelectedTextNotification` with the selected text
/// as its object when the user invokes the "Speak Selected Text with Clipboard TTS" service. This
/// coordinator owns that subscription so the pipeline is live the moment the app starts. Previously
/// the only observer lived on `MenuBarView`, whose body SwiftUI does not build until the menu bar
/// dropdown is first opened, so the service was silently dropped until then.
///
/// Marked `@unchecked Sendable` because NotificationCenter delivers the observation through a
/// `@Sendable` closure on the posting thread. The coordinator's own state needs no further
/// synchronization: `observer` is assigned once in `init` and read only in `deinit`. Every
/// notification is handed to the main actor before it reaches the main-queue-confined session
/// owner that reads UI and engine state.
final class ServicesCoordinator: ObservableObject, @unchecked Sendable {
    static let speakSelectedTextNotification = Notification.Name("SpeakSelectedText")

    /// The session owner every entry point shares. Not private, because the composition root's
    /// regression asserts that this is the same instance the scenes were handed: a Services flow
    /// speaking into a second manager pair would reach a pipeline the menu neither shows nor
    /// controls, and every other test builds its own correctly paired owner.
    let speechSession: SpeechSessionCoordinator
    private let notificationCenter: NotificationCenter
    private let mainActionExecutor: (@escaping @MainActor @Sendable () -> Void) -> Void
    private let speechActionObserver: @MainActor () -> Void
    private var observer: NSObjectProtocol?

    init(speechSession: SpeechSessionCoordinator,
         notificationCenter: NotificationCenter = .default,
         mainActionExecutor: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void = { action in
             if Thread.isMainThread {
                 MainActor.assumeIsolated(action)
             } else {
                 DispatchQueue.main.async(execute: action)
             }
         },
         speechActionObserver: @escaping @MainActor () -> Void = {}) {
        self.speechSession = speechSession
        self.notificationCenter = notificationCenter
        self.mainActionExecutor = mainActionExecutor
        self.speechActionObserver = speechActionObserver
        // queue: nil delivers synchronously on the posting thread. Explicitly hand the entire
        // pipeline to main because Services and tests can post from a background queue.
        observer = notificationCenter.addObserver(
            forName: Self.speakSelectedTextNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self, let text = notification.object as? String else { return }
            self.mainActionExecutor { [weak self] in
                self?.speak(text)
            }
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }

    /// Speaks the selection, replacing whatever was speaking.
    ///
    /// Services carries a selection the user made in another app, so it deliberately keeps no
    /// two-click contract of its own: the session owner replaces the current session outright. The
    /// refusal for an audio graph that cannot play the selected format lives there too, which is
    /// what keeps a corrupt persisted Custom rate from decoding this selection at a silent fallback.
    @MainActor private func speak(_ text: String) {
        speechActionObserver()
        speechSession.start(text: text)
    }
}
