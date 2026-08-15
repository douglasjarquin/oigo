import AVFAudio
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

public final class AudioRecorder: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var onBuffer: (@Sendable () -> Void)?
    private var onFinish: (@Sendable () -> Void)?
    private var onInterruption: (@Sendable (String) -> Void)?
    private var onFailure: (@Sendable (String) -> Void)?
    private var configurationObserver: NSObjectProtocol?
    private var recording = false
    private var failureReported = false

    public init() {}

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
        to url: URL,
        onBuffer: @escaping @Sendable () -> Void,
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
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }
        let captureFormat = AVAudioFormat(
            standardFormatWithSampleRate: nativeFormat.sampleRate,
            channels: 1
        ) ?? nativeFormat

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let file = try AVAudioFile(
            forWriting: url,
            settings: captureFormat.settings,
            commonFormat: captureFormat.commonFormat,
            interleaved: captureFormat.isInterleaved
        )

        lock.lock()
        self.engine = engine
        audioFile = file
        self.onBuffer = onBuffer
        self.onFinish = onFinish
        self.onInterruption = onInterruption
        self.onFailure = onFailure
        recording = true
        failureReported = false
        lock.unlock()

        do {
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: captureFormat) { [weak self] buffer, _ in
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
            engine.prepare()
            try engine.start()
        } catch {
            cancel()
            throw AudioRecorderError.engineStartFailed(String(describing: error))
        }
    }

    public func stop() throws {
        guard let resources = beginTeardown() else {
            throw AudioRecorderError.notRecording
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
        var callback: (@Sendable () -> Void)?
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
        } else {
            callback?()
        }
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
            onFinish: onFinish
        )
        engine = nil
        audioFile = nil
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
    }
}

private struct TeardownResources {
    let engine: AVAudioEngine?
    let onFinish: (@Sendable () -> Void)?
}
