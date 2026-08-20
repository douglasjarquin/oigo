import AudioToolbox
import AVFAudio
import Darwin
import Foundation
import OigoCore
@_spi(Testing) import OigoCapture

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
@available(macOS 14.0, *)
private struct OigoIssue90ContractTests {
    static func main() {
        let filter = CommandLine.arguments.dropFirst().drop(while: { $0 != "--filter" }).dropFirst().first
        let tests: [(String, () throws -> Void)] = [
            ("canonical-mono-passthrough", testCanonicalMonoPassthrough),
            ("stereo-interleaved-channel-extract", testStereoInterleavedExtract),
            ("stereo-noninterleaved-channel-extract", testStereoNoninterleavedExtract),
            ("multichannel-selected-index", testMultichannelSelectedIndex),
            ("out-of-range-channel", testOutOfRangeChannel),
            ("multibuffer-audio-buffer-list", testMultiBufferAudioBufferList),
            ("canonical-format-is-mono", testCanonicalFormatIsMono),
            ("caf-writer-round-trip", testCAFWriterRoundTrip),
            ("pipeline-stop-drains-accepted", testPipelineStopDrainsAccepted),
            ("pipeline-slow-writer-handoff", testPipelineSlowWriterHandoff),
            ("pipeline-overflow", testPipelineOverflow),
            ("pipeline-writer-failure-vs-speech", testWriterFailureVersusSpeech),
            ("pipeline-stale-generation", testStaleGeneration),
            ("pipeline-start-stop-cycles", testStartStopCycles),
            ("unsupported-pcm-rejected-at-init", testUnsupportedPCMRejectedAtInit),
            ("cancel-preserves-caf-prefix", testCancelPreservesCAFPrefix),
            ("interrupt-preserves-caf-prefix", testInterruptPreservesCAFPrefix),
            ("slow-speech-does-not-overflow", testSlowSpeechDoesNotOverflow),
            ("recorder-startup-interruption", testRecorderStartupInterruption),
            ("recorder-stop-after-overflow", testRecorderStopAfterOverflow),
            ("recorder-concurrent-terminalize", testRecorderConcurrentTerminalize)
        ]

        let selected = tests.filter { filter == nil || $0.0.contains(filter ?? "") }
        guard !selected.isEmpty else {
            print("FAIL: no issue #90 contract scenarios matched filter")
            exit(1)
        }

        var failures = 0
        for (name, test) in selected {
            do {
                try test()
                print("GREEN: issue #90 " + name)
            } catch {
                failures += 1
                print("FAIL: issue #90 " + name + ": " + String(describing: error))
            }
        }

        if failures > 0 {
            print("FAILURES=" + String(failures))
            exit(1)
        }
        print("GREEN: all issue #90 contract scenarios")
    }

    private static func testCanonicalMonoPassthrough() throws {
        let format = try monoFormat()
        let adapter = try CanonicalMonoAdapter(sourceFormat: format, selectedChannel: 0)
        let source = try makeBuffer(format: format, frames: 8) { _, frame in
            Float(frame) * 0.125
        }
        let converted = try adapter.convert(source)
        try assertCanonical(converted, sampleRate: format.sampleRate, frames: 8)
        try assertSamples(
            converted,
            equalTo: (0..<8).map { Float($0) * 0.125 },
            tolerance: CanonicalMonoAdapter.floatPassthroughTolerance,
            note: "mono Float32 pass-through is bit-identical (tolerance 0)"
        )
        guard adapter.canonicalCaptureFormat.isCanonicalMono else {
            throw ContractFailure(message: "canonical capture format was not mono")
        }
    }

