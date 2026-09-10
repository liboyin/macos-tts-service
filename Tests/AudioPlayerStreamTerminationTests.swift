import XCTest
@testable import ClipboardTTSApp

/// Records what the player had published at the moment of each publication.
///
/// Reading the final state cannot separate an ending applied behind a stream's audio from one
/// applied ahead of it, because both settle the same way. Sampling at every publication is what
/// turns that ordering into something a test observes rather than infers.
final class PlaybackPublicationRecorder: @unchecked Sendable {
    /// One publication, reduced to the two properties whose relative order this suite protects.
    struct Snapshot: Equatable {
        let hasAudio: Bool
        let termination: SpeechStreamTermination?
    }

    private let lock = NSLock()
    private var snapshots: [Snapshot] = []
    private var observed: AudioPlayerManager?

    /// Names the player to sample. Set before any work is scheduled, so no publication precedes it.
    func observe(_ player: AudioPlayerManager) {
        lock.lock()
        observed = player
        lock.unlock()
    }

    func record() {
        lock.lock()
        let player = observed
        lock.unlock()
        guard let player else { return }
        let snapshot = Snapshot(hasAudio: player.hasAudio, termination: player.streamTermination)
        lock.lock()
        snapshots.append(snapshot)
        lock.unlock()
    }

    var recorded: [Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }
}

/// What the player records when the request feeding a stream ends: whose stream it was, where the
/// record sits relative to that stream's PCM, and when it is withdrawn.
final class AudioPlayerStreamTerminationTests: XCTestCase {

    func testAStreamsEndingIsAppliedBehindTheAudioThatStreamDelivered() {
        // WHY: The record has to describe a buffered stream, not one still being buffered. An
        // ending applied ahead of PCM the same request delivered would mark a stream complete while
        // audio it accepted was still queued, which is exactly the state underrun recovery has to
        // be able to trust. The buffer queue is what provides that order, so the record must join
        // it rather than publish straight to the main queue.
        let publications = PlaybackPublicationRecorder()
        let stateUpdates = AudioStateUpdateRecorder()
        let audioPublished = stateUpdates.expectNextUpdate()
        let endingPublished = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: ManualAutomaticPlaybackScheduler().schedule,
            audioStateObserver: { publications.record(); stateUpdates.record() }
        )
        publications.observe(player)
        defer { player.stop() }
        let generation = player.startNewStream()

        player.scheduleAudio(data: Data(repeating: 0, count: 2_048), streamGeneration: generation)
        player.finishStream(streamGeneration: generation, termination: .finished)

        wait(for: [audioPublished, endingPublished], timeout: 2.0)
        XCTAssertEqual(
            publications.recorded,
            [
                PlaybackPublicationRecorder.Snapshot(hasAudio: true, termination: nil),
                PlaybackPublicationRecorder.Snapshot(hasAudio: true, termination: .finished)
            ],
            "The stream's PCM must already be published when its ending is."
        )
        XCTAssertGreaterThan(player.bufferDuration, 0.0)
    }

    func testAnEndingForASupersededStreamIsDropped() {
        // WHY: A terminal event that outlives its stream would tell the session that replaced it
        // that its own request had ended, closing a stream still being filled. Generation ownership
        // is the only thing separating the two, exactly as it is for scheduled audio. This is the
        // stream that was already superseded when its ending arrived; the test below covers the
        // narrower window where it is superseded after that and before the ending publishes.
        let processing = AudioDataProcessingRecorder()
        let endingHandled = processing.expectNextProcessing()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: ManualAutomaticPlaybackScheduler().schedule,
            audioDataProcessingObserver: processing.record
        )
        defer { player.stop() }
        let supersededGeneration = player.startNewStream()
        let currentGeneration = player.startNewStream()
        XCTAssertNotEqual(supersededGeneration, currentGeneration)

        player.finishStream(streamGeneration: supersededGeneration, termination: .failed)

        wait(for: [endingHandled], timeout: 2.0)
        drainMainQueueTurn()
        XCTAssertNil(player.streamTermination, "The replacing stream must not inherit its predecessor's ending.")
    }

    func testAnEndingIsWithheldWhenAReplacementLandsBeforeItPublishes() {
        // WHY: An ending crosses two queues before it is published, and it can be superseded in
        // between. The check that matters is therefore the one at publication: a stream still
        // current when its ending reaches the buffer queue can be replaced before that ending
        // publishes, and the replacing stream would otherwise inherit its predecessor's ending and
        // look finished before its request had sent a byte. Ordering, not timing, holds this still
        // — `startNewStream()` enters the buffer queue synchronously, so the ending's own turn
        // there has already run by the time the replacement retires the generation, while this test
        // still owns the main queue and the publication it queued cannot have run.
        let stateUpdates = AudioStateUpdateRecorder()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: ManualAutomaticPlaybackScheduler().schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let replacedGeneration = player.startNewStream()

        player.finishStream(streamGeneration: replacedGeneration, termination: .finished)
        _ = player.startNewStream()

        drainMainQueueTurn()
        XCTAssertNil(
            player.streamTermination,
            "An ending accepted for a stream that was replaced before it published must not be published."
        )
    }

    func testAFailedRequestIsRecordedAsSuchRatherThanAsAFinishedOne() {
        // WHY: The two endings are not interchangeable. Speech that stopped because the request
        // broke leaves the user something to retry; speech that finished does not. Collapsing them
        // would make the record useless to anything that has to tell them apart.
        let stateUpdates = AudioStateUpdateRecorder()
        let endingPublished = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: ManualAutomaticPlaybackScheduler().schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let generation = player.startNewStream()

        player.finishStream(streamGeneration: generation, termination: .failed)

        wait(for: [endingPublished], timeout: 2.0)
        XCTAssertEqual(player.streamTermination, .failed)
    }

    func testStartingANewStreamClearsTheEndingOfThePreviousOne() {
        // WHY: A new session has to begin looking open. Inheriting the previous stream's ending
        // would report a stream as finished before its request has sent a single byte.
        let stateUpdates = AudioStateUpdateRecorder()
        let endingPublished = stateUpdates.expectNextUpdate()
        let player = AudioPlayerManager(
            automaticPlaybackScheduler: ManualAutomaticPlaybackScheduler().schedule,
            audioStateObserver: stateUpdates.record
        )
        defer { player.stop() }
        let finishedGeneration = player.startNewStream()
        player.finishStream(streamGeneration: finishedGeneration, termination: .finished)
        wait(for: [endingPublished], timeout: 2.0)
        XCTAssertEqual(player.streamTermination, .finished)

        _ = player.startNewStream()

        XCTAssertNil(player.streamTermination, "A new stream must start open rather than already ended.")
    }

    /// Runs one main-queue turn, so an absence assertion follows any publication already queued.
    private func drainMainQueueTurn() {
        let drained = expectation(description: "The main queue completed a turn")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2.0)
    }
}
