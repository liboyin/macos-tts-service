// swiftlint:disable file_length
// AudioPlayerManager keeps the buffer-queue and main-queue confinement rules and their
// documentation in one cohesive file; splitting it would separate invariants from the code
// they describe.
import Foundation
import AVFoundation
/// Buffers streamed PCM, drives the playback engine, and publishes playback state to the menu bar.
///
/// Marked `@unchecked Sendable` because network callbacks schedule audio from the URLSession
/// delegate queue while the UI and Services flows drive it from the main queue; concurrent
/// scheduling entry is covered by `AudioPlayerManagerTests`. The pre-existing confinement rules:
/// - Buffer state (`pcmData`, `bufferedPCMFrameCount`, `audioFormat`, and the scheduling
///   generations) is read and written only on `bufferQueue`.
/// - The `@Published` properties, audio engine, `engineStarter`, `baseProgressOffset`, and the
///   progress timer are confined to the main queue.
/// - `playerNode` scheduling and control run on `bufferQueue` or the main queue, matching the
///   threading pattern this class has always used for `AVAudioPlayerNode`.
final class AudioPlayerManager: ObservableObject, @unchecked Sendable {
    static let defaultSampleRate = 24_000.0
    static let supportedSampleRateRange = 8_000.0...48_000.0
    private static let automaticPlaybackPrebufferDuration: TimeInterval = 0.1
    /// How often playback republishes its position while a stream plays.
    private static let progressTickInterval: TimeInterval = 0.1
    enum SampleRateUpdateResult: Equatable {
        case unchanged
        case updated
        case invalid
        case engineStartFailed
    }
    @Published var isPlaying = false
    @Published var playbackProgress: Double = 0.0
    @Published var bufferDuration: Double = 0.0
    @Published var hasAudio = false
    @Published private(set) var sampleRate: Double = defaultSampleRate
    @Published private(set) var sampleRateError: String?
    @Published private(set) var hasValidSampleRateInput = true
    @Published private(set) var hasValidSampleRateConfiguration = true
    @Published var playbackRate: Float = 1.0 {
        didSet {
            timePitch.rate = playbackRate
        }
    }
    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var timePitch = AVAudioUnitTimePitch()
    private var audioFormat: AVAudioFormat?
    // pcmData is written from the network delegate's background queue (scheduleAudio) and
    // read/cleared from the main thread (seek/stop). All access MUST
    // go through bufferQueue to avoid a data race.
    private let bufferQueue = DispatchQueue(label: "com.clipboardtts.audiobuffer")
    private var pcmData = (accumulated: Data(), unprocessed: Data())
    private var bufferedPCMFrameCount = 0
    private var baseProgressOffset: Double = 0.0
    private var scheduleGeneration: Int = 0
    private var automaticPlaybackGeneration: Int?
    private var automaticPlaybackSuppressedGeneration: Int?
    private let scheduledBufferObserver: (AVAudioPCMBuffer) -> Void
    private let engineStarter: (AVAudioEngine) throws -> Void
    /// Defers the automatic-playback start; the action it is given crosses to the main queue.
    private let automaticPlaybackScheduler: (TimeInterval, @escaping @Sendable () -> Void) -> Void
    /// Reads the position the node has rendered, in frames of the active format, for one progress
    /// tick. It takes the node rather than capturing it so a caller can state a rendered position
    /// instead of depending on live audio output.
    private let renderedSampleTime: (AVAudioPlayerNode) -> AVAudioFramePosition?
    /// Schedules the repeating progress timer the manager built. Production adds it to the main run
    /// loop; a caller that keeps the timer instead can fire the manager's own callback where it
    /// wants a tick, rather than waiting the cadence out.
    private let progressTimerScheduler: (Timer) -> Void
    private let audioObservers: (processed: () -> Void, statePublished: () -> Void)
    private var progressTimer: Timer?
    /// Creates the audio graph. The buffer observer is notified after each buffer is passed to the node.
    /// The scheduler defers automatic playback after the first complete PCM frame. The rendered-sample-time
    /// reader supplies each progress tick its position, and the timer scheduler decides where the timer
    /// driving those ticks runs. The processing observer runs after the audio queue
    /// handles a packet, and the state observer runs after publication.
    init(sampleRate: Double = AudioPlayerManager.defaultSampleRate,
         scheduledBufferObserver: @escaping (AVAudioPCMBuffer) -> Void = { _ in },
         engineStarter: @escaping (AVAudioEngine) throws -> Void = { try $0.start() },
         automaticPlaybackScheduler: @escaping (TimeInterval, @escaping @Sendable () -> Void) -> Void = { delay, action in
             DispatchQueue.main.asyncAfter(
                 deadline: .now() + delay,
                 execute: action
             )
         },
         renderedSampleTimeReader: @escaping (AVAudioPlayerNode) -> AVAudioFramePosition? = { node in
             guard let nodeTime = node.lastRenderTime,
                   let playerTime = node.playerTime(forNodeTime: nodeTime) else { return nil }
             return playerTime.sampleTime
         },
         progressTimerScheduler: @escaping (Timer) -> Void = { timer in
             RunLoop.main.add(timer, forMode: .default)
         },
         audioDataProcessingObserver: @escaping () -> Void = {},
         audioStateObserver: @escaping () -> Void = {}) {
        self.scheduledBufferObserver = scheduledBufferObserver
        self.engineStarter = engineStarter
        self.automaticPlaybackScheduler = automaticPlaybackScheduler
        self.renderedSampleTime = renderedSampleTimeReader
        self.progressTimerScheduler = progressTimerScheduler
        self.audioObservers = (processed: audioDataProcessingObserver, statePublished: audioStateObserver)
        let hasValidInitialSampleRate = Self.isSupportedSampleRate(sampleRate)
        let initialSampleRate = hasValidInitialSampleRate ? sampleRate : Self.defaultSampleRate
        setupEngine(sampleRate: initialSampleRate)
        if !hasValidInitialSampleRate {
            hasValidSampleRateInput = false
            hasValidSampleRateConfiguration = false
            sampleRateError = "PCM sample rate must be a finite value from 8,000 to 48,000 Hz."
        }
    }
    private func setupEngine(sampleRate: Double) {
        engine.attach(playerNode)
        engine.attach(timePitch)
        guard let standardFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            sampleRateError = "Couldn't configure the PCM sample rate. Try again."
            return
        }
        self.sampleRate = sampleRate
        bufferQueue.sync {
            audioFormat = standardFormat
        }
        engine.connect(playerNode, to: timePitch, format: standardFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: standardFormat)
        do {
            try engineStarter(engine)
        } catch {
            hasValidSampleRateConfiguration = false
            sampleRateError = "Couldn't start audio playback. Try again."
        }
    }
    /// Changes the PCM sample rate after clearing all audio that was decoded with the previous format.
    @discardableResult
    func setSampleRate(_ sampleRate: Double) -> SampleRateUpdateResult {
        guard Self.isSupportedSampleRate(sampleRate) else {
            hasValidSampleRateInput = false
            hasValidSampleRateConfiguration = false
            sampleRateError = "PCM sample rate must be a finite value from 8,000 to 48,000 Hz."
            return .invalid
        }
        hasValidSampleRateInput = true
        let currentSampleRate = bufferQueue.sync { audioFormat?.sampleRate }
        guard currentSampleRate != sampleRate else {
            guard !engine.isRunning else {
                hasValidSampleRateConfiguration = true
                sampleRateError = nil
                return .unchanged
            }
            do {
                try engineStarter(engine)
                hasValidSampleRateConfiguration = true
                sampleRateError = nil
                return .unchanged
            } catch {
                hasValidSampleRateConfiguration = false
                sampleRateError = "Couldn't start audio playback. Try again."
                return .engineStartFailed
            }
        }
        stop()
        engine.stop()
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeInput(timePitch)
        engine.disconnectNodeOutput(timePitch)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            hasValidSampleRateConfiguration = false
            sampleRateError = "Couldn't configure the PCM sample rate. Try again."
            return .engineStartFailed
        }
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        bufferQueue.sync {
            audioFormat = format
        }
        self.sampleRate = sampleRate
        do {
            try engineStarter(engine)
            hasValidSampleRateConfiguration = true
            sampleRateError = nil
            return .updated
        } catch {
            hasValidSampleRateConfiguration = false
            sampleRateError = "Couldn't start audio playback. Try again."
            return .engineStartFailed
        }
    }

    /// Returns whether a PCM sample rate can be represented by the app's mono Int16 graph.
    static func isSupportedSampleRate(_ sampleRate: Double) -> Bool {
        sampleRate.isFinite && supportedSampleRateRange.contains(sampleRate)
    }

    /// Whether the current configuration can start a new PCM stream without misinterpreting its format.
    var isReadyForNewStream: Bool {
        hasValidSampleRateConfiguration && engine.isRunning
    }

    /// Converts a player-node sample time to elapsed seconds using the active PCM format.
    func progress(forRenderedSampleTime sampleTime: AVAudioFramePosition) -> Double? {
        let sampleRate = bufferQueue.sync { audioFormat?.sampleRate }
        guard let sampleRate else { return nil }
        return baseProgressOffset + Double(sampleTime) / sampleRate
    }

    func startNewStream() -> Int {
        stop()
        return bufferQueue.sync {
            scheduleGeneration += 1
            return scheduleGeneration
        }
    }

    func scheduleAudio(data: Data, streamGeneration: Int) {
        // Runs on the network delegate's background queue; serialize buffer access via bufferQueue.
        bufferQueue.async {
            defer { self.audioObservers.processed() }
            guard self.scheduleGeneration == streamGeneration else { return }
            guard let format = self.audioFormat else { return }

            self.pcmData.accumulated.append(data)
            self.pcmData.unprocessed.append(data)

            let bytesPerNetworkFrame = 2 // 16-bit PCM = 2 bytes per frame
            self.bufferedPCMFrameCount = self.pcmData.accumulated.count / bytesPerNetworkFrame
            let bufferedFrameCount = self.bufferedPCMFrameCount
            let frameCapacity = AVAudioFrameCount(self.pcmData.unprocessed.count / bytesPerNetworkFrame)
            guard frameCapacity > 0 else { return }

            let bytesToProcess = Int(frameCapacity) * bytesPerNetworkFrame
            let dataToProcess = self.pcmData.unprocessed.prefix(bytesToProcess)
            self.pcmData.unprocessed.removeFirst(bytesToProcess)

            guard let buffer = self.makePCMBuffer(from: dataToProcess, format: format, frameCapacity: frameCapacity) else { return }

            self.schedule(buffer)
            let shouldScheduleAutomaticPlayback = self.automaticPlaybackGeneration != streamGeneration
            if shouldScheduleAutomaticPlayback {
                self.automaticPlaybackGeneration = streamGeneration
                self.automaticPlaybackScheduler(Self.automaticPlaybackPrebufferDuration) { [weak self] in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        self.startAutomaticPlayback(streamGeneration: streamGeneration)
                    }
                }
            }

            DispatchQueue.main.async {
                guard self.bufferQueue.sync(execute: { self.scheduleGeneration == streamGeneration }) else { return }
                self.bufferDuration = Double(bufferedFrameCount) / format.sampleRate
                self.hasAudio = true
                self.audioObservers.statePublished()
            }
        }
    }

    func play() {
        if !engine.isRunning {
            do {
                try engineStarter(engine)
            } catch {
                hasValidSampleRateConfiguration = false
                sampleRateError = "Couldn't start audio playback. Try again."
                return
            }
        }

        if playbackProgress >= bufferDuration && bufferDuration > 0 {
            seek(to: 0.0)
        }
        playerNode.play()

        isPlaying = true
        startProgressTimer()
    }

    /// Pauses playback and revokes the current stream's pending automatic start.
    ///
    /// The deferred start only observes `isPlaying`, which pausing clears, so without recording the
    /// intent against the paused generation the prebuffer deadline would undo an explicit Pause.
    /// Binding it to `scheduleGeneration` keeps the revocation to the stream that was paused: a
    /// later stream begins from a new generation, and `play()` still resumes this one on demand.
    func pause() {
        bufferQueue.sync { automaticPlaybackSuppressedGeneration = scheduleGeneration }
        playerNode.pause()
        isPlaying = false
        stopProgressTimer()
    }

    func stop() {
        // Bump the generation and clear buffers first, then stop the node. bufferQueue is a serial
        // FIFO: any scheduleAudio block already queued runs before this sync block and may still call
        // playerNode.scheduleBuffer, but the following playerNode.stop() flushes that buffer. Blocks
        // queued after the bump fail the generation guard and drop. Reversing the order would let an
        // in-flight scheduleAudio schedule one buffer onto the node after it was stopped.
        bufferQueue.sync {
            scheduleGeneration += 1
            automaticPlaybackGeneration = nil
            automaticPlaybackSuppressedGeneration = nil
            pcmData.accumulated.removeAll()
            pcmData.unprocessed.removeAll()
            bufferedPCMFrameCount = 0
        }
        playerNode.stop()
        baseProgressOffset = 0.0

        let updatePublishedState: @Sendable () -> Void = {
            self.isPlaying = false
            self.hasAudio = false
            self.bufferDuration = 0.0
            self.playbackProgress = 0.0
        }
        if Thread.isMainThread {
            updatePublishedState()
        } else {
            DispatchQueue.main.async(execute: updatePublishedState)
        }
        stopProgressTimer()
    }

    /// Moves playback to a buffered position, clamping requests outside the available PCM range.
    /// Seeking to the end stops playback but preserves the buffered data for replay.
    func seek(to progress: Double) {
        let wasPlaying = isPlaying
        let requestedProgress = progress.isFinite ? progress : 0.0
        var clampedProgress = 0.0
        var reachedBufferEnd = false

        // Both scheduleAudio and seek manipulate the player node based on pcmData.accumulated. Keeping
        // those operations on bufferQueue means a seek runs after all earlier scheduling work, then
        // prevents it from surviving playerNode.stop() and being replayed alongside the seek buffer.
        bufferQueue.sync {
            guard let format = audioFormat else { return }
            let bytesPerNetworkFrame = 2
            let bufferedDuration = Double(bufferedPCMFrameCount) / format.sampleRate
            let frameOffset: Int
            if requestedProgress >= bufferedDuration {
                frameOffset = bufferedPCMFrameCount
            } else if requestedProgress <= 0.0 {
                frameOffset = 0
            } else {
                frameOffset = min(Int(requestedProgress * format.sampleRate), bufferedPCMFrameCount)
            }
            clampedProgress = Double(frameOffset) / format.sampleRate
            let byteOffset = frameOffset * bytesPerNetworkFrame
            let completeByteCount = bufferedPCMFrameCount * bytesPerNetworkFrame

            playerNode.stop()

            guard byteOffset < completeByteCount else {
                reachedBufferEnd = true
                automaticPlaybackSuppressedGeneration = scheduleGeneration
                return
            }

            let remainingData = pcmData.accumulated.subdata(in: byteOffset..<completeByteCount)
            let frameCapacity = AVAudioFrameCount(remainingData.count / bytesPerNetworkFrame)
            guard frameCapacity > 0,
                  let buffer = makePCMBuffer(from: remainingData, format: format, frameCapacity: frameCapacity) else { return }

            schedule(buffer)
            if wasPlaying {
                playerNode.play()
            }
        }

        playbackProgress = clampedProgress
        baseProgressOffset = clampedProgress

        guard reachedBufferEnd else { return }

        // playerNode.stop() above clears every scheduled buffer, while pcmData.accumulated is retained
        // for play() to seek back to zero and replay without requesting audio again.
        isPlaying = false
        stopProgressTimer()
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        playerNode.scheduleBuffer(buffer)
        scheduledBufferObserver(buffer)
    }

    private func makePCMBuffer(from data: Data, format: AVAudioFormat, frameCapacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        buffer.frameLength = frameCapacity
        data.withUnsafeBytes { rawBufferPointer in
            let int16Pointer = rawBufferPointer.bindMemory(to: Int16.self)
            if let floatChannelData = buffer.floatChannelData?[0] {
                for frame in 0..<Int(frameCapacity) {
                    floatChannelData[frame] = Float(int16Pointer[frame]) / 32768.0
                }
            }
        }
        return buffer
    }
}

