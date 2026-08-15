import Darwin
import AVFAudio
import Foundation
import OigoCore

@available(macOS 26.0, *)
final class SecuredAudioFile: @unchecked Sendable {
    let file: AVAudioFile
    let byteCount: Int64
    private let fileDescriptor: AudioFileDescriptor

    init(file: AVAudioFile, byteCount: Int64, fileDescriptor: AudioFileDescriptor) {
        self.file = file
        self.byteCount = byteCount
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        fileDescriptor.close()
    }
}

@available(macOS 26.0, *)
public enum SavedAudioRetry {
    static func openAudioFile(
        for session: DictationSession,
        store: SessionStore,
        liveFailure: Error
    ) throws -> SecuredAudioFile {
        _ = liveFailure
        guard session.metadata.state == .failed
            || session.metadata.state == .interrupted
            || session.metadata.state == .retrying else {
            throw TranscriptionError.invalidSessionState(session.metadata.state)
        }
        let url = session.audioURL
        let fileDescriptor: AudioFileDescriptor
        do {
            fileDescriptor = try store.openAudioFileDescriptor(for: session)
        } catch {
            throw TranscriptionError.malformedAudio(
                url,
                "the saved CAF file could not be opened as a session artifact"
            )
        }

        var fileInfo = stat()
        guard Darwin.fstat(fileDescriptor.rawValue, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            fileDescriptor.close()
            throw TranscriptionError.malformedAudio(
                url,
                "the saved CAF file is not a regular file"
            )
        }
        do {
            let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(fileDescriptor.rawValue)")
            let file = try AVAudioFile(forReading: descriptorURL)
            return SecuredAudioFile(
                file: file,
                byteCount: Int64(fileInfo.st_size),
                fileDescriptor: fileDescriptor
            )
        } catch {
            fileDescriptor.close()
            throw TranscriptionError.malformedAudio(url, String(describing: error))
        }
    }

    @_spi(Testing)
    public static func retry<T>(
        session: DictationSession,
        store: SessionStore,
        liveFailure: Error,
        transcribe: (AudioFileDescriptor) throws -> T
    ) throws -> T {
        _ = liveFailure
        guard session.metadata.state == .failed
            || session.metadata.state == .interrupted
            || session.metadata.state == .retrying else {
            throw TranscriptionError.invalidSessionState(session.metadata.state)
        }
        let descriptor: AudioFileDescriptor
        do {
            descriptor = try store.openAudioFileDescriptor(for: session)
        } catch {
            throw TranscriptionError.malformedAudio(
                session.audioURL,
                "the saved CAF file could not be opened as a session artifact"
            )
        }
        defer { descriptor.close() }
        return try transcribe(descriptor)
    }
}
