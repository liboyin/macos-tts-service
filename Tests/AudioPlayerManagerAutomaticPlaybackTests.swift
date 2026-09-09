import XCTest
import AVFoundation
@testable import ClipboardTTSApp

final class AudioPlayerManagerAutomaticPlaybackTests: XCTestCase {

    func testAutomaticPlaybackBuffersPacketsUntilPrebufferDeadline() {
        // WHY: A short first network chunk must be retained while the startup prebuffer grows,
        // rather than being consumed before later chunks arrive.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let scheduledBuffers = ScheduledPCMBufferRecorder()
        let stateUpdates = AudioStateUpdateRecorder()
        let firstStateUpdate = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            scheduledBufferObserver: scheduledBuffers.record,
            automaticPlaybackScheduler: scheduler.schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let generation = player.startNewStream()

        player.scheduleAudio(data: Data(repeating: 0, count: 1_024), streamGeneration: generation)

        wait(for: [firstStateUpdate], timeout: 1.0)
        XCTAssertTrue(player.hasAudio)
        XCTAssertGreaterThan(player.bufferDuration, 0.0)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(scheduler.scheduledActionCount, 1)
        XCTAssertEqual(scheduler.scheduledDelays, [0.1])

        let secondStateUpdate = stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: Data(repeating: 0, count: 2_048), streamGeneration: generation)
        wait(for: [secondStateUpdate], timeout: 1.0)
        XCTAssertEqual(player.bufferDuration, Double(1_536) / 24_000.0, accuracy: 0.000_001)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(scheduler.scheduledActionCount, 1)
        XCTAssertEqual(scheduledBuffers.count, 2)
        XCTAssertEqual(scheduledBuffers.totalFrameCount, 1_536)

        scheduler.runNextAction()

