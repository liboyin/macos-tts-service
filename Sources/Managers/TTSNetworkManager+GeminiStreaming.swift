import Foundation

/// Incrementally separates Server-Sent Event `data` payloads while preserving an unfinished line.
struct GeminiSSEEventParser {
    private var incompleteLine = Data()
    private var eventDataLines: [Data] = []

    /// Reports whether end of stream would discard an incomplete Server-Sent Event.
    var hasIncompleteEvent: Bool {
        !incompleteLine.isEmpty || !eventDataLines.isEmpty
    }

    /// Appends bytes from one URL-session callback and returns only fully terminated event payloads.
    mutating func append(_ data: Data) -> [Data] {
        incompleteLine.append(data)
        var payloads: [Data] = []

        while let lineEnding = incompleteLine.firstIndex(of: 0x0A) {
            var line = Data(incompleteLine.prefix(upTo: lineEnding))
            incompleteLine.removeSubrange(...lineEnding)
            if line.last == 0x0D {
                line.removeLast()
            }

            if line.isEmpty {
                guard !eventDataLines.isEmpty else { continue }
                payloads.append(joinedDataLines())
                eventDataLines.removeAll(keepingCapacity: true)
            } else if line.starts(with: Data("data:".utf8)) {
                appendDataLine(from: line)
            }
        }

        return payloads
    }

    private mutating func appendDataLine(from line: Data) {
        var value = Data(line.dropFirst(5))
        if value.first == 0x20 {
            value.removeFirst()
        }
        eventDataLines.append(value)
    }

    private func joinedDataLines() -> Data {
        eventDataLines.dropFirst().reduce(eventDataLines.first ?? Data()) { partial, line in
            partial + Data([0x0A]) + line
        }
    }
}

extension TTSNetworkManager {
    /// One complete Gemini event's audio classification together with any finish reason it declared.
    ///
    /// The two are independent: a candidate may declare `finishReason` beside its audio parts, in a
    /// content-free candidate, or not at all, and reading it must not change how audio is classified.
    private struct GeminiEventContent {
        enum Payload {
            case audio(Data)
            case noAudio
            case invalid
        }

        let payload: Payload
        /// `candidates[0].finishReason`, or nil when the event declares none as a string.
        let declaredFinishReason: String?

        static let invalid = GeminiEventContent(payload: .invalid, declaredFinishReason: nil)
        static let noAudio = GeminiEventContent(payload: .noAudio, declaredFinishReason: nil)
    }

    /// Queues PCM for a request generation and invokes its handler only while that generation
    /// still owns delivery. Completion deliberately leaves the generation intact so audio accepted
    /// before a normal URL-session completion remains playable.
    func enqueueAudioDelivery(_ data: Data,
                              dataHandler: @escaping @Sendable (Data) -> Void,
                              requestGeneration: UInt64) {
        audioDeliveryQueue.async { [weak self] in
            guard let self else { return }
            self.callbackAuthority.lock()
            defer { self.callbackAuthority.unlock() }
            guard self.isCurrentRequestGeneration(requestGeneration) else { return }
            dataHandler(data)
        }
    }

    /// Queues one request's terminal event, behind every delivery that request already queued.
    ///
    /// It takes the same serial delivery queue, callback authority, and generation guard as
    /// `enqueueAudioDelivery`. The queue is what orders a session's terminal event behind its PCM:
    /// URLSession delivers a task's data callbacks before its completion callback, and each of
    /// those enqueues here in turn. The generation guard is what withdraws the event when something
    /// else claimed the pipeline first, so a stopped or replaced session is never told that the
    /// request it no longer owns has ended.
    func enqueueStreamTermination(_ termination: SpeechStreamTermination,
                                  client: SpeechStreamClient,
                                  requestGeneration: UInt64?) {
        audioDeliveryQueue.async { [weak self] in
            guard let self else { return }
            self.callbackAuthority.lock()
            defer { self.callbackAuthority.unlock() }
            guard self.isCurrentRequestGeneration(requestGeneration) else { return }
            client.didTerminate(termination)
        }
    }

    /// What a revoked malformed Gemini stream leaves its caller to finish reporting.
    ///
    /// The revocation clears the request context, so the generation its terminal state publishes
    /// against and the client that must be told the session ended both have to travel out with it.
    struct FailedGeminiRevocation {
        let task: URLSessionDataTask
        let requestGeneration: UInt64
        let client: SpeechStreamClient
    }

    /// Finishes revoking a malformed Gemini stream while holding the callback authority boundary.
    func revokeFailedGeminiRequest(for task: URLSessionDataTask) -> FailedGeminiRevocation? {
        callbackAuthority.lock()
        defer { callbackAuthority.unlock() }
        return stateQueue.sync {
            guard let context = activeRequest,
                  context.taskIdentifier == task.taskIdentifier,
                  context.hasGeminiStreamFailure else {
                return nil
            }
            activeRequest = nil
            return FailedGeminiRevocation(
                task: context.task,
                requestGeneration: requestGeneration,
                client: context.client
            )
        }
    }

