import AVFAudio
import Foundation
import OigoCore

public enum CanonicalMonoAdapterError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidSourceFormat
    case selectedChannelOutOfRange(selected: Int, channelCount: Int)
    case unsupportedLayout(String)
    case conversionFailed(String)

    public var description: String {
        switch self {
        case .invalidSourceFormat:
            "microphone input format is unavailable"
        case .selectedChannelOutOfRange(_, _):
            "the selected input channel is not available on this microphone; choose another channel in Settings"
        case .unsupportedLayout(let reason):
            "microphone input layout is unsupported: " + reason
        case .conversionFailed(let reason):
            "microphone input could not be converted to canonical mono: " + reason
        }
    }
}

public final class CanonicalMonoAdapter: @unchecked Sendable {
    public static let floatPassthroughTolerance: Float = 0
    public static let integerConversionTolerance: Float = 1.0 / 32_768.0

    public let sourceFormat: AVAudioFormat
    public let selectedChannel: Int
    public let outputFormat: AVAudioFormat

    public init(sourceFormat: AVAudioFormat, selectedChannel: Int) throws {
        guard sourceFormat.sampleRate.isFinite,
              sourceFormat.sampleRate > 0,
              sourceFormat.channelCount > 0 else {
            throw CanonicalMonoAdapterError.invalidSourceFormat
        }
        switch sourceFormat.commonFormat {
        case .pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32:
            break
        default:
            throw CanonicalMonoAdapterError.unsupportedLayout(
                "sample format is not a supported linear PCM layout"
            )
        }
        let channelCount = Int(sourceFormat.channelCount)
        guard OigoInputChannelPolicy.isValid(selectedChannel, channelCount: channelCount) else {
            throw CanonicalMonoAdapterError.selectedChannelOutOfRange(
                selected: selectedChannel,
                channelCount: channelCount
            )
        }
        guard let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: sourceFormat.sampleRate,
            channels: 1
        ) else {
            throw CanonicalMonoAdapterError.invalidSourceFormat
        }
        self.sourceFormat = sourceFormat
        self.selectedChannel = selectedChannel
        self.outputFormat = outputFormat
    }

    public var canonicalCaptureFormat: AudioCaptureFormat {
        AudioCaptureFormat(sampleRate: outputFormat.sampleRate, channelCount: 1)
    }

    public func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(input.frameLength, 1)
        ) else {
            throw CanonicalMonoAdapterError.conversionFailed("could not allocate a canonical mono buffer")
        }
        try convert(input, into: output)
        return output
    }

    public func convert(_ input: AVAudioPCMBuffer, into output: AVAudioPCMBuffer) throws {
        guard input.format.sampleRate == sourceFormat.sampleRate,
              input.format.channelCount == sourceFormat.channelCount else {
            throw CanonicalMonoAdapterError.unsupportedLayout(
                "input format does not match the recording source format"
            )
        }
        try convert(
            bufferList: input.audioBufferList,
            frameCount: input.frameLength,
            into: output
        )
    }

    public func convert(
        _ input: AVAudioPCMBuffer,
        into samples: UnsafeMutablePointer<Float>,
        frameCapacity: Int
    ) throws -> Int {
        guard input.format.sampleRate == sourceFormat.sampleRate,
              input.format.channelCount == sourceFormat.channelCount else {
            throw CanonicalMonoAdapterError.unsupportedLayout(
                "input format does not match the recording source format"
            )
        }
        let frameCount = Int(input.frameLength)
        guard frameCount <= frameCapacity else {
            throw CanonicalMonoAdapterError.conversionFailed("input frame count exceeds the conversion buffer")
        }
        if frameCount == 0 {
            return 0
        }
        try extract(
            bufferList: input.audioBufferList,
            frameCount: frameCount,
            into: samples
        )
        return frameCount
    }

    @_spi(Testing)
    public func convertBufferList(
        _ bufferList: UnsafePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount
    ) throws -> [Float] {
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(frameCount, 1)
        ) else {
            throw CanonicalMonoAdapterError.conversionFailed("could not allocate a canonical mono buffer")
        }
        try convert(bufferList: bufferList, frameCount: frameCount, into: output)
        guard let samples = output.floatChannelData?.pointee else {
            throw CanonicalMonoAdapterError.conversionFailed("canonical buffer is missing Float32 storage")
        }
        return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
    }

    public func convert(
        bufferList: UnsafePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount,
        into output: AVAudioPCMBuffer
    ) throws {
        guard output.format.channelCount == 1,
              output.format.commonFormat == .pcmFormatFloat32,
              output.frameCapacity >= frameCount,
              let destination = output.floatChannelData?.pointee else {
            throw CanonicalMonoAdapterError.conversionFailed("canonical output buffer is not mono Float32")
        }
        if frameCount == 0 {
            output.frameLength = 0
            return
        }
        try extract(
            bufferList: bufferList,
            frameCount: Int(frameCount),
            into: destination
        )
        output.frameLength = frameCount
    }

    private func extract(
        bufferList: UnsafePointer<AudioBufferList>,
        frameCount: Int,
        into destination: UnsafeMutablePointer<Float>
    ) throws {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        guard !buffers.isEmpty else {
            throw CanonicalMonoAdapterError.unsupportedLayout("AudioBufferList contains no buffers")
        }

        var channelBase = 0
        var extracted = false
        for buffer in buffers {
            let channelsInBuffer = Int(buffer.mNumberChannels)
            guard channelsInBuffer > 0 else {
                continue
            }
            let channelEnd = channelBase + channelsInBuffer
            if selectedChannel >= channelBase && selectedChannel < channelEnd {
                try copyChannel(
                    from: buffer,
                    localChannel: selectedChannel - channelBase,
                    frameCount: frameCount,
                    into: destination
                )
                extracted = true
            }
            channelBase = channelEnd
        }

        guard extracted else {
            throw CanonicalMonoAdapterError.selectedChannelOutOfRange(
                selected: selectedChannel,
                channelCount: max(channelBase, Int(sourceFormat.channelCount))
            )
        }
    }

    private func copyChannel(
        from buffer: AudioBuffer,
        localChannel: Int,
        frameCount: Int,
        into destination: UnsafeMutablePointer<Float>
    ) throws {
        guard let data = buffer.mData else {
            throw CanonicalMonoAdapterError.unsupportedLayout("AudioBuffer is missing sample storage")
        }
        let channelsInBuffer = max(1, Int(buffer.mNumberChannels))
        let bytesPerSample = try self.bytesPerSample()
        let frameStride = channelsInBuffer
        let requiredBytes = frameCount * frameStride * bytesPerSample
        guard requiredBytes <= Int(buffer.mDataByteSize) else {
            throw CanonicalMonoAdapterError.unsupportedLayout(
                "AudioBuffer is smaller than the declared frame count"
            )
        }

        switch sourceFormat.commonFormat {
        case .pcmFormatFloat32:
            let source = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                destination[frame] = source[frame * frameStride + localChannel]
            }
        case .pcmFormatInt16:
            let source = data.assumingMemoryBound(to: Int16.self)
            for frame in 0..<frameCount {
                destination[frame] = Float(source[frame * frameStride + localChannel]) / 32_768.0
            }
        case .pcmFormatInt32:
            let source = data.assumingMemoryBound(to: Int32.self)
            for frame in 0..<frameCount {
                destination[frame] = Float(source[frame * frameStride + localChannel]) / 2_147_483_648.0
            }
        default:
            throw CanonicalMonoAdapterError.unsupportedLayout(
                "sample format is not a supported linear PCM layout"
            )
        }
    }

    private func bytesPerSample() throws -> Int {
        switch sourceFormat.commonFormat {
        case .pcmFormatFloat32, .pcmFormatInt32:
            return MemoryLayout<Float>.size
        case .pcmFormatInt16:
            return MemoryLayout<Int16>.size
        default:
            let bits = Int(sourceFormat.streamDescription.pointee.mBitsPerChannel)
            guard bits > 0, bits % 8 == 0 else {
                throw CanonicalMonoAdapterError.unsupportedLayout("sample format has no usable bit depth")
            }
            return bits / 8
        }
    }
}