        assertPlayingState(of: player, is: true)
    }

    func testAutomaticPlaybackDoesNotStartAfterStopBeforePrebufferDeadline() {
        // WHY: Clear Buffer maps to stop(), so an already-queued automatic start must never
        // resurrect playback after the user has discarded the stream.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let stateUpdates = AudioStateUpdateRecorder()
        let bufferedAudioState = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: scheduler.schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: generation)

        wait(for: [bufferedAudioState], timeout: 1.0)
        player.stop()
        scheduler.runNextAction()
        assertPlayingState(of: player, is: false)

        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasAudio)
        XCTAssertEqual(player.bufferDuration, 0.0)
    }

    func testAutomaticPlaybackDoesNotRestartAfterSeekingToPrebufferEnd() {
        // WHY: Seeking to the current end stops the node by design, so the pending automatic
        // start must respect that explicit user intent instead of publishing a false playing state.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let stateUpdates = AudioStateUpdateRecorder()
        let bufferedAudioState = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: scheduler.schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: generation)

        wait(for: [bufferedAudioState], timeout: 1.0)
        player.seek(to: player.bufferDuration)
        scheduler.runNextAction()

        assertPlayingState(of: player, is: false)
        XCTAssertTrue(player.hasAudio)
    }

    func testPauseBeforePrebufferDeadlineKeepsPlaybackPaused() {
        // WHY: The deferred start observes only isPlaying, which pausing clears, so an explicit
        // Pause taken inside the prebuffer window must revoke it instead of being reversed by it.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let stateUpdates = AudioStateUpdateRecorder()
        let bufferedAudioState = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: scheduler.schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: generation)

        wait(for: [bufferedAudioState], timeout: 1.0)
        player.play()
        XCTAssertTrue(player.isPlaying)
        player.pause()
        XCTAssertFalse(player.isPlaying)

        scheduler.runNextAction()

        assertPlayingState(of: player, is: false)
        XCTAssertTrue(player.hasAudio)
    }

    func testPlayResumesStreamWhosePendingAutomaticStartPauseRevoked() {
        // WHY: Revoking the pending automatic start must cost the user nothing but the automatic
        // start; the same stream still has to resume on demand.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let stateUpdates = AudioStateUpdateRecorder()
        let bufferedAudioState = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: scheduler.schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: generation)

        wait(for: [bufferedAudioState], timeout: 1.0)
        player.play()
        player.pause()
        scheduler.runNextAction()
        assertPlayingState(of: player, is: false)

        player.play()

        XCTAssertTrue(player.isPlaying)
        assertPlayingState(of: player, is: true)
    }

    func testAutomaticPlaybackStartsForStreamBegunAfterAPause() {
        // WHY: Pause revokes the automatic start of the stream it paused, not of the next one:
        // a later stream owns a new generation and must still start on its own prebuffer deadline.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let stateUpdates = AudioStateUpdateRecorder()
        let pausedStreamState = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: scheduler.schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let pausedGeneration = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: pausedGeneration)
        wait(for: [pausedStreamState], timeout: 1.0)
        player.play()
        player.pause()

        let nextGeneration = player.startNewStream()
        let nextStreamState = stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: nextGeneration)
        wait(for: [nextStreamState], timeout: 1.0)
        XCTAssertEqual(scheduler.scheduledActionCount, 2)

        scheduler.runNextAction()
        assertPlayingState(of: player, is: false)
        scheduler.runNextAction()

        assertPlayingState(of: player, is: true)
    }

    func testPausedStreamKeepsBufferingPCMUnderItsOwnGeneration() {
        // WHY: Pause revokes the pending automatic start, not the stream. The network keeps
        // delivering while the user is paused, so PCM scheduled under the paused generation must
        // still buffer for Resume. Revoking by retiring that generation instead would satisfy every
        // other pause regression here while silently discarding the rest of the audio.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let audioDataProcessing = AudioDataProcessingRecorder()
        let stateUpdates = AudioStateUpdateRecorder()
        let bufferedAudioState = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: scheduler.schedule,
            audioDataProcessingObserver: audioDataProcessing.record,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 1_024), streamGeneration: generation)
        wait(for: [bufferedAudioState], timeout: 1.0)
        let bufferDurationWhenPaused = player.bufferDuration

        player.play()
        player.pause()

        let laterPacketProcessed = audioDataProcessing.expectNextProcessing()
        player.scheduleAudio(data: Data(repeating: 0, count: 2_048), streamGeneration: generation)
        wait(for: [laterPacketProcessed], timeout: 1.0)
        scheduler.runNextAction()
        // Drains the main queue, so any publication the later packet enqueued has been applied, and
        // proves the released prebuffer deadline still cannot override the pause.
        assertPlayingState(of: player, is: false)

        XCTAssertGreaterThan(player.bufferDuration, bufferDurationWhenPaused)
        XCTAssertEqual(player.bufferDuration, Double(1_536) / 24_000.0, accuracy: 0.000_001)

        player.play()
        XCTAssertTrue(player.isPlaying)
    }

    func testAutomaticPlaybackFromReplacedGenerationCannotStartNewStream() {
        // WHY: A late callback from a replaced request must not start playback for audio that
        // belongs to a newer generation.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let stateUpdates = AudioStateUpdateRecorder()
        let firstStateUpdate = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: scheduler.schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let firstGeneration = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: firstGeneration)
        wait(for: [firstStateUpdate], timeout: 1.0)

        let secondGeneration = player.startNewStream()
        let secondStateUpdate = stateUpdates.expectNextUpdate()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: secondGeneration)
        wait(for: [secondStateUpdate], timeout: 1.0)
        XCTAssertEqual(scheduler.scheduledActionCount, 2)

        scheduler.runNextAction()
        assertPlayingState(of: player, is: false)

        scheduler.runNextAction()

        assertPlayingState(of: player, is: true)
    }

    func testAutomaticPlaybackDoesNotStartAfterFormatResetBeforePrebufferDeadline() {
        // WHY: A PCM format reset clears the scheduled node buffers, so its pending automatic
        // start must be invalidated instead of reviving audio decoded in the old format.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let stateUpdates = AudioStateUpdateRecorder()
        let bufferedAudioState = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: scheduler.schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: generation)

        wait(for: [bufferedAudioState], timeout: 1.0)
        XCTAssertEqual(player.setSampleRate(48_000), .updated)
        scheduler.runNextAction()
        assertPlayingState(of: player, is: false)

        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasAudio)
        XCTAssertEqual(player.bufferDuration, 0.0)
    }

    func testAutomaticPlaybackReportsEngineRestartFailure() {
        // WHY: A delayed start must retain play()'s engine-recovery behavior, or the UI could
        // claim playback is active while the audio engine cannot render the buffered PCM.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let engineStarter = FailingAudioEngineStarter()
        let stateUpdates = AudioStateUpdateRecorder()
        let bufferedAudioState = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            engineStarter: engineStarter.start,
            automaticPlaybackScheduler: scheduler.schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let generation = player.startNewStream()
        player.scheduleAudio(data: Data(repeating: 0, count: 2), streamGeneration: generation)

        wait(for: [bufferedAudioState], timeout: 1.0)
        scheduler.runNextAction()
        assertPlayingState(of: player, is: false)

        XCTAssertEqual(engineStarter.callCount, 2)
        XCTAssertFalse(player.hasValidSampleRateConfiguration)
        XCTAssertEqual(player.sampleRateError, "Couldn't start audio playback. Try again.")
    }

    func testAutomaticPlaybackWaitsForCompletePCMFrame() {
        // WHY: PCM can be split on an arbitrary byte boundary. The delay must begin when the
        // first playable frame exists, not when unusable partial data first arrives.
        let scheduler = ManualAutomaticPlaybackScheduler()
        let audioDataProcessing = AudioDataProcessingRecorder()
        let firstPacketProcessed = audioDataProcessing.expectNextProcessing()
        let stateUpdates = AudioStateUpdateRecorder()
        let firstStateUpdate = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: scheduler.schedule,
            audioDataProcessingObserver: audioDataProcessing.record,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let generation = player.startNewStream()

        player.scheduleAudio(data: Data([0]), streamGeneration: generation)
        wait(for: [firstPacketProcessed], timeout: 1.0)
        XCTAssertEqual(scheduler.scheduledActionCount, 0)

        player.scheduleAudio(data: Data([0]), streamGeneration: generation)
        wait(for: [firstStateUpdate], timeout: 1.0)

        XCTAssertTrue(player.hasAudio)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(scheduler.scheduledActionCount, 1)
    }

    private func assertPlayingState(of player: AudioPlayerManager, is expectedState: Bool) {
        let expectation = XCTestExpectation(description: "Delayed playback action is handled on the main queue")
        DispatchQueue.main.async {
            XCTAssertEqual(player.isPlaying, expectedState)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }
}
