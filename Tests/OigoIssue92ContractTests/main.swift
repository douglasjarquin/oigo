import AVFAudio
import Foundation
@_spi(Testing) import OigoCapture

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
@MainActor
private struct OigoIssue92ContractTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("stop-before-start", testStopBeforeStart),
            ("natural-completion-releases-player", testNaturalCompletionReleasesPlayer),
            ("explicit-stop-releases-player", testExplicitStopReleasesPlayer),
            ("replacement-releases-previous", testReplacementReleasesPrevious),
            ("empty-audio-releases-player", testEmptyAudioReleasesPlayer),
            ("start-failure-releases-player", testStartFailureReleasesPlayer),
            ("main-actor-performer-preserves-lifecycle", testMainActorPerformerPreservesLifecycle),
            ("late-callback-cannot-clear-successor", testLateCallbackCannotClearSuccessor),
            ("stop-after-completion-is-idempotent", testStopAfterCompletionIsIdempotent),
            ("repeated-stop-is-idempotent", testRepeatedStopIsIdempotent),
            ("shutdown-releases-player", testShutdownReleasesPlayer),
            ("one-hundred-cycles-release-every-player", testOneHundredCyclesReleaseEveryPlayer),
            ("state-callback-without-polling", testStateCallbackWithoutPolling),
            ("same-session-identity-is-toggleable", testSameSessionIdentityIsToggleable)
        ]

        let requested = Set(CommandLine.arguments.dropFirst())
        let selected = requested.isEmpty ? tests : tests.filter { requested.contains($0.0) }
        guard selected.count == (requested.isEmpty ? tests.count : requested.count) else {
            print("FAIL: unknown issue #92 contract scenario")
            exit(2)
        }

        var failures = 0
        for (name, test) in selected {
            do {
                try test()
                print("GREEN: issue #92 " + name)
            } catch {
                failures += 1
                print("FAIL: issue #92 " + name + ": " + String(describing: error))
            }
        }

        if failures > 0 {
            print("FAILURES=" + String(failures))
            exit(1)
        }
        print("GREEN: all issue #92 contract scenarios")
    }

    private static func testStopBeforeStart() throws {
        let playback = AudioPlayback()
        playback.stop()
        playback.stop()
        guard playback.activePlayerCount == 0,
              playback.currentGeneration == 0,
              playback.lastTerminalOutcome == nil,
              playback.playingSessionID == nil else {
            throw ContractFailure(message: "stop before start retained a player or invented an outcome")
        }
    }

    private static func testNaturalCompletionReleasesPlayer() throws {
        let playback = AudioPlayback()
        let performer = ControllableAudioPlaybackPerformer()
        let generation = try playback.play(using: performer)
        guard playback.activePlayerCount == 1,
              playback.lastTerminalOutcome == nil,
              performer.startCount == 1 else {
            throw ContractFailure(message: "playback did not retain the active performer")
        }
        performer.finishNaturally()
        guard playback.activePlayerCount == 0,
              playback.currentGeneration == generation,
              playback.lastTerminalOutcome == .completed,
              performer.stopCount == 1,
              playback.playingSessionID == nil else {
            throw ContractFailure(message: "natural completion did not release the player")
        }
    }

    private static func testExplicitStopReleasesPlayer() throws {
        let playback = AudioPlayback()
        let performer = ControllableAudioPlaybackPerformer()
        _ = try playback.play(using: performer)
        playback.stop()
        guard playback.activePlayerCount == 0,
              playback.lastTerminalOutcome == .stopped,
              performer.stopCount == 1 else {
            throw ContractFailure(message: "explicit stop did not release the player")
        }
    }

    private static func testReplacementReleasesPrevious() throws {
        let playback = AudioPlayback()
        let first = ControllableAudioPlaybackPerformer()
        let second = ControllableAudioPlaybackPerformer()
        let firstGeneration = try playback.play(using: first)
        let secondGeneration = try playback.play(using: second)
        guard firstGeneration != secondGeneration,
              playback.activePlayerCount == 1,
              playback.currentGeneration == secondGeneration,
              first.stopCount == 1,
              second.startCount == 1 else {
            throw ContractFailure(message: "replacement did not stop the previous performer")
        }
        first.finishNaturally()
        guard playback.activePlayerCount == 1,
              playback.currentGeneration == secondGeneration,
              playback.lastTerminalOutcome == nil else {
            throw ContractFailure(message: "replaced performer completion mutated the successor")
        }
        second.finishNaturally()
        guard playback.activePlayerCount == 0,
              playback.lastTerminalOutcome == .completed else {
            throw ContractFailure(message: "successor completion did not release the replacement player")
        }
    }

    private static func testStartFailureReleasesPlayer() throws {
        let playback = AudioPlayback()
        let previous = ControllableAudioPlaybackPerformer()
        _ = try playback.play(using: previous)
        let failing = ControllableAudioPlaybackPerformer()
        failing.startShouldFail = true
        do {
            _ = try playback.play(using: failing)
            throw ContractFailure(message: "failed start was treated as success")
        } catch AudioPlaybackError.startFailed {
        } catch {
            throw ContractFailure(message: "failed start returned an untyped outcome: \(error)")
        }
        guard playback.activePlayerCount == 0,
              playback.lastTerminalOutcome == .failed,
              previous.stopCount == 1,
              failing.startCount == 1,
              playback.playingSessionID == nil else {
            throw ContractFailure(message: "start failure leaked a player")
        }
    }

    private static func testEmptyAudioReleasesPlayer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue92-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("empty.caf")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            throw ContractFailure(message: "could not create the empty-audio fixture format")
        }
        _ = try AVAudioFile(forWriting: url, settings: format.settings)

        let playback = AudioPlayback()
        do {
            _ = try playback.play(url: url)
            throw ContractFailure(message: "empty audio was treated as playable")
        } catch AudioPlaybackError.noPlayableFrames {
        } catch let failure as ContractFailure {
            throw failure
        } catch {
            throw ContractFailure(message: "empty audio returned an untyped outcome: \(error)")
        }
        guard playback.activePlayerCount == 0,
              playback.lastTerminalOutcome == .failed,
              playback.playingSessionID == nil else {
            throw ContractFailure(message: "empty audio retained an active performer")
        }
    }

    private static func testMainActorPerformerPreservesLifecycle() throws {
        let playback = AudioPlayback()
        let performer = MainActorPlaybackPerformer()
        _ = try playback.play(using: performer)
        performer.finishNaturally()
        guard playback.activePlayerCount == 0,
              playback.lastTerminalOutcome == .completed,
              performer.startCount == 1,
              performer.stopCount == 1 else {
            throw ContractFailure(message: "main-actor performer did not preserve playback lifecycle")
        }
    }

    private static func testLateCallbackCannotClearSuccessor() throws {
        let playback = AudioPlayback()
        let first = ControllableAudioPlaybackPerformer()
        let second = ControllableAudioPlaybackPerformer()
        let firstGeneration = try playback.play(using: first)
        let secondGeneration = try playback.play(using: second)
        playback.complete(generation: firstGeneration)
        playback.fail(generation: firstGeneration)
        first.failDecode()
        guard playback.activePlayerCount == 1,
              playback.currentGeneration == secondGeneration,
              playback.playingSessionID == nil || playback.lastTerminalOutcome == nil else {
            throw ContractFailure(message: "late callback from player A cleared player B")
        }
        guard playback.activePlayerCount == 1 else {
            throw ContractFailure(message: "late callback released the successor")
        }
    }

    private static func testStopAfterCompletionIsIdempotent() throws {
        let playback = AudioPlayback()
        let performer = ControllableAudioPlaybackPerformer()
        _ = try playback.play(using: performer)
        performer.finishNaturally()
        playback.stop()
        playback.stop()
        guard playback.activePlayerCount == 0,
              playback.lastTerminalOutcome == .completed,
              performer.stopCount == 1 else {
            throw ContractFailure(message: "stop after completion changed the completed outcome")
        }
    }

    private static func testRepeatedStopIsIdempotent() throws {
        let playback = AudioPlayback()
        let performer = ControllableAudioPlaybackPerformer()
        _ = try playback.play(using: performer)
        playback.stop()
        playback.stop()
        playback.stop()
        guard playback.activePlayerCount == 0,
              playback.lastTerminalOutcome == .stopped,
              performer.stopCount == 1 else {
            throw ContractFailure(message: "repeated stop was not idempotent")
        }
    }

    private static func testShutdownReleasesPlayer() throws {
        let playback = AudioPlayback()
        let performer = ControllableAudioPlaybackPerformer()
        _ = try playback.play(using: performer)
        playback.shutdown()
        guard playback.activePlayerCount == 0,
              playback.lastTerminalOutcome == .shutdown,
              performer.stopCount == 1 else {
            throw ContractFailure(message: "shutdown did not release the player")
        }
        playback.shutdown()
        guard playback.lastTerminalOutcome == .shutdown else {
            throw ContractFailure(message: "repeated shutdown changed the terminal outcome")
        }
    }

    private static func testOneHundredCyclesReleaseEveryPlayer() throws {
        let playback = AudioPlayback()
        for index in 0..<100 {
            let performer = ControllableAudioPlaybackPerformer()
            _ = try playback.play(sessionID: UUID(), using: performer)
            if index.isMultiple(of: 2) {
                performer.finishNaturally()
            } else {
                playback.stop()
            }
            guard playback.activePlayerCount == 0 else {
                throw ContractFailure(message: "cycle \(index) leaked an active player")
            }
        }
        guard playback.activePlayerCount == 0 else {
            throw ContractFailure(message: "100 playback cycles leaked a player")
        }
    }

    private static func testStateCallbackWithoutPolling() throws {
        let playback = AudioPlayback()
        let outcomes = CallbackBox()
        playback.onStateChange = { state in
            outcomes.append(state)
        }
        let performer = ControllableAudioPlaybackPerformer()
        let sessionID = UUID()
        _ = try playback.play(sessionID: sessionID, using: performer)
        guard let started = outcomes.values.last,
              started.isPlaying,
              started.sessionID == sessionID,
              started.outcome == nil else {
            throw ContractFailure(message: "playback did not publish a start state callback")
        }
        performer.finishNaturally()
        guard let finished = outcomes.values.last,
              !finished.isPlaying,
              finished.outcome == .completed,
              finished.sessionID == nil else {
            throw ContractFailure(message: "playback did not publish a completion state callback")
        }
    }

    private static func testSameSessionIdentityIsToggleable() throws {
        let playback = AudioPlayback()
        let sessionID = UUID()
        let performer = ControllableAudioPlaybackPerformer()
        _ = try playback.play(sessionID: sessionID, using: performer)
        guard playback.isPlaying(sessionID: sessionID),
              !playback.isPlaying(sessionID: UUID()) else {
            throw ContractFailure(message: "playing session identity was not isolated")
        }
        playback.stop()
        guard !playback.isPlaying(sessionID: sessionID),
              playback.activePlayerCount == 0 else {
            throw ContractFailure(message: "stopped session still appeared to be playing")
        }
    }
}

@MainActor
private final class MainActorPlaybackPerformer: AudioPlaybackPerforming {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var finishHandler: (@MainActor @Sendable (AudioPlaybackTerminalOutcome) -> Void)?

    func start() -> Bool {
        startCount += 1
        return true
    }

    func stop() {
        stopCount += 1
    }

    func setFinishHandler(
        _ handler: @escaping @MainActor @Sendable (AudioPlaybackTerminalOutcome) -> Void
    ) {
        finishHandler = handler
    }

    func finishNaturally() {
        finishHandler?(.completed)
    }
}

private final class CallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [AudioPlaybackState] = []

    var values: [AudioPlaybackState] {
        lock.lock()
        defer { lock.unlock() }
        return states
    }

    func append(_ state: AudioPlaybackState) {
        lock.lock()
        states.append(state)
        lock.unlock()
    }
}
