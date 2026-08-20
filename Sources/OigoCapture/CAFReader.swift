import AudioToolbox
import AVFAudio
import Foundation
import OigoCore

public enum CAFReaderError: Error, CustomStringConvertible, Sendable {
    case initializeFailed(OSStatus)
    case readFailed(OSStatus)
    case closed

    public var description: String {
        switch self {
        case .initializeFailed(let status):
            "CAF reader could not open the session descriptor (status " + String(status) + ")"
        case .readFailed(let status):
            "CAF reader could not read audio (status " + String(status) + ")"
        case .closed:
            "CAF reader is closed"
        }
    }
}

public final class CAFReader: @unchecked Sendable {
    public let processingFormat: AVAudioFormat
    public let boundFileDescriptor: Int32

    private let descriptor: AudioFileDescriptor?
    private let io: DescriptorFileIO
    private let lock = NSLock()
    private var audioFile: AudioFileID?
    private var extAudioFile: ExtAudioFileRef?
    private var closed = false

    public init(descriptor: AudioFileDescriptor, ownsDescriptor: Bool = true) throws {
        self.boundFileDescriptor = descriptor.rawValue
        self.descriptor = ownsDescriptor ? descriptor : nil
        self.io = DescriptorFileIO(fd: descriptor.rawValue)

        var fileID: AudioFileID?
        let clientData = Unmanaged.passUnretained(io).toOpaque()
        let openStatus = AudioFileOpenWithCallbacks(
            clientData,
            descriptorFileReadProc,
            nil,
            descriptorFileGetSizeProc,
            nil,
            kAudioFileCAFType,
            &fileID
        )
        guard openStatus == noErr, let fileID else {
            throw CAFReaderError.initializeFailed(openStatus)
        }

        var extFile: ExtAudioFileRef?
        let wrapStatus = ExtAudioFileWrapAudioFileID(fileID, false, &extFile)
        guard wrapStatus == noErr, let extFile else {
            AudioFileClose(fileID)
            throw CAFReaderError.initializeFailed(wrapStatus)
        }

        var fileASBD = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = ExtAudioFileGetProperty(
            extFile,
            kExtAudioFileProperty_FileDataFormat,
            &asbdSize,
            &fileASBD
        )
        guard formatStatus == noErr else {
            ExtAudioFileDispose(extFile)
            AudioFileClose(fileID)
            throw CAFReaderError.initializeFailed(formatStatus)
        }

        let sampleRate = fileASBD.mSampleRate > 0 ? fileASBD.mSampleRate : 16_000
        guard let resolvedFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            ExtAudioFileDispose(extFile)
            AudioFileClose(fileID)
            throw CAFReaderError.initializeFailed(kAudioFileUnsupportedDataFormatError)
        }

        var clientASBD = resolvedFormat.streamDescription.pointee
        let clientSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let clientStatus = ExtAudioFileSetProperty(
            extFile,
            kExtAudioFileProperty_ClientDataFormat,
            clientSize,
            &clientASBD
        )
        guard clientStatus == noErr else {
            ExtAudioFileDispose(extFile)
            AudioFileClose(fileID)
            throw CAFReaderError.initializeFailed(clientStatus)
        }

        self.processingFormat = resolvedFormat
        self.audioFile = fileID
        self.extAudioFile = extFile
    }

    public func frameLength() throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let extFile = extAudioFile else {
            throw CAFReaderError.closed
        }
        var length: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        let status = ExtAudioFileGetProperty(
            extFile,
            kExtAudioFileProperty_FileLengthFrames,
            &size,
            &length
        )
        guard status == noErr else {
            throw CAFReaderError.readFailed(status)
        }
        return length
    }

    public func read(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let extFile = extAudioFile else {
            throw CAFReaderError.closed
        }
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: processingFormat,
                frameCapacity: frameCount
              ) else {
            throw CAFReaderError.readFailed(kAudioFileUnsupportedDataFormatError)
        }
        var frames = frameCount
        let status = ExtAudioFileRead(extFile, &frames, buffer.mutableAudioBufferList)
        guard status == noErr else {
            throw CAFReaderError.readFailed(status)
        }
        guard frames > 0 else {
            return nil
        }
        buffer.frameLength = frames
        return buffer
    }

    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let extFile = extAudioFile
        let fileID = audioFile
        extAudioFile = nil
        audioFile = nil
        lock.unlock()

        if let extFile {
            _ = ExtAudioFileDispose(extFile)
        }
        if let fileID {
            _ = AudioFileClose(fileID)
        }
        io.invalidate()
        descriptor?.close()
    }

    @_spi(Testing)
    public var usesPathExtensionInference: Bool {
        false
    }

    deinit {
        close()
    }
}
