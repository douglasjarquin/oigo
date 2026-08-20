import AudioToolbox
import Darwin
import Foundation

final class DescriptorFileIO: @unchecked Sendable {
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

func descriptorFileReadProc(
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

func descriptorFileWriteProc(
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

func descriptorFileGetSizeProc(inClientData: UnsafeMutableRawPointer) -> Int64 {
    let io = Unmanaged<DescriptorFileIO>.fromOpaque(inClientData).takeUnretainedValue()
    return io.size()
}

func descriptorFileSetSizeProc(
    inClientData: UnsafeMutableRawPointer,
    inSize: Int64
) -> OSStatus {
    let io = Unmanaged<DescriptorFileIO>.fromOpaque(inClientData).takeUnretainedValue()
    return io.setSize(inSize)
}
