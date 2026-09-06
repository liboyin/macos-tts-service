import Foundation

/// Streams speech audio for one request at a time and publishes request state to the menu bar.
///
/// Marked `@unchecked Sendable` because the `URLSessionDataDelegate` conformance requires
/// `Sendable` and URLSession invokes delegate methods on its own queue. Three confinement rules
/// keep that sound, and concurrent delegate entry is covered by `TTSNetworkManagerConcurrencyTests`:
/// - Mutable request, settings, and metadata state (`activeRequest`, `requestGeneration`,
///   `baseURL`, `apiKey`, `model`, `voice`, `selectedMetadataProvider`, the metadata request
///   records, and the publication-depth counter) is read and written only under `stateQueue`.
/// - The `@Published` properties, `isPublishingMetadata`, and `migrationFailureMessage` are written
///   only on the main queue (every write path dispatches or already runs there) and are observed by
///   SwiftUI on main. Construction is the one exception: the initializer assigns
///   `migrationFailureMessage`, and `lastError` when startup could not secure or read a saved key,
///   on whichever thread builds the manager and before it is shared.
/// - A recursive callback-authority lock spans delivery authorization through the complete handler
///   call and generation revocation; it is never the request-state lock, so direct re-entrant stops work.
/// - A path that needs both locks acquires callback authority before `stateQueue`; fatal Gemini
///   parsing advances its generation under `stateQueue` before waiting at callback authority.
/// `session` and `sessionInvalidated` are assigned once during init, before the manager is shared.
final class TTSNetworkManager: NSObject, ObservableObject, URLSessionDataDelegate, @unchecked Sendable {
    @Published var isStreaming = false
    /// A short, sanitized explanation of the most recent speech-request failure.
    @Published private(set) var lastError: String?
    /// The model and voice choices currently offered, each naming the provider that published it.
    @Published var modelSuggestions = ProviderSuggestions.unpublished
    @Published var voiceSuggestions = ProviderSuggestions.unpublished

    private(set) var baseURL: String
    private var apiKey: String
    private var model: String
    private var voice: String

    var session: URLSession!
    /// Session-lifecycle and request-body seams used by production setup and focused tests.
    private let sessionInvalidated: ((URLSession) -> Void)?
    let requestBodyEncoder: (Data) throws -> Data
    /// Serializes active-request state; client callbacks are captured here but always invoked after leaving this queue.
    let stateQueue = DispatchQueue(label: "com.clipboardtts.ttsnetworkmanager")
    /// Delivers request-owned PCM in the same order that `stateQueue` accepts delegate callbacks.
    ///
    /// Keeping this separate from `stateQueue` lets a handler synchronously stop or replace its
    /// stream without deadlocking the request-state lock.
    let audioDeliveryQueue: DispatchQueue
    /// Serializes generation revocation with delivery authorization and the complete client
    /// callback. It is recursive so a handler can synchronously stop or replace its own stream.
    let callbackAuthority: CallbackAuthorityLocking
    var activeRequest: ActiveRequestContext?
    var requestGeneration: UInt64 = 0
    private var requestStatePublicationDepth = 0
    /// The legacy-key migration warning this manager last published, retained so a later recovery
    /// can withdraw or replace exactly that message rather than whatever `lastError` holds by then.
    private var migrationFailureMessage: String?
    private(set) var selectedMetadataProvider: String
    var metadataGeneration: UInt64 = 0
    var nextMetadataRequestIdentifier: UInt64 = 0
    var modelMetadataRequest: MetadataRequest?
    var voiceMetadataRequest: MetadataRequest?
    var isPublishingMetadata = false

    /// Returns the active task for debug-only delegate-ordering tests.
    #if DEBUG
    var activeTaskForTesting: URLSessionDataTask? { stateQueue.sync { activeRequest?.task } }
    #endif

    enum ProviderKind: Equatable {
        case openAICompatible
        case gemini
        case custom

        init(baseURL: String, selectedProvider: String) {
            if selectedProvider == "Custom" {
                self = .custom
            } else {
                self = baseURL.contains("generativelanguage.googleapis.com") ? .gemini : .openAICompatible
            }
        }
    }

    /// The values used to create one request, captured before the task is resumed.
    struct RequestSettings {
        let baseURL: String
        let apiKey: String
        let model: String
        let voice: String
        let provider: ProviderKind
    }

    /// State that belongs exclusively to the active URL session task and is guarded by `stateQueue`.
    struct ActiveRequestContext {
        let task: URLSessionDataTask
        let taskIdentifier: Int
        let requestGeneration: UInt64
        let provider: ProviderKind
        /// The request this attempt sent, retained so its permitted retry replays exactly it.
        let request: URLRequest
        let dataHandler: @Sendable (Data) -> Void
        /// Whether this attempt is itself the retry, which is what bounds recovery to one extra try.
        let isRetryAttempt: Bool
        var isErrorResponse = false
        var responseStatusCode: Int?
        var geminiEventParser = GeminiSSEEventParser()
        var geminiIncompletePCM = Data()
        var hasGeminiStreamFailure = false
        /// The most recent `finishReason` a Gemini candidate declared, retained because only an
        /// explicit non-`STOP` reason distinguishes a provider-truncated stream from a normal end.
        var geminiDeclaredFinishReason: String?
        var providerAudioByteCount = 0
        var didRefuseInsecureRedirect = false
    }