    /// Validates an incoming task chunk and invokes its handler after releasing `stateQueue`.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let failedGeminiTask = stateQueue.sync { () -> URLSessionDataTask? in
            guard var context = activeRequest, dataTask.taskIdentifier == context.taskIdentifier,
                  !context.isErrorResponse else { return nil }
            if context.provider == .gemini {
                guard !context.hasGeminiStreamFailure else { return nil }
                let events = context.geminiEventParser.append(data)
                guard !events.isEmpty else {
                    activeRequest = context
                    return nil
                }
                // Decode and account for events before completion can clear this request. Only
                // the user handler is deferred, so it remains outside stateQueue but retains the
                // order in which this request accepted delegate callbacks.
                if let failedRequest = enqueueGeminiEvents(events, into: &context, for: dataTask) {
                    // Invalidate queued delivery before it can acquire callback authority. A
                    // delivery already waiting on stateQueue will therefore observe the failed
                    // generation when it continues, while a running handler is awaited below.
                    requestGeneration &+= 1
                    // Leave the failed context in place until its revocation takes the callback
                    // authority lock. That preserves the lock order used by delivery.
                    activeRequest = context
                    return failedRequest.task
                }
                activeRequest = context
                return nil
            }
            guard !data.isEmpty else { return nil }
            context.providerAudioByteCount += data.count
            let dataHandler = context.client.didReceiveAudio
            let deliveryGeneration = context.requestGeneration
            // Enqueue while stateQueue owns this context, rather than after its lock is released,
            // so a later concurrent delegate callback cannot overtake this PCM chunk.
            enqueueAudioDelivery(data, dataHandler: dataHandler, requestGeneration: deliveryGeneration)
            activeRequest = context
            return nil
        }
        guard let failedGeminiTask,
              let revocation = revokeFailedGeminiRequest(for: failedGeminiTask) else {
            return
        }
        revocation.task.cancel()
        publishFailure("The TTS service returned no playable audio. Please try again.", requestGeneration: revocation.requestGeneration)
        enqueueStreamTermination(.failed, client: revocation.client, requestGeneration: revocation.requestGeneration)
    }

    /// Decodes complete SSE events while `stateQueue` owns their request context.
    private func enqueueGeminiEvents(_ events: [Data],
                                     into context: inout ActiveRequestContext,
                                     for task: URLSessionDataTask) -> (task: URLSessionDataTask, requestGeneration: UInt64)? {
        for event in events {
            let content = extractGeminiEventContent(from: event)
            // Retain the most recently declared reason. A trailing metadata event or a candidate
            // that omits the field declares nothing, so it must not erase what an earlier candidate
            // reported; only a later declared reason replaces it.
            if let declaredFinishReason = content.declaredFinishReason {
                context.geminiDeclaredFinishReason = declaredFinishReason
            }
            switch content.payload {
            case let .audio(audioData):
                guard let playableAudio = recordGeminiAudio(audioData, in: &context) else { continue }
                let dataHandler = context.client.didReceiveAudio
                enqueueAudioDelivery(
                    playableAudio,
                    dataHandler: dataHandler,
                    requestGeneration: context.requestGeneration
                )
            case .noAudio:
                continue
            case .invalid:
                context.hasGeminiStreamFailure = true
                return (task, context.requestGeneration)
            }
        }
        return nil
    }

    /// Records one decoded Gemini payload under `stateQueue` and returns complete PCM for delivery.
    private func recordGeminiAudio(_ audioData: Data, in context: inout ActiveRequestContext) -> Data? {
        context.providerAudioByteCount += audioData.count
        context.geminiIncompletePCM.append(audioData)
        let playableByteCount = context.geminiIncompletePCM.count
            - context.geminiIncompletePCM.count % 2
        guard playableByteCount > 0 else { return nil }
        let playableAudio = Data(context.geminiIncompletePCM.prefix(playableByteCount))
        context.geminiIncompletePCM.removeFirst(playableByteCount)
        return playableAudio
    }

    /// Classifies one complete Gemini event without attempting to decode an absent audio payload.
    private func extractGeminiEventContent(from event: Data) -> GeminiEventContent {
        guard let json = try? JSONSerialization.jsonObject(with: event) as? [String: Any],
              json["error"] == nil else {
            return .invalid
        }
        guard let rawCandidates = json["candidates"] else {
            return .noAudio
        }
        guard let candidates = rawCandidates as? [[String: Any]] else {
            return .invalid
        }
        guard let candidate = candidates.first else {
            return .noAudio
        }
        // A `finishReason` of another type counts as undeclared rather than as a corrupt stream, so
        // a provider schema change leaves the remaining completion checks in charge instead of
        // revoking speech the user can already hear.
        return GeminiEventContent(
            payload: audioPayload(in: candidate),
            declaredFinishReason: candidate["finishReason"] as? String
        )
    }

    /// Classifies the audio one Gemini candidate carries, independently of any reason it declared.
    private func audioPayload(in candidate: [String: Any]) -> GeminiEventContent.Payload {
        guard let rawContent = candidate["content"] else {
            return .noAudio
        }
        guard let content = rawContent as? [String: Any] else {
            return .invalid
        }
        guard let rawParts = content["parts"] else {
            return .noAudio
        }
        guard let parts = rawParts as? [[String: Any]] else {
            return .invalid
        }
        for part in parts {
            guard let rawInlineData = part["inlineData"] else { continue }
            guard let inlineData = rawInlineData as? [String: Any],
                  let base64String = inlineData["data"] as? String,
                  let audioData = Data(base64Encoded: base64String) else {
                return .invalid
            }
            return .audio(audioData)
        }
        return .noAudio
    }

}
