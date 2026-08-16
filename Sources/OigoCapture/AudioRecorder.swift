import AVFAudio
import AppKit
import CoreAudio
import Foundation
import OigoCore

public enum AudioRecorderError: Error, CustomStringConvertible, Sendable {
    case alreadyRecording
    case notRecording
    case missingApplicationBundle
    case microphonePermission(String)
    case invalidInputFormat
    case engineStartFailed(String)

    public var description: String {
        switch self {
        case .alreadyRecording:
            "audio recorder is already recording"
        case .notRecording:
            "audio recorder is not recording"
        case .missingApplicationBundle:
            "microphone capture requires an application bundle with NSMicrophoneUsageDescription; the command-line host cannot initialize live capture"
        case .microphonePermission(let permission):
            "microphone permission is " + permission + "; allow Oigo in System Settings > Privacy & Security > Microphone"
        case .invalidInputFormat:
            "microphone input format is unavailable"
        case .engineStartFailed(let reason):
            "audio engine could not start: " + reason
        }
    }
}

public protocol AudioDeviceMonitoring: AnyObject {
    func start(onChange: @escaping @Sendable (String) -> Void)
    func stop()
}

@available(macOS 14.0, *)
public final class SystemAudioDeviceMonitor: AudioDeviceMonitoring, @unchecked Sendable {
    private final class Registration {
        let objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let listener: AudioObjectPropertyListenerBlock

        init(
            objectID: AudioObjectID,
            address: AudioObjectPropertyAddress,
            queue: DispatchQueue,
            listener: @escaping AudioObjectPropertyListenerBlock
        ) {
            self.objectID = objectID
            self.address = address
            self.queue = queue
            self.listener = listener
        }
    }

    private let lock = NSLock()
    private var registration: Registration?
    private var onChange: (@Sendable (String) -> Void)?

    public init() {}

    public func start(onChange: @escaping @Sendable (String) -> Void) {
        stop()
        let queue = DispatchQueue(label: "com.oigo.audio-device-monitor")
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.notifyChange()
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        ) == noErr else {
            return
        }
        lock.lock()
        self.onChange = onChange
        registration = Registration(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: address,
            queue: queue,
            listener: listener
        )
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let registration = self.registration
        self.registration = nil
        onChange = nil
        lock.unlock()

        guard let registration else {
            return
        }
        _ = AudioObjectRemovePropertyListenerBlock(
            registration.objectID,
            &registration.address,
            registration.queue,
            registration.listener
        )
    }

    private func notifyChange() {
        lock.lock()
        let callback = onChange
        lock.unlock()
        callback?("default input device changed")
    }
}