    /// Creates a manager and optionally observes the lifecycle of its underlying URL session.
    init(configuration: URLSessionConfiguration = .default,
         sessionCreated: ((URLSession) -> Void)? = nil,
         sessionInvalidated: ((URLSession) -> Void)? = nil,
         secretStore: SecretStoring = KeychainSecretStore(),
         defaults: UserDefaults,
         requestBodyEncoder: @escaping (Data) throws -> Data = { $0 },
         audioDeliveryQueue: DispatchQueue = DispatchQueue(label: "com.clipboardtts.ttsaudiodelivery"),
         callbackAuthority: CallbackAuthorityLocking = RecursiveCallbackAuthority()) {
        let persistedProvider = defaults.string(forKey: SettingsKeys.ttsProvider) ?? "OpenAI"
        let provider = APIKeyProvider(selectedProvider: persistedProvider)
        self.selectedMetadataProvider = provider.settingsValue
        let secretStartupState = APIKeyStartupState.load(
            selectedProvider: provider.settingsValue, secretStore: secretStore, defaults: defaults
        )
        switch provider {
        case .openAI:
            self.baseURL = "https://api.openai.com/v1/audio/speech"
            self.apiKey = secretStartupState.apiKey
            self.model = defaults.string(forKey: SettingsKeys.openAIModel) ?? "tts-1"
            self.voice = defaults.string(forKey: SettingsKeys.openAIVoice) ?? "alloy"
        case .gemini:
            self.baseURL = "https://generativelanguage.googleapis.com/v1beta"
            self.apiKey = secretStartupState.apiKey
            self.model = defaults.string(forKey: SettingsKeys.geminiModel) ?? "gemini-3.1-flash-tts-preview"
            self.voice = defaults.string(forKey: SettingsKeys.geminiVoice) ?? "Aoede"
        case .custom:
            self.baseURL = defaults.string(forKey: SettingsKeys.apiBaseURL) ?? "https://api.openai.com/v1/audio/speech"
            self.apiKey = secretStartupState.apiKey
            self.model = defaults.string(forKey: SettingsKeys.customModel) ?? ""
            self.voice = defaults.string(forKey: SettingsKeys.customVoice) ?? ""
        }
        self.requestBodyEncoder = requestBodyEncoder
        self.sessionInvalidated = sessionInvalidated
        self.audioDeliveryQueue = audioDeliveryQueue
        self.callbackAuthority = callbackAuthority

        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        sessionCreated?(self.session)
        if let errorMessage = secretStartupState.errorMessage { self.lastError = errorMessage }
        // Startup collapses its migration failures into the first provider's guidance, so the same
        // provider's message identifies the warning published above. A key that could not be read
        // produces a different message, which securing a legacy key does not resolve.
        self.migrationFailureMessage = APIKeyMigrationService.pendingProviders(defaults: defaults)
            .first
            .map(APIKeyMigrationService.failureMessage(for:))
    }

    /// Updates the settings used by future TTS requests and invalidates metadata from a previous provider or endpoint.
    ///
    /// The caller names the provider rather than letting the manager infer one from the endpoint,
    /// so `selectedMetadataProvider` can only ever hold an identity a surface is able to match: an
    /// inferred name that no provider form recognizes would silently refuse every list it tags.
    func updateSettings(baseURL: String,
                        apiKey: String,
                        model: String,
                        voice: String,
                        selectedProvider: String) {
        let invalidatedGeneration: UInt64? = stateQueue.sync {
            let metadataScopeChanged = self.baseURL != baseURL || self.selectedMetadataProvider != selectedProvider
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.model = model
            self.voice = voice
            self.selectedMetadataProvider = selectedProvider

            guard metadataScopeChanged else { return nil }

            metadataGeneration &+= 1
            modelMetadataRequest?.task?.cancel()
            modelMetadataRequest = nil
            voiceMetadataRequest = nil
            return metadataGeneration
        }
        if let invalidatedGeneration {
            clearMetadataLists(for: invalidatedGeneration)
        }
    }

    /// Returns the token identifying which logical request currently owns the pipeline.
    ///
    /// It advances only when a request starts, is replaced, or is stopped, so a caller that
    /// captured it earlier can tell that somebody else claimed or released the pipeline in between
    /// — including while a finished request's accepted audio has not reached the player yet, when
    /// neither `isStreaming` nor `hasAudio` reports the pipeline as busy. A request's own automatic
    /// retry inherits this token rather than advancing it, because recovering from a transient
    /// provider failure is not somebody else claiming the pipeline; keep it that way, or every
    /// waiting menu action would go stale on a retry the user never asked for.
    func currentRequestGeneration() -> UInt64 {
        stateQueue.sync { requestGeneration }
    }