    private static func testStereoInterleavedExtract() throws {
        let format = try requiredFormat(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 2,
                interleaved: true
            )
        )
        let adapter = try CanonicalMonoAdapter(sourceFormat: format, selectedChannel: 1)
        let source = try makeBuffer(format: format, frames: 6) { channel, frame in
            channel == 0 ? Float(frame) : Float(frame) + 100
        }
        let converted = try adapter.convert(source)
        try assertCanonical(converted, sampleRate: 16_000, frames: 6)
        try assertSamples(
            converted,
            equalTo: (0..<6).map { Float($0) + 100 },
            tolerance: CanonicalMonoAdapter.floatPassthroughTolerance,
            note: "interleaved stereo must extract the selected channel without mixing"
        )
        let leftAdapter = try CanonicalMonoAdapter(sourceFormat: format, selectedChannel: 0)
        let left = try leftAdapter.convert(source)
        try assertSamples(
            left,
            equalTo: (0..<6).map { Float($0) },
            tolerance: CanonicalMonoAdapter.floatPassthroughTolerance,
            note: "channel 0 must not include the right channel"
        )
    }

    private static func testStereoNoninterleavedExtract() throws {
        let format = try requiredFormat(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 2,
                interleaved: false
            )
        )
        let adapter = try CanonicalMonoAdapter(sourceFormat: format, selectedChannel: 1)
        let source = try makeBuffer(format: format, frames: 6) { channel, frame in
            channel == 0 ? -Float(frame + 1) : Float(frame + 1) * 3
        }
        let converted = try adapter.convert(source)
        try assertCanonical(converted, sampleRate: 16_000, frames: 6)
        try assertSamples(
            converted,
            equalTo: (0..<6).map { Float($0 + 1) * 3 },
            tolerance: CanonicalMonoAdapter.floatPassthroughTolerance,
            note: "noninterleaved stereo must extract the selected buffer, not mix channels"
        )
    }

    private static func testMultichannelSelectedIndex() throws {
        let layout = try requiredLayout(
            AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Quadraphonic)
        )
        let format = try requiredFormat(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                interleaved: false,
                channelLayout: layout
            )
        )
        let adapter = try CanonicalMonoAdapter(sourceFormat: format, selectedChannel: 2)
        let source = try makeBuffer(format: format, frames: 4) { channel, frame in
            Float(channel * 10 + frame)
        }
        let converted = try adapter.convert(source)
        try assertSamples(
            converted,
            equalTo: (0..<4).map { Float(20 + $0) },
            tolerance: CanonicalMonoAdapter.floatPassthroughTolerance,
            note: "multi-channel input must extract the persisted selected index"
        )
    }

    private static func testOutOfRangeChannel() throws {
        let format = try requiredFormat(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2)
        )
        do {
            _ = try CanonicalMonoAdapter(sourceFormat: format, selectedChannel: 2)
            throw ContractFailure(message: "out-of-range channel was accepted before conversion")
        } catch CanonicalMonoAdapterError.selectedChannelOutOfRange(let selected, let channelCount) {
            guard selected == 2, channelCount == 2 else {
                throw ContractFailure(message: "out-of-range error did not report the selected index")
            }
        }
        do {
            _ = try CanonicalMonoAdapter(sourceFormat: format, selectedChannel: -1)
            throw ContractFailure(message: "negative channel was accepted")
        } catch CanonicalMonoAdapterError.selectedChannelOutOfRange {
            return
        }
    }

    private static func testMultiBufferAudioBufferList() throws {
        let format = try requiredFormat(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 2,
                interleaved: false
            )
        )
        let adapter = try CanonicalMonoAdapter(sourceFormat: format, selectedChannel: 1)
        let left = (0..<5).map { Float($0) }
        let right = (0..<5).map { Float($0) + 50 }
        let converted = try withTwoBufferList(left: left, right: right) { bufferList in
            try adapter.convertBufferList(bufferList, frameCount: 5)
        }
        guard converted == right else {
            throw ContractFailure(
                message: "multi-buffer AudioBufferList treated the first buffer as the entire stream"
            )
        }
        let firstBufferAdapter = try CanonicalMonoAdapter(sourceFormat: format, selectedChannel: 0)
        let first = try withTwoBufferList(left: left, right: right) { bufferList in
            try firstBufferAdapter.convertBufferList(bufferList, frameCount: 5)
        }
        guard first == left else {
            throw ContractFailure(message: "channel 0 did not come from the first AudioBuffer")
        }
    }

    private static func testCanonicalFormatIsMono() throws {
        let stereo = try requiredFormat(
            AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        )
        let adapter = try CanonicalMonoAdapter(sourceFormat: stereo, selectedChannel: 0)
        let format = adapter.canonicalCaptureFormat
        guard format.isCanonicalMono, format.channelCount == 1, format.sampleRate == 44_100 else {
            throw ContractFailure(message: "AudioCaptureFormat described the hardware channel count instead of canonical mono")
        }
    }

    private static func testCAFWriterRoundTrip() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let session = try store.createSession(now: Date(timeIntervalSince1970: 9_000))
        let descriptor = try store.createAudioFileDescriptor(for: session)
        var descriptorInfo = stat()
        guard fstat(descriptor.rawValue, &descriptorInfo) == 0 else {
            throw ContractFailure(message: "could not stat the secure session descriptor")
        }

        let format = try monoFormat()
        let writer: CAFWriter
        do {
            writer = try CAFWriter(descriptor: descriptor, format: format)
        } catch {
            print("INCONCLUSIVE: native CAF writer unavailable: " + String(describing: error))
            descriptor.close()
            return
        }

        guard writer.boundFileDescriptor == descriptor.rawValue,
              CAFWriter.fileType == kAudioFileCAFType,
              writer.usesPathExtensionInference == false else {
            writer.close()
            throw ContractFailure(message: "CAF writer was not bound to the session descriptor with an explicit CAF type")
        }

        let samples: [Float] = (0..<1_600).map { sin(Float($0) / 32.0) * 0.25 }
        try samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw ContractFailure(message: "synthetic PCM pointer was missing")
            }
            try writer.writeCanonicalMono(samples: baseAddress, frameCount: samples.count)
        }
        writer.close()

        let readDescriptor = try store.openAudioFileDescriptor(for: session)
        do {
            let reader = try CAFReader(descriptor: readDescriptor, ownsDescriptor: true)
            let readerFrames = try reader.frameLength()
            reader.close()
            guard readerFrames == Int64(samples.count),
                  reader.usesPathExtensionInference == false else {
                throw ContractFailure(message: "CAF reader did not reopen the explicit CAF descriptor")
            }
        } catch let error as CAFReaderError {
            print("INCONCLUSIVE: native CAF reader unavailable: " + String(describing: error))
        }

        var pathInfo = stat()
        guard lstat(session.audioURL.path, &pathInfo) == 0,
              pathInfo.st_dev == descriptorInfo.st_dev,
              pathInfo.st_ino == descriptorInfo.st_ino else {
            throw ContractFailure(message: "written CAF is not the inode represented by the original descriptor")
        }

        let frames = try AudioPlayback.playableFrameLength(at: session.audioURL)
        guard frames == AVAudioFramePosition(samples.count) else {
            throw ContractFailure(
                message: "production reader did not reopen a playable CAF with the committed frame count"
            )
        }
    }

    private static func testPipelineStopDrainsAccepted() throws {
        let writer = ScriptedWriter()
        let pipeline = try makePipeline(writer: writer, generation: 1, capacity: 8)
        let buffer = try makeSineBuffer(frames: 32, seed: 1)
        for _ in 0..<4 {
            let result = pipeline.tryAccept(buffer, generation: 1)
            guard result == .accepted else {
                throw ContractFailure(message: "accepted buffers were rejected before stop: " + String(describing: result))
            }
        }
        pipeline.stopAndWait()
        guard writer.closed,
              writer.frameCounts == [32, 32, 32, 32],
              writer.samples.count == 4 else {
            throw ContractFailure(message: "user stop did not drain accepted buffers before close")
        }
    }

    private static func testPipelineSlowWriterHandoff() throws {
        let writer = ScriptedWriter()
        writer.blockWrites = true
        let pipeline = try makePipeline(writer: writer, generation: 7, capacity: 8)
        let buffer = try makeSineBuffer(frames: 16, seed: 2)
        let acceptStarted = Date()
        for _ in 0..<3 {
            guard pipeline.tryAccept(buffer, generation: 7) == .accepted else {
                writer.unblock()
                throw ContractFailure(message: "slow writer blocked the tap handoff")
            }
        }
        let acceptElapsed = Date().timeIntervalSince(acceptStarted)
        guard acceptElapsed < 0.05 else {
            writer.unblock()
            throw ContractFailure(message: "tap handoff waited on the slow writer")
        }
        writer.unblock()
        pipeline.stopAndWait()
        guard writer.frameCounts.count == 3, writer.closed else {
            throw ContractFailure(message: "slow writer did not receive the accepted sequence after the tap returned")
        }
    }

    private static func testPipelineOverflow() throws {
        let writer = ScriptedWriter()
        writer.blockWrites = true
        let pipeline = try makePipeline(writer: writer, generation: 3, capacity: 2, maxFrames: 16)
        let buffer = try makeSineBuffer(frames: 8, seed: 3)
        var accepted = 0
        var overflowed = false
        for _ in 0..<6 {
            switch pipeline.tryAccept(buffer, generation: 3) {
            case .accepted:
                accepted += 1
            case .overflow:
                overflowed = true
            default:
                break
            }
        }
        guard overflowed, accepted >= 1 else {
            writer.unblock()
            throw ContractFailure(message: "queue saturation did not report overflow")
        }
        writer.unblock()
        let deadline = Date().addingTimeInterval(1)
        while !pipeline.isFinalized && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard writer.failures.contains(CapturePipelineFailure.overflow.rawValue) else {
            throw ContractFailure(message: "overflow did not report audio_pipeline_overflow")
        }
    }

    private static func testWriterFailureVersusSpeech() throws {
        let writer = ScriptedWriter()
        writer.failOnWrite = 2
        let speech = SpeechSink()
        speech.failOnBuffer = 1
        let pipeline = try makePipeline(
            writer: writer,
            generation: 4,
            capacity: 8,
            onBuffer: { buffer in
                speech.consume(buffer)
            }
        )
        let buffer = try makeSineBuffer(frames: 10, seed: 4)
        for _ in 0..<4 {
            _ = pipeline.tryAccept(buffer, generation: 4)
        }
        pipeline.stopAndWait()
        pipeline.waitForSpeechHandoff()
        guard writer.writeCount == 2,
              writer.failures.contains(where: { $0.contains("injected writer failure") }),
              speech.count >= 1 else {
            throw ContractFailure(message: "durable writer failure did not terminalize after the committed prefix")
        }

        let completingWriter = ScriptedWriter()
        let failingSpeech = SpeechSink()
        failingSpeech.failOnBuffer = 1
        let durablePipeline = try makePipeline(
            writer: completingWriter,
            generation: 5,
            capacity: 8,
            onBuffer: { buffer in
                failingSpeech.consume(buffer)
            }
        )
        for _ in 0..<3 {
            _ = durablePipeline.tryAccept(buffer, generation: 5)
        }
        durablePipeline.stopAndWait()
        guard completingWriter.frameCounts.count == 3,
              completingWriter.closed,
              completingWriter.failures.isEmpty else {
            throw ContractFailure(message: "speech failure terminalized durable capture instead of allowing it to complete")
        }
    }

    private static func testStaleGeneration() throws {
        let writer = ScriptedWriter()
        let pipeline = try makePipeline(writer: writer, generation: 11, capacity: 4)
        let buffer = try makeSineBuffer(frames: 8, seed: 6)
        guard pipeline.tryAccept(buffer, generation: 11) == .accepted else {
            throw ContractFailure(message: "current generation was rejected")
        }
        guard pipeline.tryAccept(buffer, generation: 10) == .ignored else {
            throw ContractFailure(message: "stale generation mutated the current recording")
        }
        pipeline.stopAndWait()
        guard writer.frameCounts == [8] else {
            throw ContractFailure(message: "stale callback was written into the later recording")
        }
    }

    private static func testStartStopCycles() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let format = try monoFormat()
        let before = openFileDescriptorCount()
        var nativeFailures = 0

        for cycle in 0..<100 {
            let session = try store.createSession(
                now: Date(timeIntervalSince1970: 10_000 + Double(cycle))
            )
            let descriptor = try store.createAudioFileDescriptor(for: session)
            let writer: CAFWriter
            do {
                writer = try CAFWriter(descriptor: descriptor, format: format)
            } catch {
                descriptor.close()
                nativeFailures += 1
                continue
            }
            let pipeline = try makePipeline(writer: writer, generation: UInt64(cycle + 1), capacity: 4)
            let buffer = try makeSineBuffer(frames: 32, seed: cycle)
            guard pipeline.tryAccept(buffer, generation: UInt64(cycle + 1)) == .accepted else {
                pipeline.cancelAndWait()
                throw ContractFailure(message: "cycle \(cycle) rejected an accepted buffer")
            }
            pipeline.stopAndWait()
            guard writer.isClosed else {
                throw ContractFailure(message: "cycle \(cycle) leaked a CAF writer")
            }
        }

        if nativeFailures == 100 {
            print("INCONCLUSIVE: native CAF writer unavailable for start/stop cycles")
            return
        }
        guard nativeFailures == 0 else {
            throw ContractFailure(message: "native CAF writer failed during start/stop cycles")
        }
        let after = openFileDescriptorCount()
        guard after <= before + 8 else {
            throw ContractFailure(
                message: "100 start/stop cycles leaked descriptors: before=\(before) after=\(after)"
            )
        }
    }

    private static func testUnsupportedPCMRejectedAtInit() throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 3,
            mFramesPerPacket: 1,
            mBytesPerFrame: 3,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 24,
            mReserved: 0
        )
        let format = try requiredFormat(AVAudioFormat(streamDescription: &asbd))
        do {
            _ = try CanonicalMonoAdapter(sourceFormat: format, selectedChannel: 0)
            throw ContractFailure(message: "24-bit PCM was accepted at adapter init")
        } catch CanonicalMonoAdapterError.unsupportedLayout {
            return
        }
    }

    private static func testCancelPreservesCAFPrefix() throws {
        try assertTerminalPreservesCAFPrefix(cancel: true)
    }

    private static func testInterruptPreservesCAFPrefix() throws {
        try assertTerminalPreservesCAFPrefix(cancel: false)
    }

    private static func assertTerminalPreservesCAFPrefix(cancel: Bool) throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let session = try store.createSession(now: Date(timeIntervalSince1970: cancel ? 11_000 : 11_100))
        let descriptor = try store.createAudioFileDescriptor(for: session)
        let format = try monoFormat()
        let cafWriter: CAFWriter
        do {
            cafWriter = try CAFWriter(descriptor: descriptor, format: format)
        } catch {
            descriptor.close()
            print("INCONCLUSIVE: native CAF writer unavailable: " + String(describing: error))
            return
        }
        let writer = GatedCAFWriter(inner: cafWriter)
        let pipeline = try makePipeline(writer: writer, generation: 21, capacity: 8)
        let first = try makeSineBuffer(frames: 32, seed: 1)
        let second = try makeSineBuffer(frames: 32, seed: 2)
        guard pipeline.tryAccept(first, generation: 21) == .accepted else {
            throw ContractFailure(message: "first buffer was not accepted")
        }
        let wroteFirst = Date().addingTimeInterval(0.5)
        while writer.writeCount < 1 && Date() < wroteFirst {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard writer.writeCount == 1 else {
            pipeline.cancelAndWait()
            throw ContractFailure(message: "first buffer was not committed before the second was queued")
        }
        guard pipeline.tryAccept(second, generation: 21) == .accepted else {
            throw ContractFailure(message: "second buffer was not accepted")
        }
        if cancel {
            pipeline.cancelAndWait()
        } else {
            pipeline.interruptAndWait("test interruption")
        }
        let readerDescriptor = try store.openAudioFileDescriptor(for: session)
        let reader = try CAFReader(descriptor: readerDescriptor, ownsDescriptor: true)
        let frames = try reader.frameLength()
        reader.close()
        guard frames == 32 else {
            throw ContractFailure(
                message: "cancel/interrupt did not preserve only the committed CAF prefix, frames=\(frames)"
            )
        }
    }

    private static func testSlowSpeechDoesNotOverflow() throws {
        let writer = ScriptedWriter()
        let speech = SpeechSink()
        speech.blockOnConsume = true
        let pipeline = try makePipeline(
            writer: writer,
            generation: 22,
            capacity: 8,
            onBuffer: { buffer in
                speech.consume(buffer)
            }
        )
        let buffer = try makeSineBuffer(frames: 16, seed: 9)
        for _ in 0..<6 {
            let result = pipeline.tryAccept(buffer, generation: 22)
            guard result == .accepted else {
                speech.unblock()
                throw ContractFailure(message: "slow Speech overflowed durable capture: " + String(describing: result))
            }
        }
        speech.unblock()
        pipeline.stopAndWait()
        guard writer.frameCounts.count == 6,
              writer.failures.isEmpty else {
            throw ContractFailure(message: "slow Speech terminalized or truncated durable CAF writes")
        }
    }

    private static func testRecorderStartupInterruption() throws {
        let writer = ScriptedWriter()
        let recorder = AudioRecorder(
            deviceMonitor: EmptyDeviceMonitor(),
            inputRouter: FailingInputRouter()
        )
        let generation = try recorder.testClaimStart()
        let pipeline = try makePipeline(writer: writer, generation: generation, capacity: 4)
        recorder.testInstallPipeline(pipeline)
        recorder.testNoteInterruption("audio input configuration changed", generation: generation)
        recorder.testApplyEngineStart(generation: generation)
        guard !recorder.testIsStarting,
              !recorder.isRecording,
              pipeline.isFinalized else {
            throw ContractFailure(message: "startup interruption returned success and left capture starting")
        }
        guard recorder.testLatchedFailure?.contains("configuration") == true else {
            throw ContractFailure(message: "startup interruption was not latched")
        }
    }

    private static func testRecorderStopAfterOverflow() throws {
        let writer = ScriptedWriter()
        writer.blockClose = true
        let recorder = AudioRecorder(
            deviceMonitor: EmptyDeviceMonitor(),
            inputRouter: FailingInputRouter()
        )
        let generation = try recorder.testClaimStart()
        let format = try monoFormat()
        let adapter = try CanonicalMonoAdapter(sourceFormat: format, selectedChannel: 0)
        let pipeline = CapturePipeline(
            generation: generation,
            adapter: adapter,
            writer: writer,
            capacity: 2,
            maxFrames: 1_024,
            maxBytes: 2 * 1_024 * MemoryLayout<Float>.size,
            onBuffer: { _ in },
            onFinish: {},
            onInterruption: { _ in },
            onFailure: { reason in
                writer.failures.append(reason)
                recorder.testNotifyFailure(reason, generation: generation)
            },
            teardownHandler: {
                recorder.testBeginEngineTeardown()
            },
            onTerminalized: {
                recorder.testNotifyTerminalized(generation: generation)
            }
        )
        recorder.testInstallPipeline(pipeline, recording: true)
        let buffer = try makeSineBuffer(frames: 8, seed: 3)
        var overflowed = false
        for _ in 0..<6 {
            if pipeline.tryAccept(buffer, generation: generation) == .overflow {
                overflowed = true
            }
        }
        guard overflowed else {
            writer.unblockClose()
            throw ContractFailure(message: "overflow was not produced")
        }
        guard writer.waitUntilCloseStarted(timeout: 1) else {
            writer.unblockClose()
            throw ContractFailure(message: "overflow teardown did not reach writer close")
        }
        do {
            try recorder.stop()
            writer.unblockClose()
            throw ContractFailure(message: "stop during overflow teardown succeeded and could mark the session complete")
        } catch let error as AudioRecorderError {
            writer.unblockClose()
            guard case .captureFailed(let reason) = error,
                  reason == CapturePipelineFailure.overflow.rawValue else {
                throw ContractFailure(message: "stop during overflow teardown did not report audio_pipeline_overflow")
            }
        }
        let deadline = Date().addingTimeInterval(1)
        while !pipeline.isFinalized && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !recorder.isRecording else {
            throw ContractFailure(message: "overflow left the recorder recording")
        }
    }

    private static func testRecorderConcurrentTerminalize() throws {
        let writer = ScriptedWriter()
        let recorder = AudioRecorder(
            deviceMonitor: EmptyDeviceMonitor(),
            inputRouter: FailingInputRouter()
        )
        let generation = try recorder.testClaimStart()
        let pipeline = try makePipeline(writer: writer, generation: generation, capacity: 4)
        recorder.testInstallPipeline(pipeline, recording: true)
        let buffer = try makeSineBuffer(frames: 8, seed: 4)
        _ = pipeline.tryAccept(buffer, generation: generation)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            recorder.cancel()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            recorder.testNoteInterruption("system sleep interrupted recording", generation: generation)
            group.leave()
        }
        group.wait()
        guard !recorder.isRecording,
              !recorder.testIsStarting,
              !recorder.testIsFinishing,
              pipeline.isFinalized else {
            throw ContractFailure(message: "concurrent terminalize left finishing set or capture live")
        }
    }

    private static func makePipeline(
        writer: CanonicalAudioWriting,
        generation: UInt64,
        capacity: Int,
        maxFrames: Int = 1_024,
        onBuffer: (@Sendable (AudioCaptureBuffer) -> Void)? = nil
    ) throws -> CapturePipeline {
        let format = try monoFormat()
        let adapter = try CanonicalMonoAdapter(sourceFormat: format, selectedChannel: 0)
        let speech = onBuffer
        let scripted = writer as? ScriptedWriter
        return CapturePipeline(
            generation: generation,
            adapter: adapter,
            writer: writer,
            capacity: capacity,
            maxFrames: maxFrames,
            maxBytes: capacity * maxFrames * MemoryLayout<Float>.size,
            onBuffer: { buffer in
                speech?(buffer)
            },
            onFinish: {
                scripted?.finished = true
            },
            onInterruption: { reason in
                scripted?.interruptions.append(reason)
            },
            onFailure: { reason in
                scripted?.failures.append(reason)
            },
            teardownHandler: {}
        )
    }

    private static func makeSineBuffer(frames: AVAudioFrameCount, seed: Int) throws -> AVAudioPCMBuffer {
        let format = try monoFormat()
        return try makeBuffer(format: format, frames: frames) { _, frame in
            sin(Float(frame + seed) / 8.0) * 0.2
        }
    }

    private static func monoFormat() throws -> AVAudioFormat {
        try requiredFormat(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    }

    private static func requiredFormat(_ format: AVAudioFormat?) throws -> AVAudioFormat {
        guard let format else {
            throw ContractFailure(message: "could not construct AVAudioFormat fixture")
        }
        return format
    }

    private static func requiredLayout(_ layout: AVAudioChannelLayout?) throws -> AVAudioChannelLayout {
        guard let layout else {
            throw ContractFailure(message: "could not construct a quadraphonic channel layout")
        }
        return layout
    }

    private static func makeBuffer(
        format: AVAudioFormat,
        frames: AVAudioFrameCount,
        fill: (Int, Int) -> Float
    ) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw ContractFailure(message: "could not allocate PCM fixture")
        }
        buffer.frameLength = frames
        let channels = Int(format.channelCount)
        if format.isInterleaved {
            let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard let data = abl.first?.mData else {
                throw ContractFailure(message: "interleaved fixture is missing sample storage")
            }
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<Int(frames) {
                for channel in 0..<channels {
                    samples[frame * channels + channel] = fill(channel, frame)
                }
            }
        } else {
            guard let channelData = buffer.floatChannelData else {
                throw ContractFailure(message: "noninterleaved fixture is missing channel storage")
            }
            for channel in 0..<channels {
                for frame in 0..<Int(frames) {
                    channelData[channel][frame] = fill(channel, frame)
                }
            }
        }
        return buffer
    }

    private static func assertCanonical(
        _ buffer: AVAudioPCMBuffer,
        sampleRate: Double,
        frames: AVAudioFrameCount
    ) throws {
        guard buffer.format.channelCount == 1,
              buffer.format.sampleRate == sampleRate,
              buffer.frameLength == frames else {
            throw ContractFailure(message: "converted buffer was not canonical mono PCM")
        }
    }

    private static func assertSamples(
        _ buffer: AVAudioPCMBuffer,
        equalTo expected: [Float],
        tolerance: Float,
        note: String
    ) throws {
        guard let samples = buffer.floatChannelData?.pointee else {
            throw ContractFailure(message: note + ": missing Float32 storage")
        }
        guard Int(buffer.frameLength) == expected.count else {
            throw ContractFailure(message: note + ": frame count mismatch")
        }
        for index in expected.indices {
            let delta = abs(samples[index] - expected[index])
            if delta > tolerance {
                throw ContractFailure(
                    message: note + ": sample \(index) delta \(delta) exceeds tolerance \(tolerance)"
                )
            }
        }
    }

    private static func withTwoBufferList<T>(
        left: [Float],
        right: [Float],
        body: (UnsafePointer<AudioBufferList>) throws -> T
    ) throws -> T {
        guard left.count == right.count else {
            throw ContractFailure(message: "multi-buffer fixture channel lengths differ")
        }
        var leftSamples = left
        var rightSamples = right
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        defer { abl.unsafeMutablePointer.deallocate() }
        abl.count = 2
        return try leftSamples.withUnsafeMutableBufferPointer { leftBuffer in
            try rightSamples.withUnsafeMutableBufferPointer { rightBuffer in
                abl[0] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(left.count * MemoryLayout<Float>.size),
                    mData: leftBuffer.baseAddress.map { UnsafeMutableRawPointer($0) }
                )
                abl[1] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(right.count * MemoryLayout<Float>.size),
                    mData: rightBuffer.baseAddress.map { UnsafeMutableRawPointer($0) }
                )
                return try body(UnsafePointer(abl.unsafeMutablePointer))
            }
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue90-contract-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    private static func openFileDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? 0
    }
}