@available(macOS 14.0, *)
public final class AudioRecorder: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let deviceMonitor: AudioDeviceMonitoring
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var audioFileDescriptor: AudioFileDescriptor?
    private var onBuffer: (@Sendable (AudioCaptureBuffer) -> Void)?
    private var onFinish: (@Sendable () -> Void)?
    private var onInterruption: (@Sendable (String) -> Void)?
    private var onFailure: (@Sendable (String) -> Void)?
    private var configurationObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var recording = false
    private var failureReported = false

    public init(deviceMonitor: AudioDeviceMonitoring = SystemAudioDeviceMonitor()) {
        self.deviceMonitor = deviceMonitor
    }

    public func captureFormat() throws -> AudioCaptureFormat {
        guard Bundle.main.bundleIdentifier != nil else {
            throw AudioRecorderError.missingApplicationBundle
        }

        guard let inputConfiguration = Self.inputConfiguration(),
              inputConfiguration.channelCount == 1 else {
            throw AudioRecorderError.invalidInputFormat
        }
        return AudioCaptureFormat(
            sampleRate: inputConfiguration.sampleRate,
            channelCount: 1
        )
    }

    public var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recording
    }

    public static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public func start(
        to descriptor: AudioFileDescriptor,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        var retained = false
        defer {
            if !retained {
                descriptor.close()
            }
        }
        try start(
            writingTo: URL(fileURLWithPath: "/dev/fd/\(descriptor.rawValue)"),
            descriptor: descriptor,
            onBuffer: onBuffer,
            onFinish: onFinish,
            onInterruption: onInterruption,
            onFailure: onFailure
        )
        retained = true
    }

    private func start(
        writingTo url: URL,
        descriptor: AudioFileDescriptor,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        lock.lock()
        let alreadyRecording = recording
        lock.unlock()
        guard !alreadyRecording else {
            throw AudioRecorderError.alreadyRecording
        }

        guard Bundle.main.bundleIdentifier != nil else {
            throw AudioRecorderError.missingApplicationBundle
        }

        let permission = AVAudioApplication.shared.recordPermission
        guard permission == .granted else {
            throw AudioRecorderError.microphonePermission(String(describing: permission))
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        guard let inputConfiguration = Self.inputConfiguration(),
              inputConfiguration.channelCount == 1 else {
            throw AudioRecorderError.invalidInputFormat
        }
        let captureFormat = AVAudioFormat(
            standardFormatWithSampleRate: inputConfiguration.sampleRate,
            channels: AVAudioChannelCount(inputConfiguration.channelCount)
        )
        guard let captureFormat else {
            throw AudioRecorderError.invalidInputFormat
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: captureFormat.settings,
            commonFormat: captureFormat.commonFormat,
            interleaved: captureFormat.isInterleaved
        )

        lock.lock()
        self.engine = engine
        audioFile = file
        audioFileDescriptor = descriptor
        self.onBuffer = onBuffer
        self.onFinish = onFinish
        self.onInterruption = onInterruption
        self.onFailure = onFailure
        recording = true
        failureReported = false
        lock.unlock()

        do {
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
                self?.handle(buffer)
            }
            let observer = NotificationCenter.default.addObserver(
                forName: Notification.Name("AVAudioEngineConfigurationChangeNotification"),
                object: engine,
                queue: nil
            ) { [weak self] _ in
                self?.handleInterruption("audio input configuration changed")
            }
            lock.lock()
            configurationObserver = observer
            lock.unlock()
            deviceMonitor.start { [weak self] reason in
                self?.handleInterruption(reason)
            }
            let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
            let lifecycleNames = [
                NSWorkspace.willSleepNotification,
                NSWorkspace.sessionDidResignActiveNotification
            ]
            let lifecycleObservers = lifecycleNames.map { name in
                workspaceNotificationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: nil
                ) { [weak self] notification in
                    let reason = notification.name.rawValue.contains("Sleep")
                        ? "system sleep interrupted recording"
                        : "screen lock interrupted recording"
                    self?.handleInterruption(reason)
                }
            }
            lock.lock()
            self.lifecycleObservers = lifecycleObservers
            lock.unlock()
            engine.prepare()
            try engine.start()
        } catch {
            cancel()
            throw AudioRecorderError.engineStartFailed(String(describing: error))
        }
    }

    public func stop() throws {
        guard let resources = beginTeardown() else {
            return
        }
        finish(resources)
    }

    public func cancel() {
        guard let resources = beginTeardown() else {
            return
        }
        finish(resources)
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            handleInterruption("microphone permission revoked")
            return
        }

        var callback: (@Sendable (AudioCaptureBuffer) -> Void)?
        var forwardedBuffer: AudioCaptureBuffer?
        var failure: (@Sendable (String) -> Void)?
        var failureDescription: String?

        lock.lock()
        guard recording, !failureReported, let audioFile else {
            lock.unlock()
            return
        }
        do {
            try audioFile.write(from: buffer)
            callback = onBuffer
            forwardedBuffer = AudioCaptureBuffer(
                frameCount: Int(buffer.frameLength),
                sampleRate: buffer.format.sampleRate,
                channelCount: Int(buffer.format.channelCount),
                pcmData: Self.pcmData(from: buffer)
            )
        } catch {
            if !failureReported {
                failureReported = true
                failure = onFailure
                failureDescription = String(describing: error)
            }
        }
        lock.unlock()

        if let failure, let failureDescription {
            cancel()
            failure(failureDescription)
        } else if let callback, let forwardedBuffer {
            callback(forwardedBuffer)
        }
    }

    private static func pcmData(from buffer: AVAudioPCMBuffer) -> Data {
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else {
            return Data()
        }
        return Data(bytes: data, count: Int(audioBuffer.mDataByteSize))
    }

    private struct InputConfiguration {
        let sampleRate: Double
        let channelCount: UInt32
    }

    private static func inputConfiguration() -> InputConfiguration? {
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceAddress,
            0,
            nil,
            &deviceSize,
            &device
        ) == noErr,
        device != AudioDeviceID(kAudioObjectUnknown) else {
            return nil
        }

        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            device,
            &streamAddress,
            0,
            nil,
            &streamSize
        ) == noErr,
        streamSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return nil
        }

        let streamBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(streamSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { streamBuffer.deallocate() }
        guard AudioObjectGetPropertyData(
            device,
            &streamAddress,
            0,
            nil,
            &streamSize,
            streamBuffer
        ) == noErr else {
            return nil
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            streamBuffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        let channelCount = buffers.reduce(0) { $0 + $1.mNumberChannels }
        guard channelCount > 0 else {
            return nil
        }

        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(
            device,
            &rateAddress,
            0,
            nil,
            &rateSize,
            &sampleRate
        ) == noErr,
        sampleRate > 0 else {
            return nil
        }
        return InputConfiguration(sampleRate: sampleRate, channelCount: channelCount)
    }

    private func beginTeardown() -> TeardownResources? {
        lock.lock()
        guard recording else {
            lock.unlock()
            return nil
        }
        recording = false
        let resources = TeardownResources(
            engine: engine,
            onFinish: onFinish,
            descriptor: audioFileDescriptor
        )
        engine = nil
        audioFile = nil
        audioFileDescriptor = nil
        onBuffer = nil
        onFinish = nil
        let observer = configurationObserver
        configurationObserver = nil
        onInterruption = nil
        onFailure = nil
        lock.unlock()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        lock.lock()
        let lifecycleObservers = self.lifecycleObservers
        self.lifecycleObservers = []
        lock.unlock()
        for observer in lifecycleObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        deviceMonitor.stop()
        return resources
    }

    private func handleInterruption(_ reason: String) {
        lock.lock()
        let callback = onInterruption
        let shouldNotify = recording && !failureReported
        if shouldNotify {
            failureReported = true
        }
        lock.unlock()

        guard shouldNotify else {
            return
        }
        cancel()
        callback?(reason)
    }

    private func finish(_ resources: TeardownResources) {
        resources.engine?.inputNode.removeTap(onBus: 0)
        resources.engine?.stop()
        resources.onFinish?()
        resources.descriptor?.close()
    }
}

private struct TeardownResources {
    let engine: AVAudioEngine?
    let onFinish: (@Sendable () -> Void)?
    let descriptor: AudioFileDescriptor?
}
