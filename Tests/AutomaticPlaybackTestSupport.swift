import XCTest
import AVFoundation
@testable import ClipboardTTSApp

// Test doubles shared by the audio-manager suites. They live here rather than beside one suite so
// either can drive the 0.1-second automatic-playback prebuffer deterministically: the scheduler
// hands the deferred start back to the test, and the recorders turn the manager's processing and
// publication hooks into explicit completion instead of an elapsed-time wait.

final class AudioDataProcessingRecorder {
    private let lock = NSLock()
    private var pendingExpectations: [XCTestExpectation] = []

    func expectNextProcessing() -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Audio queue finishes processing a network packet")
        lock.lock()
        pendingExpectations.append(expectation)
        lock.unlock()
        return expectation
    }

    func record() {
        lock.lock()
        let expectation = pendingExpectations.isEmpty ? nil : pendingExpectations.removeFirst()
        lock.unlock()
        expectation?.fulfill()
    }
}

final class FailingAudioEngineStarter {
    private(set) var callCount = 0

    func start(_: AVAudioEngine) throws {
        callCount += 1
        throw TestAudioEngineStartError.failed
    }
}

enum TestAudioEngineStartError: Error {
    case failed
}

final class ManualAutomaticPlaybackScheduler {
    private let lock = NSLock()
    private var actions: [() -> Void] = []
    private var delays: [TimeInterval] = []

    var scheduledActionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return actions.count
    }

    var scheduledDelays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return delays
    }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        lock.lock()
        delays.append(delay)
        actions.append(action)
        lock.unlock()
    }

    func runNextAction() {
        lock.lock()
        let action = actions.removeFirst()
        lock.unlock()
        action()
    }
}

final class ScheduledPCMBufferRecorder {
    private let lock = NSLock()
    private var bufferCount = 0
    private var frameCount: AVAudioFrameCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return bufferCount
    }

    var totalFrameCount: AVAudioFrameCount {
        lock.lock()
        defer { lock.unlock() }
        return frameCount
    }

    func record(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        bufferCount += 1
        frameCount += buffer.frameLength
        lock.unlock()
    }
}

final class AudioStateUpdateRecorder {
    private let lock = NSLock()
    private var pendingExpectations: [XCTestExpectation] = []

    func expectNextUpdate() -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Buffered-audio state is published")
        lock.lock()
        pendingExpectations.append(expectation)
        lock.unlock()
        return expectation
    }

    func record() {
        lock.lock()
        let expectation = pendingExpectations.isEmpty ? nil : pendingExpectations.removeFirst()
        lock.unlock()
        expectation?.fulfill()
    }
}