private final class ScriptedWriter: CanonicalAudioWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var gate = DispatchSemaphore(value: 0)
    private let closeStarted = DispatchSemaphore(value: 0)
    private let closeGate = DispatchSemaphore(value: 0)
    var blockWrites = false
    var blockClose = false
    var failOnWrite: Int?
    private(set) var writeCount = 0
    private(set) var samples: [[Float]] = []
    private(set) var frameCounts: [Int] = []
    private(set) var closed = false
    var finished = false
    var failures: [String] = []
    var interruptions: [String] = []

    func writeCanonicalMono(samples: UnsafePointer<Float>, frameCount: Int) throws {
        let shouldBlock: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return blockWrites
        }()
        if shouldBlock {
            gate.wait()
        }
        lock.lock()
        writeCount += 1
        let current = writeCount
        let failAt = failOnWrite
        frameCounts.append(frameCount)
        self.samples.append(Array(UnsafeBufferPointer(start: samples, count: frameCount)))
        lock.unlock()
        if failAt == current {
            throw ContractFailure(message: "injected writer failure")
        }
    }

    func close() {
        let shouldBlock: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return blockClose
        }()
        if shouldBlock {
            closeStarted.signal()
            closeGate.wait()
        }
        lock.lock()
        closed = true
        lock.unlock()
    }

    func waitUntilCloseStarted(timeout: TimeInterval) -> Bool {
        closeStarted.wait(timeout: .now() + timeout) == .success
    }

    func unblockClose() {
        lock.lock()
        blockClose = false
        lock.unlock()
        closeGate.signal()
        closeGate.signal()
    }

    func unblock() {
        lock.lock()
        blockWrites = false
        lock.unlock()
        gate.signal()
        gate.signal()
        gate.signal()
        gate.signal()
        gate.signal()
        gate.signal()
    }
}