    /// Returns whether the manager's future-request settings belong to the supplied persisted provider.
    func isCurrentProvider(_ provider: String) -> Bool {
        stateQueue.sync {
            selectedMetadataProvider == provider
        }
    }

    /// Returns the model that future requests will use.
    ///
    /// Deliberately reads the model alone: the OpenAI voice catalog is the only caller, and its
    /// choice depends on nothing else. Handing it an aggregate would deliver the saved API key,
    /// endpoint, and provider identity to a metadata-only path that would discard all three, so a
    /// credential must not be added back here.
    func currentModel() -> String {
        stateQueue.sync { model }
    }

    /// Captures the immutable settings one request attempt owns from start to finish.
    func requestSettingsSnapshot() -> RequestSettings {
        stateQueue.sync {
            RequestSettings(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                voice: voice,
                provider: ProviderKind(baseURL: baseURL, selectedProvider: selectedMetadataProvider)
            )
        }
    }

    /// Publishes a request failure on the main queue and marks the request as finished.
    func publishFailure(_ message: String, requestGeneration: UInt64? = nil) {
        let update: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            guard self.isCurrentRequestGeneration(requestGeneration) else { return }
            self.withRequestStatePublication {
                self.lastError = message
                self.isStreaming = false
            }
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    /// Clears a failure message only when it belongs to the latest request attempt.
    func clearLastError(requestGeneration: UInt64? = nil) {
        let update: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            guard self.isCurrentRequestGeneration(requestGeneration) else { return }
            self.withRequestStatePublication {
                self.lastError = nil
            }
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    /// Republishes or withdraws the warning about a legacy key that could not be secured.
    ///
    /// Settings calls this after the user retries that migration: passing the provider still
    /// pending keeps the menu bar naming a key that really is unsecured, and passing `nil`
    /// withdraws the warning once every one of them is secured. Only the message this manager
    /// itself published for migration is replaced: a request that published or cleared `lastError`
    /// since then owns that line, and what it says — including saying nothing — is not something
    /// securing a key changes. An unresolved migration therefore stays visible in Settings, which
    /// is where its recovery is.
    func updateMigrationFailureWarning(for provider: APIKeyProvider?) {
        let message = provider.map(APIKeyMigrationService.failureMessage(for:))
        let update: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let publishedWarning = self.migrationFailureMessage
            self.migrationFailureMessage = message
            guard self.lastError == publishedWarning else { return }
            self.withRequestStatePublication {
                self.lastError = message
            }
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    /// Publishes the request lifecycle state on the main queue.
    func setStreaming(_ isStreaming: Bool, requestGeneration: UInt64? = nil) {
        let update: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            guard self.isCurrentRequestGeneration(requestGeneration) else { return }
            self.withRequestStatePublication {
                self.isStreaming = isStreaming
            }
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    /// Returns whether a completion still belongs to the latest stream generation.
    func isCurrentRequestGeneration(_ generation: UInt64?) -> Bool {
        guard let generation else { return true }
        return stateQueue.sync { requestGeneration == generation }
    }

    /// Defers request starts triggered by synchronous `@Published` observer re-entrancy.
    func deferRequestStartIfPublishingState(_ action: @escaping @Sendable () -> Void) -> Bool {
        let isPublishing = stateQueue.sync { requestStatePublicationDepth > 0 }
        guard isPublishing else { return false }
        DispatchQueue.main.async(execute: action)
        return true
    }

    /// Marks a `@Published` mutation so re-entrant observers cannot start a request mid-update.
    private func withRequestStatePublication(_ update: () -> Void) {
        stateQueue.sync { requestStatePublicationDepth += 1 }
        defer { stateQueue.sync { requestStatePublicationDepth -= 1 } }
        update()
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        var shouldAllow = false
        stateQueue.sync {
            if var context = activeRequest, dataTask.taskIdentifier == context.taskIdentifier {
                shouldAllow = true
                if let httpResponse = response as? HTTPURLResponse {
                    context.responseStatusCode = httpResponse.statusCode
                    if !(200...299).contains(httpResponse.statusCode) {
                        context.isErrorResponse = true
                    }
                }
                activeRequest = context
            }
        }
        completionHandler(shouldAllow ? .allow : .cancel)
    }

    /// Applies the endpoint transport rule to a redirect the provider asks the app to follow.
    ///
    /// URLSession follows redirects on its own, and a 307 or 308 replays the original method and
    /// body — the user's clipboard text — at whatever endpoint the response names, so checking the
    /// configured endpoint alone would let a provider move a request onto cleartext after it
    /// started. This runs for metadata tasks as well, which URLSession consults here even though
    /// they carry their own completion handler. A refused target records itself on the active
    /// speech request so completion reports the transport failure instead of the redirect status.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, EndpointTransportPolicy.permitsCredentials(url) {
            completionHandler(request)
            return
        }
        stateQueue.sync {
            guard var context = activeRequest, task.taskIdentifier == context.taskIdentifier else { return }
            context.didRefuseInsecureRedirect = true
            activeRequest = context
        }
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        sessionInvalidated?(session)
    }
}
