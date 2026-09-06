import XCTest
@testable import ClipboardTTSApp

final class TTSNetworkManagerTests: MockURLProtocolTestCase {

    func testNetworkManagerFormatsRequestCorrectly() {
        // WHY: We must ensure that the app sends the exactly correct JSON payload, headers, and URL
        // when triggering a TTS request, so that the API accepts it without error.

        let manager = TestNetworkFactory.makeManager()

        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "secret_token", model: "tts-test", voice: "test-voice", selectedProvider: "OpenAI")

        let expectation = XCTestExpectation(description: "Wait for request to be formed")

        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://mock.api/v1/audio/speech")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret_token")

            var extractedData: Data? = request.httpBody
            if extractedData == nil, let stream = request.httpBodyStream {
                stream.open()
                let bufferSize = 1024
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                var data = Data()
                while stream.hasBytesAvailable {
                    let bytesRead = stream.read(&buffer, maxLength: bufferSize)
                    if bytesRead > 0 {
                        data.append(buffer, count: bytesRead)
                    } else {
                        break
                    }
                }
                stream.close()
                extractedData = data
            }

            if let bodyData = extractedData, !bodyData.isEmpty {
                let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
                XCTAssertEqual(json?["model"] as? String, "tts-test")
                XCTAssertEqual(json?["input"] as? String, "Hello world")
                XCTAssertEqual(json?["voice"] as? String, "test-voice")
                XCTAssertEqual(json?["response_format"] as? String, "pcm")
            } else {
                XCTFail("No request body found")
            }

