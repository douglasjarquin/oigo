import AVFAudio
import Foundation

public enum AudioPlaybackError: Error, CustomStringConvertible, Sendable {
    case noPlayableFrames
    case startFailed

    public var description: String {
        switch self {
        case .noPlayableFrames:
            "audio file has no playable frames"
        case .startFailed:
            "playback could not start"
        }
    }
}

public enum AudioPlaybackTerminalOutcome: Equatable, Sendable {
    case completed
    case stopped
    case replaced
    case failed
    case shutdown
}

public struct AudioPlaybackState: Equatable, Sendable {
    public let generation: UInt64
    public let sessionID: UUID?
    public let isPlaying: Bool
    public let outcome: AudioPlaybackTerminalOutcome?

    public init(
        generation: UInt64,
        sessionID: UUID?,
        isPlaying: Bool,
        outcome: AudioPlaybackTerminalOutcome?
    ) {
        self.generation = generation
        self.sessionID = sessionID
        self.isPlaying = isPlaying
        self.outcome = outcome
    }
}

@_spi(Testing)
public protocol AudioPlaybackPerforming: AnyObject {
    func start() -> Bool
    func stop()
    func setFinishHandler(_ handler: @escaping @Sendable (AudioPlaybackTerminalOutcome) -> Void)
}

public final class AudioPlayback: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var performer: AudioPlaybackPerforming?
    private var sessionID: UUID?
    private var lastOutcome: AudioPlaybackTerminalOutcome?
    private var stateHandler: (@Sendable (AudioPlaybackState) -> Void)?

    public init() {}

    public var onStateChange: (@Sendable (AudioPlaybackState) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stateHandler
        }
        set {
            lock.lock()
            stateHandler = newValue
            lock.unlock()
        }
    }

    @_spi(Testing)
    public var activePlayerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return performer == nil ? 0 : 1
    }

    @_spi(Testing)
    public var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    @_spi(Testing)
    public var lastTerminalOutcome: AudioPlaybackTerminalOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return lastOutcome
    }

    @_spi(Testing)
    public var playingSessionID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return performer == nil ? nil : sessionID
    }

    public var hasActivePlayback: Bool {
        lock.lock()
        defer { lock.unlock() }
        return performer != nil
    }

    public func isPlaying(sessionID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return performer != nil && self.sessionID == sessionID
    }

    public func currentState() -> AudioPlaybackState {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    @discardableResult
    public func play(url: URL, sessionID: UUID? = nil) throws -> AVAudioFramePosition {
        let length: AVAudioFramePosition
        do {
            length = try Self.playableFrameLength(at: url)
        } catch {
            replaceActive()
            failCurrent()
            throw error
        }
        let performer: AudioPlaybackPerforming
        do {
            performer = try AVAudioPlayerPerformer(url: url)
        } catch {
            replaceActive()
            failCurrent()
            throw AudioPlaybackError.startFailed
        }
        try install(performer, sessionID: sessionID)
        return length
    }

    @_spi(Testing)
    @discardableResult
    public func play(
        sessionID: UUID? = nil,
        using performer: AudioPlaybackPerforming
    ) throws -> UInt64 {
        try install(performer, sessionID: sessionID)
        return currentGeneration
    }

    public func stop() {
        finish(outcome: .stopped)
    }

    public func shutdown() {
        finish(outcome: .shutdown)
    }

    @_spi(Testing)
    public func complete(generation expected: UInt64) {
        finish(generation: expected, outcome: .completed)
    }

    @_spi(Testing)
    public func fail(generation expected: UInt64) {
        finish(generation: expected, outcome: .failed)
    }

    public static func playableFrameLength(at url: URL) throws -> AVAudioFramePosition {
        let audioFile = try AVAudioFile(forReading: url)
        guard audioFile.length > 0 else {
            throw AudioPlaybackError.noPlayableFrames
        }
        return audioFile.length
    }

    private func install(
        _ performer: AudioPlaybackPerforming,
        sessionID: UUID?
    ) throws {
        let generation = replaceActive()
        performer.setFinishHandler { [weak self] outcome in
            self?.finish(generation: generation, outcome: outcome)
        }
        guard performer.start() else {
            failCurrent()
            throw AudioPlaybackError.startFailed
        }
        lock.lock()
        self.performer = performer
        self.sessionID = sessionID
        lastOutcome = nil
        let state = snapshotLocked()
        let handler = stateHandler
        lock.unlock()
        handler?(state)
    }

    @discardableResult
    private func replaceActive() -> UInt64 {
        lock.lock()
        let previous = performer
        performer = nil
        let previousSession = sessionID
        sessionID = nil
        let replacedGeneration = generation
        let handler: (@Sendable (AudioPlaybackState) -> Void)?
        let replacedState: AudioPlaybackState?
        if previous != nil {
            lastOutcome = .replaced
            replacedState = AudioPlaybackState(
                generation: replacedGeneration,
                sessionID: previousSession,
                isPlaying: false,
                outcome: .replaced
            )
            handler = stateHandler
        } else {
            replacedState = nil
            handler = nil
        }
        generation &+= 1
        let next = generation
        lock.unlock()
        previous?.stop()
        if let replacedState {
            handler?(replacedState)
        }
        return next
    }

    private func failCurrent() {
        finish(generation: currentGeneration, outcome: .failed)
    }

    private func finish(outcome: AudioPlaybackTerminalOutcome) {
        finish(generation: currentGeneration, outcome: outcome)
    }

    private func finish(
        generation expected: UInt64,
        outcome: AudioPlaybackTerminalOutcome
    ) {
        lock.lock()
        guard expected == generation else {
            lock.unlock()
            return
        }
        let current = performer
        guard current != nil || outcome == .failed else {
            lock.unlock()
            return
        }
        performer = nil
        sessionID = nil
        lastOutcome = outcome
        let state = snapshotLocked()
        let handler = stateHandler
        lock.unlock()
        current?.stop()
        handler?(state)
    }

    private func snapshotLocked() -> AudioPlaybackState {
        AudioPlaybackState(
            generation: generation,
            sessionID: performer == nil ? nil : sessionID,
            isPlaying: performer != nil,
            outcome: performer == nil ? lastOutcome : nil
        )
    }
}