/// Progress reporting: the repeating tick that turns the node's rendered position into the
/// published playback position, and the timer that drives it while a stream plays.
extension AudioPlayerManager {
    /// Publishes the position one progress tick has reached, reading the rendered sample time and
    /// applying it within a single main-queue turn.
    ///
    /// The read and the publication must stay in one turn. `seek` installs a new
    /// `baseProgressOffset` on the main queue, so a tick that deferred its update would add a
    /// position rendered before the seek to the offset that seek installed. That sum reports
    /// playback ahead of the position the user chose, and pauses the stream once it reaches the
    /// buffered end. Reaching that end on a tick of its own still pauses, which is how playback
    /// stops when the buffer runs out.
    func applyProgressTick() {
        guard let sampleTime = renderedSampleTime(playerNode),
              let newProgress = progress(forRenderedSampleTime: sampleTime) else { return }
        if newProgress > 0 && newProgress <= bufferDuration {
            playbackProgress = newProgress
        } else if newProgress > bufferDuration {
            playbackProgress = bufferDuration
        }
        if isPlaying && playbackProgress >= bufferDuration && bufferDuration > 0 {
            pause()
        }
    }

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = Timer(timeInterval: Self.progressTickInterval, repeats: true) { [weak self] _ in
            self?.applyProgressTick()
        }
        progressTimer = timer
        progressTimerScheduler(timer)
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}

private extension AudioPlayerManager {
    func startAutomaticPlayback(streamGeneration: Int) {
        let result = bufferQueue.sync { () -> (started: Bool, engineStartFailed: Bool) in
            guard scheduleGeneration == streamGeneration,
                  automaticPlaybackSuppressedGeneration != streamGeneration,
                  !isPlaying else { return (false, false) }
            if !engine.isRunning {
                do {
                    try engineStarter(engine)
                } catch {
                    return (false, true)
                }
            }
            playerNode.play()
            return (true, false)
        }
        guard result.started else {
            if result.engineStartFailed {
                hasValidSampleRateConfiguration = false
                sampleRateError = "Couldn't start audio playback. Try again."
            }
            return
        }
        isPlaying = true
        startProgressTimer()
    }
}