            expectation.fulfill()
            return (HTTPURLResponse(), Data())
        }

        manager.streamTTS(text: "Hello world") { _ in }

        wait(for: [expectation], timeout: 2.0)
    }

    func testCustomRequestRequiresConfiguredModelAndVoiceBeforeStartingANetworkTask() {
        // WHY: Custom servers follow the OpenAI-compatible payload contract, so accepting blank
        // model or voice values would send a request the server cannot interpret. The validation
        // must fail through the menu's normal error state before a request reaches the endpoint.
        let manager = TestNetworkFactory.makeManager()
        MockURLProtocol.installRequestHandler { _ in
            XCTFail("Invalid Custom configuration must not contact the endpoint")
            return (HTTPURLResponse(), Data())
        }

        let invalidConfigurations = [
            (model: "", voice: "custom-voice", description: "missing model"),
            (model: " \n\t ", voice: "custom-voice", description: "whitespace model"),
            (model: "custom-model", voice: "", description: "missing voice"),
            (model: "custom-model", voice: " \n\t ", description: "whitespace voice")
        ]

        for configuration in invalidConfigurations {
            manager.updateSettings(
                baseURL: "https://custom.api/v1/audio/speech",
                apiKey: "custom-token",
                model: configuration.model,
                voice: configuration.voice,
                selectedProvider: "Custom"
            )
            manager.streamTTS(text: configuration.description) { _ in
                XCTFail("Invalid Custom configuration must not deliver audio")
            }

            XCTAssertEqual(manager.lastError, "Custom TTS requires a model and voice. Update Settings and try again.")
            XCTAssertFalse(manager.isStreaming)
        }
    }

    func testNetworkManagerInitUsesPersistedCustomModelAndVoice() {
        // WHY: Custom model and voice are required request fields, so a cold launch must restore
        // them before Settings is opened. Falling back to empty values would make clipboard and
        // Services speech fail despite the user having already configured the provider.
        let defaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Custom",
            SettingsKeys.apiBaseURL: "https://custom.api/v1/audio/speech",
            SettingsKeys.legacyCustomAPIKey: "persisted-custom-key",
            SettingsKeys.customModel: "persisted-custom-model",
            SettingsKeys.customVoice: "persisted-custom-voice"
        ])

        let manager = TestNetworkFactory.makeManager(defaults: defaults)
        let requestEmitted = expectation(description: "Persisted Custom values form a request")
        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer persisted-custom-key")
            let bodyData = try XCTUnwrap(requestBodyData(from: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: String])
            XCTAssertEqual(body["model"], "persisted-custom-model")
            XCTAssertEqual(body["voice"], "persisted-custom-voice")
            requestEmitted.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        manager.streamTTS(text: "Use persisted Custom settings") { _ in }
        wait(for: [requestEmitted], timeout: 2.0)
    }

    func testNetworkManagerStreamsDataChunks() {
        // WHY: The UI depends on receiving audio data quickly. This test ensures that when the server
        // sends data, the network manager relays it to the completion handler properly.

        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "OpenAI")

        let expectation = XCTestExpectation(description: "Wait for data chunk")

        MockURLProtocol.installRequestHandler { _ in
            let mockData = Data("audiochunk".utf8)
            return (HTTPURLResponse(), mockData)
        }

        manager.streamTTS(text: "Test streaming") { data in
            XCTAssertEqual(String(data: data, encoding: .utf8), "audiochunk")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testNetworkManagerStopsStreaming() {
        // WHY: Users might interrupt TTS playback. The network manager must cancel the ongoing network request
        // to save bandwidth and instantly transition the state.

        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "OpenAI")

        let requestStarted = XCTestExpectation(description: "Mock request started")
        let requestFinished = XCTestExpectation(description: "Mock request finished")
        MockURLProtocol.installRequestHandler { _ in
            requestStarted.fulfill()
            Thread.sleep(forTimeInterval: 0.5)
            requestFinished.fulfill()
            return (HTTPURLResponse(), Data())
        }

        manager.streamTTS(text: "Test cancel") { _ in }

        wait(for: [requestStarted], timeout: 1.0)

        let streamStarted = XCTestExpectation(description: "Wait for stream to start")
        DispatchQueue.main.async {
            XCTAssertTrue(manager.isStreaming)
            streamStarted.fulfill()
        }
        wait(for: [streamStarted], timeout: 1.0)

        manager.stopStreaming()

        let streamStopped = XCTestExpectation(description: "Wait for stream to stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertFalse(manager.isStreaming)
            streamStopped.fulfill()
        }
        wait(for: [streamStopped, requestFinished], timeout: 1.0)
    }

    func testNetworkManagerIgnoresDataAfterStop() {
        // WHY: A delegate callback for a task that is no longer active (e.g. one cancelled by
        // stopStreaming) must not invoke dataHandler, or a stale chunk resurrects audio after a stop.
        // We drive the delegate method directly with a task whose identifier does not match the
        // active one, because URLSession suppresses callbacks for a cancelled task, so the real
        // network path can never exercise the stale-callback guard.
        let manager = TestNetworkFactory.makeManager()
        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "OpenAI")

        let dataReceived = LockedValue(false)
        let requestStarted = XCTestExpectation(description: "Mock request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        let responseFinished = XCTestExpectation(description: "Mock response finished")
        MockURLProtocol.installRequestHandler { _ in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 1.0)
            responseFinished.fulfill()
            return (HTTPURLResponse(), Data("audiochunk".utf8))
        }
        manager.streamTTS(text: "Test cancel data") { _ in
            dataReceived.withValue { $0 = true }
        }
        wait(for: [requestStarted], timeout: 1.0)

        manager.stopStreaming()
        releaseResponse.signal()
        wait(for: [responseFinished], timeout: 1.0)

        // Simulate a late chunk arriving for the now-cancelled task. Its identifier cannot match the
        // active one (stopStreaming cleared it), so the guard must drop it.
        let mockSession = TestNetworkFactory.makeSession()
        let staleTask = mockSession.dataTask(with: URL(string: "https://mock.api/v1/audio/speech")!)
        manager.urlSession(mockSession, dataTask: staleTask, didReceive: Data("late chunk".utf8))
        manager.urlSession(mockSession, task: staleTask, didCompleteWithError: nil)

        let expectation = XCTestExpectation(description: "Wait to ensure no data is received")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertFalse(dataReceived.value)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testNetworkManagerFormatsGeminiRequestCorrectly() {
        let manager = TestNetworkFactory.makeManager()

        let geminiKey = "test-gemini-api-key"
        manager.updateSettings(baseURL: "https://generativelanguage.googleapis.com/v1beta", apiKey: geminiKey, model: "gemini-tts", voice: "Aoede", selectedProvider: "Gemini")

        let expectation = XCTestExpectation(description: "Wait for Gemini request")

        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-tts:streamGenerateContent?alt=sse")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), geminiKey)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(request.url?.absoluteString.contains(geminiKey) ?? true)
            XCTAssertEqual(request.httpMethod, "POST")

            var extractedData: Data? = request.httpBody
            if extractedData == nil, let stream = request.httpBodyStream {
                stream.open()
                let bufferSize = 1024
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                var data = Data()
                while stream.hasBytesAvailable {
                    let bytesRead = stream.read(&buffer, maxLength: bufferSize)
                    if bytesRead > 0 { data.append(buffer, count: bytesRead) } else { break }
                }
                stream.close()
                extractedData = data
            }

            if let bodyData = extractedData, !bodyData.isEmpty {
                let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
                let contents = json?["contents"] as? [[String: Any]]
                let parts = contents?.first?["parts"] as? [[String: Any]]
                XCTAssertEqual(parts?.first?["text"] as? String, "Hello Gemini")
            } else {
                XCTFail("No request body")
            }

            expectation.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        manager.streamTTS(text: "Hello Gemini") { _ in }
        wait(for: [expectation], timeout: 2.0)
    }

    func testNetworkManagerHandlesAPIError() {
        let manager = TestNetworkFactory.makeManager()

        manager.updateSettings(baseURL: "https://mock.api/v1/audio/speech", apiKey: "test", model: "test", voice: "test", selectedProvider: "OpenAI")

        let expectation = XCTestExpectation(description: "Wait for error completion")

        MockURLProtocol.installRequestHandler { request in
            let errorData = Data("{\"error\": \"Unauthorized\"}".utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, errorData)
        }

        manager.streamTTS(text: "Test error") { _ in }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertFalse(manager.isStreaming)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func testNetworkManagerInitReadsProviderSpecificDefaults() {
        // WHY: SettingsView persists model/voice under provider-specific UserDefaults keys
        // (openaiModel/openaiVoice, geminiModel/geminiVoice). The manager's init must read the
        // same keys so user-chosen settings survive an app restart even before the settings
        // window is opened. A regression here would silently fall back to hardcoded defaults
        // (tts-1/alloy) on every cold start until the user re-opens settings.
        // OpenAI: persisted model/voice/key should drive the outgoing request. Each provider gets
        // its own store because each manager reads its settings once, when it is constructed.
        let openaiDefaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "OpenAI",
            SettingsKeys.openAIModel: "persisted-openai-model",
            SettingsKeys.openAIVoice: "persisted-openai-voice",
            SettingsKeys.legacyOpenAIAPIKey: "persisted-openai-key"
        ])
        let geminiDefaults = makeOwnedDefaults([
            SettingsKeys.ttsProvider: "Gemini",
            SettingsKeys.geminiModel: "persisted-gemini-model",
            SettingsKeys.geminiVoice: "persisted-gemini-voice",
            SettingsKeys.legacyGeminiAPIKey: "persisted-gemini-key"
        ])

        let openaiManager = TestNetworkFactory.makeManager(defaults: openaiDefaults)
        let openaiExpectation = XCTestExpectation(description: "OpenAI request uses persisted values")

        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer persisted-openai-key")

            var extractedData: Data? = request.httpBody
            if extractedData == nil, let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 1024)
                var data = Data()
                while stream.hasBytesAvailable {
                    let bytesRead = stream.read(&buffer, maxLength: 1024)
                    if bytesRead > 0 { data.append(buffer, count: bytesRead) } else { break }
                }
                stream.close()
                extractedData = data
            }

            if let bodyData = extractedData,
               let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                XCTAssertEqual(json["model"] as? String, "persisted-openai-model")
                XCTAssertEqual(json["voice"] as? String, "persisted-openai-voice")
            } else {
                XCTFail("OpenAI request body missing")
            }

            openaiExpectation.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        openaiManager.streamTTS(text: "test") { _ in }
        wait(for: [openaiExpectation], timeout: 2.0)

        // Gemini: persisted model embeds in URL path, voice embeds in request body.

        let geminiManager = TestNetworkFactory.makeManager(defaults: geminiDefaults)
        let geminiExpectation = XCTestExpectation(description: "Gemini request uses persisted values")

        MockURLProtocol.installRequestHandler { request in
            XCTAssertEqual(request.url?.absoluteString,
                           "https://generativelanguage.googleapis.com/v1beta/models/persisted-gemini-model:streamGenerateContent?alt=sse")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "persisted-gemini-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

            var extractedData: Data? = request.httpBody
            if extractedData == nil, let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 1024)
                var data = Data()
                while stream.hasBytesAvailable {
                    let bytesRead = stream.read(&buffer, maxLength: 1024)
                    if bytesRead > 0 { data.append(buffer, count: bytesRead) } else { break }
                }
                stream.close()
                extractedData = data
            }

            if let bodyData = extractedData,
               let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                let cfg = json["generationConfig"] as? [String: Any]
                let speech = cfg?["speechConfig"] as? [String: Any]
                let voiceCfg = speech?["voiceConfig"] as? [String: Any]
                let prebuilt = voiceCfg?["prebuiltVoiceConfig"] as? [String: Any]
                XCTAssertEqual(prebuilt?["voiceName"] as? String, "persisted-gemini-voice")
            } else {
                XCTFail("Gemini request body missing")
            }

            geminiExpectation.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        geminiManager.streamTTS(text: "test") { _ in }
        wait(for: [geminiExpectation], timeout: 2.0)
    }

}
