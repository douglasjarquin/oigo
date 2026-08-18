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
    case inputDeviceUnavailable
    case selectedInputUnavailable
    case inputDeviceRouteFailed
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
        case .inputDeviceUnavailable:
            "no microphone input is available; connect an input or choose another source in Oigo Settings"
        case .selectedInputUnavailable:
            "the selected microphone is unavailable; reconnect it or choose another source in Oigo Settings"
        case .inputDeviceRouteFailed:
            "Oigo could not select the requested microphone; choose another source in Settings and try again"
        case .invalidInputFormat:
            "microphone input format is unavailable"
        case .engineStartFailed(let reason):
            "audio engine could not start: " + reason
        }
    }
}

public protocol AudioDeviceMonitoring: AnyObject {
    func currentDevices() throws -> [OigoInputDevice]
    func start(onChange: @escaping @Sendable ([OigoInputDevice]) -> Void)
    func stop()
}

public protocol AudioInputDeviceRouting: AnyObject {
    func route(inputNode: AVAudioInputNode, to deviceID: UInt32) throws
}

@available(macOS 14.0, *)
public final class SystemAudioInputDeviceRouter: AudioInputDeviceRouting, @unchecked Sendable {
    public init() {}

    public func route(inputNode: AVAudioInputNode, to deviceID: UInt32) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioRecorderError.inputDeviceRouteFailed
        }
        var device = AudioDeviceID(deviceID)
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            size
        ) == noErr else {
            throw AudioRecorderError.inputDeviceRouteFailed
        }
    }
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
    private var registrations: [Registration] = []
    private var onChange: (@Sendable ([OigoInputDevice]) -> Void)?
    private var listenerQueue: DispatchQueue?

    private static let devicePropertyScopes: [
        (selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope)
    ] = [
        (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
        (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal)
    ]

    public init() {}

    public func currentDevices() throws -> [OigoInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            throw AudioRecorderError.inputDeviceUnavailable
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard deviceCount > 0 else {
            return []
        }
        var deviceIDs = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: deviceCount)
        let status = deviceIDs.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else {
                return kAudioHardwareBadPropertySizeError
            }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                baseAddress
            )
        }
        guard status == noErr else {
            throw AudioRecorderError.inputDeviceUnavailable
        }

        let defaultDevice = Self.readDeviceID(
            AudioDeviceID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        return deviceIDs.compactMap { deviceID in
            Self.makeDevice(deviceID, isDefault: deviceID == defaultDevice)
        }
    }

    public func start(onChange: @escaping @Sendable ([OigoInputDevice]) -> Void) {
        stop()
        let queue = DispatchQueue(label: "com.oigo.audio-device-monitor")
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.notifyChange()
        }
        let initialDeviceIDs = Set(
            (try? currentDevices())?.map { AudioDeviceID($0.deviceID) } ?? []
        )
        let selectors = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice
        ]
        var registrations: [Registration] = []
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener
            ) == noErr else {
                for registration in registrations {
                    var registeredAddress = registration.address
                    _ = AudioObjectRemovePropertyListenerBlock(
                        registration.objectID,
                        &registeredAddress,
                        registration.queue,
                        registration.listener
                    )
                }
                return
            }
            registrations.append(Registration(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: address,
                queue: queue,
                listener: listener
            ))
        }
        lock.lock()
        self.onChange = onChange
        self.registrations = registrations
        self.listenerQueue = queue
        lock.unlock()
        refreshDeviceListeners(for: initialDeviceIDs)
    }

    public func stop() {
        lock.lock()
        let registrations = self.registrations
        self.registrations = []
        onChange = nil
        listenerQueue = nil
        lock.unlock()

        for registration in registrations {
            var address = registration.address
            _ = AudioObjectRemovePropertyListenerBlock(
                registration.objectID,
                &address,
                registration.queue,
                registration.listener
            )
        }
    }

    private func notifyChange() {
        lock.lock()
        let callback = onChange
        lock.unlock()
        guard let devices = try? currentDevices() else {
            return
        }
        refreshDeviceListeners(
            for: Set(devices.map { AudioDeviceID($0.deviceID) })
        )
        callback?(devices)
    }

    private func refreshDeviceListeners(for deviceIDs: Set<AudioDeviceID>) {
        lock.lock()
        guard let queue = listenerQueue,
              let globalRegistration = registrations.first else {
            lock.unlock()
            return
        }
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let existingDeviceIDs = Set(
            registrations
                .filter { $0.objectID != systemObjectID }
                .map(\.objectID)
        )
        let removed = registrations.filter {
            $0.objectID != systemObjectID && !deviceIDs.contains($0.objectID)
        }
        registrations.removeAll { registration in
            registration.objectID != systemObjectID
                && !deviceIDs.contains(registration.objectID)
        }
        lock.unlock()

        for registration in removed {
            var address = registration.address
            _ = AudioObjectRemovePropertyListenerBlock(
                registration.objectID,
                &address,
                registration.queue,
                registration.listener
            )
        }

        var additions: [Registration] = []
        for deviceID in deviceIDs.subtracting(existingDeviceIDs) {
            for property in Self.devicePropertyScopes {
                var address = AudioObjectPropertyAddress(
                    mSelector: property.selector,
                    mScope: property.scope,
                    mElement: kAudioObjectPropertyElementMain
                )
                guard AudioObjectAddPropertyListenerBlock(
                    deviceID,
                    &address,
                    queue,
                    globalRegistration.listener
                ) == noErr else {
                    continue
                }
                additions.append(Registration(
                    objectID: deviceID,
                    address: address,
                    queue: queue,
                    listener: globalRegistration.listener
                ))
            }
        }

        lock.lock()
        let isCurrent = listenerQueue === queue
        if isCurrent {
            registrations.append(contentsOf: additions)
        }
        lock.unlock()

        if !isCurrent {
            for registration in additions {
                var address = registration.address
                _ = AudioObjectRemovePropertyListenerBlock(
                    registration.objectID,
                    &address,
                    registration.queue,
                    registration.listener
                )
            }
        }
    }

    private static func makeDevice(
        _ deviceID: AudioDeviceID,
        isDefault: Bool
    ) -> OigoInputDevice? {
        guard let uid = readString(
            deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal
        ),
        let displayName = readString(
            deviceID,
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal
        ),
        let inputChannelCount = readInputChannelCount(deviceID),
        let nominalSampleRate = readDouble(
            deviceID,
            selector: kAudioDevicePropertyNominalSampleRate,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        ),
        let alive = readUInt32(
            deviceID,
            selector: kAudioDevicePropertyDeviceIsAlive,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        ) else {
            return nil
        }
        return OigoInputDevice(
            uid: uid,
            displayName: displayName,
            deviceID: UInt32(deviceID),
            inputChannelCount: inputChannelCount,
            nominalSampleRate: nominalSampleRate,
            isAlive: alive != 0,
            isDefault: isDefault
        )
    }

    private static func readDeviceID(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return nil
        }
        return value
    }

    private static func readDouble(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value = Double(0)
        var dataSize = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return nil
        }
        return value
    }

    private static func readUInt32(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return nil
        }
        return value
    }

    private static func readString(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr,
        let value else {
            return nil
        }
        return value.takeUnretainedValue() as String
    }

    private static func readInputChannelCount(_ deviceID: AudioDeviceID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }
        let streamBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { streamBuffer.deallocate() }
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            streamBuffer
        ) == noErr else {
            return nil
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            streamBuffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

@available(macOS 14.0, *)
public final class AudioRecorder: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let deviceMonitor: AudioDeviceMonitoring
    private let inputRouter: AudioInputDeviceRouting
    private let instrumentation: PerformanceInstrumentation
    private var engine: AVAudioEngine?
    private var preparedEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var audioFileDescriptor: AudioFileDescriptor?
    private var onBuffer: (@Sendable (AudioCaptureBuffer) -> Void)?
    private var onFinish: (@Sendable () -> Void)?
    private var onInterruption: (@Sendable (String) -> Void)?
    private var onFailure: (@Sendable (String) -> Void)?
    private var configurationObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var recording = false
    private var starting = false
    private var finishing = false
    private var pendingInterruptionReason: String?
    private var failureReported = false
    private var firstBufferReported = false
    private var selectedInput: OigoInputSelection = .systemDefault
    private var activeSelection: OigoInputSelection?
    private var activeDeviceUID: String?
    private var recordingFence = AudioRecordingOperationFence()

    public init(
        deviceMonitor: AudioDeviceMonitoring = SystemAudioDeviceMonitor(),
        inputRouter: AudioInputDeviceRouting = SystemAudioInputDeviceRouter(),
        instrumentation: PerformanceInstrumentation = OSLogPerformanceInstrumentation()
    ) {
        self.deviceMonitor = deviceMonitor
        self.inputRouter = inputRouter
        self.instrumentation = instrumentation
    }

    public func setInputSelection(_ selection: OigoInputSelection) {
        lock.lock()
        selectedInput = selection
        if !recording && !starting {
            activeSelection = selection
            preparedEngine = nil
        }
        lock.unlock()
    }

    public func captureFormat() throws -> AudioCaptureFormat {
        guard Bundle.main.bundleIdentifier != nil else {
            throw AudioRecorderError.missingApplicationBundle
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let preparation = try prepareInput(on: inputNode)
        let inputConfiguration = preparation.configuration
        lock.lock()
        preparedEngine = engine
        lock.unlock()
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
        let alreadyRecording = recording || starting || finishing
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

        lock.lock()
        let preparedEngine = self.preparedEngine
        self.preparedEngine = nil
        lock.unlock()
        let engine = preparedEngine ?? AVAudioEngine()
        let inputNode = engine.inputNode
        let preparation = try prepareInput(on: inputNode)
        let inputConfiguration = preparation.configuration
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
        starting = true
        pendingInterruptionReason = nil
        let recordingGeneration = recordingFence.begin()
        failureReported = false
        firstBufferReported = false
        lock.unlock()

        do {
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
                self?.handle(buffer, generation: recordingGeneration)
            }
            let observer = NotificationCenter.default.addObserver(
                forName: Notification.Name("AVAudioEngineConfigurationChangeNotification"),
                object: engine,
                queue: nil
            ) { [weak self] _ in
                self?.handleInterruption(
                    "audio input configuration changed",
                    generation: recordingGeneration
                )
            }
            lock.lock()
            configurationObserver = observer
            lock.unlock()
            deviceMonitor.start { [weak self] devices in
                self?.handleDeviceChange(devices, generation: recordingGeneration)
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
                    self?.handleInterruption(reason, generation: recordingGeneration)
                }
            }
            lock.lock()
            self.lifecycleObservers = lifecycleObservers
            lock.unlock()
            instrumentation.mark(.audioEngineStartBegin)
            defer { instrumentation.mark(.audioEngineStartEnd) }
            engine.prepare()
            try engine.start()
            lock.lock()
            let startupInterruption = pendingInterruptionReason
            pendingInterruptionReason = nil
            let startupIsCurrent = starting
                && recordingFence.accepts(recordingGeneration)
                && startupInterruption == nil
            if startupIsCurrent {
                starting = false
                recording = true
            }
            lock.unlock()
            if let startupInterruption {
                cancel()
                throw AudioRecorderError.engineStartFailed(startupInterruption)
            }
            guard startupIsCurrent else {
                throw AudioRecorderError.inputDeviceUnavailable
            }
        } catch {
            cancel()
            throw AudioRecorderError.engineStartFailed(String(describing: error))
        }
    }

    private func prepareInput(
        on inputNode: AVAudioInputNode
    ) throws -> (device: OigoInputDevice, configuration: InputConfiguration) {
        lock.lock()
        let selection = selectedInput
        if !recording {
            activeSelection = selection
        }
        lock.unlock()

        let devices = try deviceMonitor.currentDevices()
        do {
            var inputConfiguration: InputConfiguration?
            let device = try OigoInputDeviceCatalog.resolveAndRouteBeforeInspection(
                selection,
                from: devices,
                route: { [inputRouter] device in
                    try inputRouter.route(inputNode: inputNode, to: device.deviceID)
                },
                inspect: { _ in
                    guard let configuration = Self.inputConfiguration(for: inputNode),
                          configuration.channelCount == 1 else {
                        throw AudioRecorderError.invalidInputFormat
                    }
                    inputConfiguration = configuration
                }
            )
            guard let inputConfiguration else {
                throw AudioRecorderError.invalidInputFormat
            }
            lock.lock()
            activeDeviceUID = device.uid
            lock.unlock()
            return (device, inputConfiguration)
        } catch OigoInputDeviceResolutionError.pinnedInputUnavailable {
            throw AudioRecorderError.selectedInputUnavailable
        } catch OigoInputDeviceResolutionError.noAvailableInput {
            throw AudioRecorderError.inputDeviceUnavailable
        } catch let error as AudioRecorderError {
            throw error
        } catch {
            throw AudioRecorderError.inputDeviceRouteFailed
        }
    }

    private func handleDeviceChange(_ devices: [OigoInputDevice], generation: UInt64) {
        lock.lock()
        guard recordingFence.accepts(generation) else {
            lock.unlock()
            return
        }
        let activeSelection = self.activeSelection
        let activeDeviceUID = self.activeDeviceUID
        let recording = self.recording
        let starting = self.starting
        lock.unlock()
        guard recording || starting,
              let activeSelection,
              let activeDeviceUID else {
            return
        }
        let currentDevice = try? OigoInputDeviceCatalog.resolve(activeSelection, from: devices)
        guard currentDevice?.uid == activeDeviceUID else {
            handleInterruption(
                "audio input device changed; choose the source again before restarting",
                generation: generation
            )
            return
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

    private func handle(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            handleInterruption("microphone permission revoked", generation: generation)
            return
        }

        var callback: (@Sendable (AudioCaptureBuffer) -> Void)?
        var forwardedBuffer: AudioCaptureBuffer?
        var failure: (@Sendable (String) -> Void)?
        var failureDescription: String?
        var markFirstBuffer = false

        lock.lock()
        guard recording,
              recordingFence.accepts(generation),
              !failureReported,
              let audioFile else {
            lock.unlock()
            return
        }
        do {
            try audioFile.write(from: buffer)
            if !firstBufferReported {
                firstBufferReported = true
                markFirstBuffer = true
            }
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
            guard let resources = beginTeardown(expectedGeneration: generation) else {
                return
            }
            finish(resources) {
                failure(failureDescription)
            }
        } else if let callback, let forwardedBuffer {
            lock.lock()
            let isCurrentOperation = recording
                && recordingFence.accepts(generation)
                && !failureReported
            lock.unlock()
            guard isCurrentOperation else {
                return
            }
            if markFirstBuffer {
                instrumentation.mark(.firstAudioBuffer)
            }
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

    private static func inputConfiguration(
        for inputNode: AVAudioInputNode
    ) -> InputConfiguration? {
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate.isFinite,
              format.sampleRate > 0,
              format.channelCount > 0 else {
            return nil
        }
        return InputConfiguration(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount
        )
    }

    private func beginTeardown() -> TeardownResources? {
        beginTeardown(expectedGeneration: nil)
    }

    private func beginTeardown(expectedGeneration: UInt64?) -> TeardownResources? {
        lock.lock()
        guard recording || starting,
              expectedGeneration.map(recordingFence.accepts) ?? true else {
            lock.unlock()
            return nil
        }
        recording = false
        starting = false
        finishing = true
        pendingInterruptionReason = nil
        recordingFence.invalidate()
        firstBufferReported = false
        activeSelection = nil
        activeDeviceUID = nil
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

    private func handleInterruption(_ reason: String, generation: UInt64? = nil) {
        lock.lock()
        guard recording || starting,
              !failureReported,
              generation.map(recordingFence.accepts) ?? true else {
            lock.unlock()
            return
        }
        if starting {
            pendingInterruptionReason = pendingInterruptionReason ?? reason
            lock.unlock()
            return
        }
        let callback = onInterruption
        failureReported = true
        lock.unlock()

        guard let resources = beginTeardown(expectedGeneration: generation) else {
            return
        }
        finish(resources) {
            callback?(reason)
        }
    }

    private func finish(
        _ resources: TeardownResources,
        terminalCallback: (@Sendable () -> Void)? = nil
    ) {
        defer {
            lock.lock()
            finishing = false
            lock.unlock()
        }
        resources.engine?.inputNode.removeTap(onBus: 0)
        resources.engine?.stop()
        resources.onFinish?()
        terminalCallback?()
        resources.descriptor?.close()
    }
}

private struct TeardownResources {
    let engine: AVAudioEngine?
    let onFinish: (@Sendable () -> Void)?
    let descriptor: AudioFileDescriptor?
}
