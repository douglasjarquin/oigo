import Darwin
import Foundation
import OigoCore

@available(macOS 26.0, *)
public enum SavedAudioRetry {
    public static func audioURL(
        for session: DictationSession,
        liveFailure: Error
    ) throws -> URL {
        _ = liveFailure
        guard session.metadata.state == .failed || session.metadata.state == .interrupted else {
            throw TranscriptionError.invalidSessionState(session.metadata.state)
        }
        guard FileManager.default.fileExists(atPath: session.audioURL.path) else {
            throw TranscriptionError.malformedAudio(
                session.audioURL,
                "the saved CAF file does not exist"
            )
        }
        do {
            let directoryValues = try session.directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            let audioValues = try session.audioURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            let canonicalDirectory = session.directoryURL.resolvingSymlinksInPath().standardizedFileURL
            let canonicalAudio = session.audioURL.resolvingSymlinksInPath().standardizedFileURL
            guard directoryValues.isSymbolicLink != true,
                  audioValues.isSymbolicLink != true,
                  canonicalAudio.deletingLastPathComponent() == canonicalDirectory else {
                throw TranscriptionError.malformedAudio(
                    session.audioURL,
                    "the saved CAF path is not a regular session artifact"
                )
            }
            var fileInfo = stat()
            guard lstat(session.audioURL.path, &fileInfo) == 0,
                  (fileInfo.st_mode & S_IFMT) == S_IFREG else {
                throw TranscriptionError.malformedAudio(
                    session.audioURL,
                    "the saved CAF path is not a regular file"
                )
            }
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.malformedAudio(
                session.audioURL,
                "the saved CAF path could not be validated"
            )
        }
        return session.audioURL
    }

    public static func retry<T>(
        session: DictationSession,
        liveFailure: Error,
        transcribe: (URL) throws -> T
    ) throws -> T {
        try transcribe(audioURL(for: session, liveFailure: liveFailure))
    }
}
