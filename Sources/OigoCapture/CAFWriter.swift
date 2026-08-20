import AudioToolbox
import AVFAudio
import Darwin
import Foundation
import OigoCore

public enum CAFWriterError: Error, CustomStringConvertible, Sendable {
    case invalidFormat
    case initializeFailed(OSStatus)
    case writeFailed(OSStatus)
    case closed

    public var description: String {
        switch self {
        case .invalidFormat:
            "canonical mono audio format is unavailable"
        case .initializeFailed(let status):
            "CAF writer could not initialize on the session descriptor (status " + String(status) + ")"
        case .writeFailed(let status):
            "CAF writer could not store audio (status " + String(status) + ")"
        case .closed:
            "CAF writer is closed"
        }
    }
}

public protocol CanonicalAudioWriting: AnyObject {
    func writeCanonicalMono(samples: UnsafePointer<Float>, frameCount: Int) throws
    func close()
}

public final class CAFWriter: CanonicalAudioWriting, @unchecked Sendable {
    public static let fileType: AudioFileTypeID = kAudioFileCAFType

    public let boundFileDescriptor: Int32
    public let processingFormat: AVAudioFormat

    private let descriptor: AudioFileDescriptor
    private let io: DescriptorFileIO
    private let lock = NSLock()
    private var audioFile: AudioFileID?
    private var extAudioFile: ExtAudioFileRef?
    private var closed = false

    public init(descriptor: AudioFileDescriptor, format: AVAudioFormat) throws {
        guard format.channelCount == 1,
              format.sampleRate.isFinite,
              format.sampleRate > 0 else {
            throw CAFWriterError.invalidFormat
        }
        let processingFormat: AVAudioFormat
        if format.commonFormat == .pcmFormatFloat32 {
            processingFormat = format
        } else if let canonical = AVAudioFormat(
            standardFormatWithSampleRate: format.sampleRate,
            channels: 1
        ) {
            processingFormat = canonical
        } else {
            throw CAFWriterError.invalidFormat
        }

        self.descriptor = descriptor
        self.boundFileDescriptor = descriptor.rawValue
        self.processingFormat = processingFormat
        self.io = DescriptorFileIO(fd: descriptor.rawValue)

        var fileASBD = AudioStreamBasicDescription(
            mSampleRate: processingFormat.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var fileID: AudioFileID?
        let clientData = Unmanaged.passUnretained(io).toOpaque()
        let initializeStatus = AudioFileInitializeWithCallbacks(
            clientData,
            cafWriterReadProc,
            cafWriterWriteProc,
            cafWriterGetSizeProc,
            cafWriterSetSizeProc,
            kAudioFileCAFType,
            &fileASBD,
            [],
            &fileID
        )
        guard initializeStatus == noErr, let fileID else {
            throw CAFWriterError.initializeFailed(initializeStatus)
        }

        var extFile: ExtAudioFileRef?
        let wrapStatus = ExtAudioFileWrapAudioFileID(fileID, true, &extFile)
        guard wrapStatus == noErr, let extFile else {
            AudioFileClose(fileID)
            throw CAFWriterError.initializeFailed(wrapStatus)
        }

        var clientASBD = fileASBD
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
            throw CAFWriterError.initializeFailed(clientStatus)
        }

        self.audioFile = fileID
        self.extAudioFile = extFile
    }

    public func write(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.format.channelCount == 1 else {
            throw CAFWriterError.invalidFormat
        }
        guard buffer.frameLength > 0 else {
            return
        }
        if let samples = buffer.floatChannelData?.pointee {
            try writeCanonicalMono(samples: samples, frameCount: Int(buffer.frameLength))
            return
        }
        try writeBufferList(buffer.audioBufferList, frameCount: buffer.frameLength)
    }

    public func writeCanonicalMono(samples: UnsafePointer<Float>, frameCount: Int) throws {
        guard frameCount > 0 else {
            return
        }
        let buffer = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(mutating: samples)
        )
        var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
        try writeBufferList(&bufferList, frameCount: AVAudioFrameCount(frameCount))
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
        descriptor.close()
    }

    @_spi(Testing)
    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    @_spi(Testing)
    public var usesPathExtensionInference: Bool {
        false
    }

    deinit {
        close()
    }

    private func writeBufferList(
        _ bufferList: UnsafePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let extFile = extAudioFile else {
            throw CAFWriterError.closed
        }
        let status = ExtAudioFileWrite(extFile, frameCount, bufferList)
        guard status == noErr else {
            throw CAFWriterError.writeFailed(status)
        }
    }
}

private final class DescriptorFileIO: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var invalidated = false

    init(fd: Int32) {
        self.fd = fd
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    func read(
        position: Int64,
        requestCount: UInt32,
        buffer: UnsafeMutableRawPointer,
        actualCount: UnsafeMutablePointer<UInt32>
    ) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else {
            actualCount.pointee = 0
            return kAudioFileNotOpenError
        }
        let readCount = pread(fd, buffer, Int(requestCount), off_t(position))
        guard readCount >= 0 else {
            actualCount.pointee = 0
            return kAudioFileUnspecifiedError
        }
        actualCount.pointee = UInt32(readCount)
        return noErr
    }

    func write(
        position: Int64,
        requestCount: UInt32,
        buffer: UnsafeRawPointer,
        actualCount: UnsafeMutablePointer<UInt32>
    ) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else {
            actualCount.pointee = 0
            return kAudioFileNotOpenError
        }
        let writeCount = pwrite(fd, buffer, Int(requestCount), off_t(position))
        guard writeCount >= 0 else {
            actualCount.pointee = 0
            return kAudioFileUnspecifiedError
        }
        actualCount.pointee = UInt32(writeCount)
        return noErr
    }

    func size() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else {
            return 0
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            return 0
        }
        return Int64(info.st_size)
    }

    func setSize(_ size: Int64) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else {
            return kAudioFileNotOpenError
        }
        guard ftruncate(fd, off_t(size)) == 0 else {
            return kAudioFileUnspecifiedError
        }
        return noErr
    }
}

private func cafWriterReadProc(
    inClientData: UnsafeMutableRawPointer,
    inPosition: Int64,
    requestCount: UInt32,
    buffer: UnsafeMutableRawPointer,
    actualCount: UnsafeMutablePointer<UInt32>
) -> OSStatus {
    let io = Unmanaged<DescriptorFileIO>.fromOpaque(inClientData).takeUnretainedValue()
    return io.read(
        position: inPosition,
        requestCount: requestCount,
        buffer: buffer,
        actualCount: actualCount
    )
}

private func cafWriterWriteProc(
    inClientData: UnsafeMutableRawPointer,
    inPosition: Int64,
    requestCount: UInt32,
    buffer: UnsafeRawPointer,
    actualCount: UnsafeMutablePointer<UInt32>
) -> OSStatus {
    let io = Unmanaged<DescriptorFileIO>.fromOpaque(inClientData).takeUnretainedValue()
    return io.write(
        position: inPosition,
        requestCount: requestCount,
        buffer: buffer,
        actualCount: actualCount
    )
}

private func cafWriterGetSizeProc(inClientData: UnsafeMutableRawPointer) -> Int64 {
    let io = Unmanaged<DescriptorFileIO>.fromOpaque(inClientData).takeUnretainedValue()
    return io.size()
}

private func cafWriterSetSizeProc(
    inClientData: UnsafeMutableRawPointer,
    inSize: Int64
) -> OSStatus {
    let io = Unmanaged<DescriptorFileIO>.fromOpaque(inClientData).takeUnretainedValue()
    return io.setSize(inSize)
}