@_spi(Testing)
public final class ControllableAudioPlaybackPerformer: AudioPlaybackPerforming, @unchecked Sendable {
    public var startShouldFail = false
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    private let lock = NSLock()
    private var finishHandler: (@Sendable (AudioPlaybackTerminalOutcome) -> Void)?

    public init() {}

    public func start() -> Bool {
        lock.lock()
        startCount += 1
        let shouldFail = startShouldFail
        lock.unlock()
        return !shouldFail
    }

    public func stop() {
        lock.lock()
        stopCount += 1
        lock.unlock()
    }

    public func setFinishHandler(
        _ handler: @escaping @Sendable (AudioPlaybackTerminalOutcome) -> Void
    ) {
        lock.lock()
        finishHandler = handler
        lock.unlock()
    }

    public func finishNaturally() {
        lock.lock()
        let handler = finishHandler
        lock.unlock()
        handler?(.completed)
    }

    public func failDecode() {
        lock.lock()
        let handler = finishHandler
        lock.unlock()
        handler?(.failed)
    }
}

private final class AVAudioPlayerPerformer: NSObject, AVAudioPlayerDelegate, AudioPlaybackPerforming {
    private let player: AVAudioPlayer
    private var finishHandler: (@Sendable (AudioPlaybackTerminalOutcome) -> Void)?

    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
    }

    func start() -> Bool {
        player.prepareToPlay()
        return player.play()
    }

    func stop() {
        player.delegate = nil
        player.stop()
    }

    func setFinishHandler(
        _ handler: @escaping @Sendable (AudioPlaybackTerminalOutcome) -> Void
    ) {
        finishHandler = handler
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        _ = player
        _ = flag
        finishHandler?(.completed)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        _ = player
        _ = error
        finishHandler?(.failed)
    }
}
