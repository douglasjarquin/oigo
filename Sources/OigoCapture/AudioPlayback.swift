import AVFAudio
import Foundation

public enum AudioPlaybackError: Error, CustomStringConvertible, Sendable {
    case noPlayableFrames(URL)

    public var description: String {
        switch self {
        case .noPlayableFrames(let url):
            "audio file has no playable frames: " + url.path
        }
    }
}

public final class AudioPlayback: @unchecked Sendable {
    private let lock = NSLock()
    private var player: AVAudioPlayer?

    public init() {}

    @discardableResult
    public func play(url: URL) throws -> AVAudioFramePosition {
        let audioFile = try AVAudioFile(forReading: url)
        guard audioFile.length > 0 else {
            throw AudioPlaybackError.noPlayableFrames(url)
        }
        let player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        player.play()
        lock.lock()
        self.player = player
        lock.unlock()
        return audioFile.length
    }

    public func stop() {
        lock.lock()
        let player = self.player
        self.player = nil
        lock.unlock()
        player?.stop()
    }

    public static func playableFrameLength(at url: URL) throws -> AVAudioFramePosition {
        let audioFile = try AVAudioFile(forReading: url)
        guard audioFile.length > 0 else {
            throw AudioPlaybackError.noPlayableFrames(url)
        }
        return audioFile.length
    }
}