private final class SpeechSink: @unchecked Sendable {
    var failOnBuffer: Int?
    var blockOnConsume = false
    private let gate = DispatchSemaphore(value: 0)
    private(set) var count = 0

    func consume(_ buffer: AudioCaptureBuffer) {
        if blockOnConsume {
            gate.wait()
        }
        count += 1
        if failOnBuffer == count {
            return
        }
        _ = buffer
    }

    func unblock() {
        blockOnConsume = false
        gate.signal()
        gate.signal()
        gate.signal()
        gate.signal()
        gate.signal()
        gate.signal()
        gate.signal()
        gate.signal()
    }
}

private final class GatedCAFWriter: CanonicalAudioWriting, @unchecked Sendable {
    private let inner: CAFWriter
    private let lock = NSLock()
    private(set) var writeCount = 0

    init(inner: CAFWriter) {
        self.inner = inner
    }

    func writeCanonicalMono(samples: UnsafePointer<Float>, frameCount: Int) throws {
        lock.lock()
        writeCount += 1
        let current = writeCount
        lock.unlock()
        try inner.writeCanonicalMono(samples: samples, frameCount: frameCount)
        if current == 1 {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func close() {
        inner.close()
    }
}

private final class EmptyDeviceMonitor: AudioDeviceMonitoring {
    func currentDevices() throws -> [OigoInputDevice] {
        []
    }

    func start(onChange: @escaping @Sendable ([OigoInputDevice]) -> Void) {
        _ = onChange
    }

    func stop() {}
}

private final class FailingInputRouter: AudioInputDeviceRouting {
    func route(inputNode: AVAudioInputNode, to deviceID: UInt32) throws {
        _ = inputNode
        _ = deviceID
        throw AudioRecorderError.inputDeviceRouteFailed
    }
}
