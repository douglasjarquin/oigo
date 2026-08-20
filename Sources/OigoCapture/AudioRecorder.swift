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
    case selectedChannelUnavailable
    case captureFailed(String)
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
        case .selectedChannelUnavailable:
            "the selected input channel is not available on this microphone; choose another channel in Settings"
        case .captureFailed(let reason):
            reason
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

        let deviceIDByteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard dataSize % deviceIDByteCount == 0 else {
            throw AudioRecorderError.inputDeviceUnavailable
        }
        let deviceCount = Int(dataSize / deviceIDByteCount)
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
        guard dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
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
        let bufferList = streamBuffer.assumingMemoryBound(to: AudioBufferList.self)
        let bufferCount = Int(bufferList.pointee.mNumberBuffers)
        guard bufferCount > 0,
              let bufferOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers) else {
            return nil
        }
        let (bufferBytes, bufferBytesOverflow) = bufferCount.multipliedReportingOverflow(
            by: MemoryLayout<AudioBuffer>.stride
        )
        let (requiredSize, requiredSizeOverflow) = bufferOffset.addingReportingOverflow(bufferBytes)
        guard !bufferBytesOverflow,
              !requiredSizeOverflow,
              requiredSize <= Int(dataSize) else {
            return nil
        }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

@available(macOS 14.0, *)
public final class AudioRecorder: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let deviceMonitor: AudioDeviceMonitoring
    private let inputRouter: AudioInputDeviceRouting
    private let instrumentation: PerformanceInstrumentation
    private let callbackDeliveryGate = AudioRecordingCallbackGate()
    private let controlQueue = DispatchQueue(label: "com.oigo.capture.control")
    private var engine: AVAudioEngine?
    private var preparedEngine: AVAudioEngine?
    private var pipeline: CapturePipeline?
    private var configurationObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var recording = false
    private var starting = false
    private var finishing = false
    private var terminalWaiters = 0
    private var pendingInterruptionReason: String?
    private var failureReported = false
    private var latchedTerminal: LatchedTerminal?
    private var boundPipelineGeneration: UInt64 = 0
    private var selectedInput: OigoInputSelection = .systemDefault
    private var selectedChannel: Int = OigoInputChannelPolicy.defaultIndex
    private var activeSelection: OigoInputSelection?
    private var activeDeviceUID: String?
    private var recordingFence = AudioRecordingOperationFence()
    private var preparedInput: PreparedInput?

    public init(
        deviceMonitor: AudioDeviceMonitoring = SystemAudioDeviceMonitor(),
        inputRouter: AudioInputDeviceRouting = SystemAudioInputDeviceRouter(),
        instrumentation: PerformanceInstrumentation = OSLogPerformanceInstrumentation()
    ) {
        self.deviceMonitor = deviceMonitor
        self.inputRouter = inputRouter
        self.instrumentation = instrumentation
    }

    public func setInputSelection(
        _ selection: OigoInputSelection,
        channel: Int = OigoInputChannelPolicy.defaultIndex
    ) {
        lock.lock()
        selectedInput = selection
        selectedChannel = OigoInputChannelPolicy.sanitized(channel)
        if !recording && !starting {
            activeSelection = selection
            preparedEngine = nil
            preparedInput = nil
        }
        lock.unlock()
    }

    public func captureFormat() throws -> AudioCaptureFormat {
        guard Bundle.main.bundleIdentifier != nil else {
            throw AudioRecorderError.missingApplicationBundle
        }

        lock.lock()
        let unavailable = recording || starting || finishing
        lock.unlock()
        guard !unavailable else {
            throw AudioRecorderError.alreadyRecording
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let preparation = try prepareInput(on: inputNode)
        let inputConfiguration = preparation.configuration
        lock.lock()
        guard !recording, !starting, !finishing else {
            lock.unlock()
            throw AudioRecorderError.alreadyRecording
        }
        preparedEngine = engine
        preparedInput = PreparedInput(
            selection: preparation.selection,
            deviceUID: preparation.device.uid,
            configuration: inputConfiguration,
            selectedChannel: preparation.selectedChannel
        )
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
        let recordingGeneration = try claimStart()
        var startCompleted = false
        defer {
            if !startCompleted {
                cancel()
            }
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
        let preparedInput = self.preparedInput
        self.preparedInput = nil
        lock.unlock()
        let engine = preparedEngine ?? AVAudioEngine()
        let inputNode = engine.inputNode
        let preparation: (
            device: OigoInputDevice,
            configuration: InputConfiguration,
            selectedChannel: Int
        )
        if let preparedInput {
            let resolved = try resolvePreparedInput(preparedInput, on: inputNode)
            preparation = (resolved.device, resolved.configuration, preparedInput.selectedChannel)
        } else {
            let fullPreparation = try prepareInput(on: inputNode)
            preparation = (
                fullPreparation.device,
                fullPreparation.configuration,
                fullPreparation.selectedChannel
            )
        }
        let inputConfiguration = preparation.configuration
        let sourceFormat = inputNode.inputFormat(forBus: 0)
        guard sourceFormat.sampleRate == inputConfiguration.sampleRate,
              sourceFormat.channelCount == inputConfiguration.channelCount else {
            throw AudioRecorderError.invalidInputFormat
        }
        let adapter: CanonicalMonoAdapter
        do {
            adapter = try CanonicalMonoAdapter(
                sourceFormat: sourceFormat,
                selectedChannel: preparation.selectedChannel
            )
        } catch CanonicalMonoAdapterError.selectedChannelOutOfRange {
            throw AudioRecorderError.selectedChannelUnavailable
        } catch {
            throw AudioRecorderError.invalidInputFormat
        }
        let canonicalFormat = adapter.canonicalCaptureFormat
        guard canonicalFormat.isCanonicalMono else {
            throw AudioRecorderError.invalidInputFormat
        }

        let writer: CAFWriter
        do {
            writer = try CAFWriter(descriptor: descriptor, format: adapter.outputFormat)
        } catch let error as CAFWriterError {
            throw AudioRecorderError.engineStartFailed(error.description)
        } catch {
            throw AudioRecorderError.engineStartFailed(String(describing: error))
        }
        retained = true

        let pipeline = CapturePipeline(
            generation: recordingGeneration,
            adapter: adapter,
            writer: writer,
            instrumentation: instrumentation,
            onBuffer: onBuffer,
            onFinish: onFinish,
            onInterruption: { [weak self] reason in
                self?.latchTerminal(.interrupt(reason), generation: recordingGeneration)
                onInterruption(reason)
            },
            onFailure: { [weak self] reason in
                self?.latchTerminal(.failure(reason), generation: recordingGeneration)
                onFailure(reason)
            },
            teardownHandler: { [weak self] in
                self?.beginEngineTeardown()
            },
            onTerminalized: { [weak self] in
                guard let self else {
                    return
                }
                self.lock.lock()
                let current = self.pipeline
                self.lock.unlock()
                guard let current else {
                    return
                }
                self.markCaptureIdle(generation: recordingGeneration, pipeline: current)
            },
            permissionCheck: {
                AVAudioApplication.shared.recordPermission == .granted
            }
        )

        lock.lock()
        guard starting && recordingFence.accepts(recordingGeneration) else {
            lock.unlock()
            pipeline.cancelAndWait()
            throw AudioRecorderError.inputDeviceUnavailable
        }
        self.engine = engine
        self.pipeline = pipeline
        boundPipelineGeneration = recordingGeneration
        pendingInterruptionReason = nil
        failureReported = false
        latchedTerminal = nil
        lock.unlock()

        do {
            let startupInterruption = try callbackDeliveryGate.performExclusively { () -> String? in
                inputNode.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
                    self?.handle(buffer, generation: recordingGeneration)
                }
                let observer = NotificationCenter.default.addObserver(
                    forName: Notification.Name("AVAudioEngineConfigurationChangeNotification"),
                    object: engine,
                    queue: nil
                ) { [weak self] _ in
                    guard let recorder = self else {
                        return
                    }
                    recorder.controlQueue.async {
                        recorder.handleInterruption(
                            "audio input configuration changed",
                            generation: recordingGeneration
                        )
                    }
                }
                lock.lock()
                configurationObserver = observer
                lock.unlock()
                deviceMonitor.start { [weak self] devices in
                    guard let recorder = self else {
                        return
                    }
                    recorder.controlQueue.async {
                        recorder.handleDeviceChange(devices, generation: recordingGeneration)
                    }
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
                        guard let recorder = self else {
                            return
                        }
                        recorder.controlQueue.async {
                            recorder.handleInterruption(reason, generation: recordingGeneration)
                        }
                    }
                }
                lock.lock()
                self.lifecycleObservers = lifecycleObservers
                lock.unlock()
                instrumentation.mark(.audioEngineStartBegin)
                defer { instrumentation.mark(.audioEngineStartEnd) }
                engine.prepare()
                try engine.start()
                return applyEngineStartResult(generation: recordingGeneration)
            }
            if let startupInterruption {
                terminalize(.interrupt(startupInterruption), generation: recordingGeneration)
                return
            }
            startCompleted = true
        } catch {
            cancel()
            throw AudioRecorderError.engineStartFailed(String(describing: error))
        }
    }

    private func claimStart() throws -> UInt64 {
        let generation: UInt64? = callbackDeliveryGate.performExclusively {
            lock.lock()
            defer { lock.unlock() }
            guard !recording, !starting, !finishing else {
                return nil
            }
            starting = true
            pendingInterruptionReason = nil
            failureReported = false
            latchedTerminal = nil
            return recordingFence.begin()
        }
        guard let generation else {
            throw AudioRecorderError.alreadyRecording
        }
        return generation
    }

    private func prepareInput(
        on inputNode: AVAudioInputNode
    ) throws -> (
        device: OigoInputDevice,
        configuration: InputConfiguration,
        selection: OigoInputSelection,
        selectedChannel: Int
    ) {
        lock.lock()
        let selection = selectedInput
        let channel = selectedChannel
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
                    guard let configuration = Self.inputConfiguration(for: inputNode) else {
                        throw AudioRecorderError.invalidInputFormat
                    }
                    guard OigoInputChannelPolicy.isValid(
                        channel,
                        channelCount: Int(configuration.channelCount)
                    ) else {
                        throw AudioRecorderError.selectedChannelUnavailable
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
            return (device, inputConfiguration, selection, channel)
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

    private func resolvePreparedInput(
        _ preparedInput: PreparedInput,
        on inputNode: AVAudioInputNode
    ) throws -> (device: OigoInputDevice, configuration: InputConfiguration) {
        let devices = try deviceMonitor.currentDevices()
        let visibleDevices = OigoInputDeviceCatalog.visibleDevices(from: devices)
        guard let device = visibleDevices.first(where: { $0.uid == preparedInput.deviceUID }) else {
            switch preparedInput.selection {
            case .systemDefault:
                throw AudioRecorderError.inputDeviceUnavailable
            case .pinned:
                throw AudioRecorderError.selectedInputUnavailable
            }
        }
        try inputRouter.route(inputNode: inputNode, to: device.deviceID)
        lock.lock()
        activeDeviceUID = device.uid
        lock.unlock()
        return (device, preparedInput.configuration)
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
        if let reason = latchedFailureReason() {
            throw AudioRecorderError.captureFailed(reason)
        }
        terminalize(.userStop, generation: nil)
        if let reason = latchedFailureReason() {
            throw AudioRecorderError.captureFailed(reason)
        }
    }

    public func cancel() {
        terminalize(.cancel, generation: nil)
    }

    private func handle(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        lock.lock()
        guard recording,
              recordingFence.accepts(generation),
              !failureReported,
              let pipeline else {
            lock.unlock()
            return
        }
        lock.unlock()
        switch pipeline.tryAccept(buffer, generation: generation) {
        case .overflow:
            latchTerminal(
                .failure(CapturePipelineFailure.overflow.rawValue),
                generation: generation
            )
        case .conversionFailed:
            latchTerminal(
                .failure("microphone input could not be converted to canonical mono"),
                generation: generation
            )
        case .accepted, .ignored:
            break
        }
    }

    private struct InputConfiguration {
        let sampleRate: Double
        let channelCount: UInt32
    }

    private struct PreparedInput {
        let selection: OigoInputSelection
        let deviceUID: String
        let configuration: InputConfiguration
        let selectedChannel: Int
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

    private enum TerminalAction {
        case userStop
        case cancel
        case interrupt(String)
    }

    private enum LatchedTerminal: Equatable {
        case failure(String)
        case interrupt(String)
    }

    private enum TerminalClaim {
        case won(CapturePipeline, UInt64)
        case engineOnly(UInt64)
        case alreadyFinishing
        case idle
    }

    private func applyEngineStartResult(generation: UInt64) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let reason = pendingInterruptionReason
        pendingInterruptionReason = nil
        let startupIsCurrent = starting
            && recordingFence.accepts(generation)
            && reason == nil
        if startupIsCurrent {
            starting = false
            recording = true
        }
        return reason
    }

    private func latchedFailureReason() -> String? {
        lock.lock()
        defer { lock.unlock() }
        switch latchedTerminal {
        case .failure(let reason), .interrupt(let reason):
            return reason
        case .none:
            return nil
        }
    }

    private func latchTerminal(_ terminal: LatchedTerminal, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard recordingFence.accepts(generation) || boundPipelineGeneration == generation else {
            return
        }
        if latchedTerminal == nil {
            latchedTerminal = terminal
        }
        failureReported = true
        recording = false
        starting = false
        finishing = true
    }

    private func terminalize(
        _ action: TerminalAction,
        generation: UInt64?
    ) {
        let claim: TerminalClaim = callbackDeliveryGate.performExclusively {
            lock.lock()
            defer { lock.unlock() }
            if let generation, !recordingFence.accepts(generation) {
                return .idle
            }
            if finishing {
                return .alreadyFinishing
            }
            guard recording || starting else {
                return .idle
            }
            recording = false
            starting = false
            finishing = true
            terminalWaiters += 1
            pendingInterruptionReason = nil
            activeSelection = nil
            activeDeviceUID = nil
            guard let pipeline else {
                return .engineOnly(boundPipelineGeneration)
            }
            return .won(pipeline, boundPipelineGeneration)
        }
        switch claim {
        case .alreadyFinishing, .idle:
            return
        case .engineOnly(let pipelineGeneration):
            teardownEngineAndObservers()
            finishTerminalWait(generation: pipelineGeneration, pipeline: nil)
        case .won(let pipeline, let pipelineGeneration):
            switch action {
            case .userStop:
                pipeline.stopAndWait()
            case .cancel:
                pipeline.cancelAndWait()
            case .interrupt(let reason):
                latchTerminal(.interrupt(reason), generation: pipelineGeneration)
                pipeline.interruptAndWait(reason)
            }
            finishTerminalWait(generation: pipelineGeneration, pipeline: pipeline)
        }
    }

    private func finishTerminalWait(generation: UInt64, pipeline: CapturePipeline?) {
        lock.lock()
        terminalWaiters = max(0, terminalWaiters - 1)
        if terminalWaiters == 0 {
            if pipeline == nil || self.pipeline === pipeline {
                self.pipeline = nil
            }
            finishing = false
            if recordingFence.accepts(generation) {
                recordingFence.invalidate()
            }
        }
        lock.unlock()
    }

    private func markCaptureIdle(generation: UInt64, pipeline: CapturePipeline) {
        lock.lock()
        defer { lock.unlock() }
        guard self.pipeline === pipeline else {
            return
        }
        self.pipeline = nil
        recording = false
        starting = false
        if terminalWaiters == 0 {
            finishing = false
            if recordingFence.accepts(generation) {
                recordingFence.invalidate()
            }
        }
    }

    private func beginEngineTeardown() {
        lock.lock()
        recording = false
        starting = false
        lock.unlock()
        teardownEngineAndObservers()
    }

    private func teardownEngineAndObservers() {
        let engineAndObservers: (
            engine: AVAudioEngine?,
            configurationObserver: NSObjectProtocol?,
            lifecycleObservers: [NSObjectProtocol]
        ) = callbackDeliveryGate.performExclusively {
            lock.lock()
            let engine = self.engine
            self.engine = nil
            let configurationObserver = self.configurationObserver
            self.configurationObserver = nil
            let lifecycleObservers = self.lifecycleObservers
            self.lifecycleObservers = []
            lock.unlock()
            return (engine, configurationObserver, lifecycleObservers)
        }
        if let observer = engineAndObservers.configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in engineAndObservers.lifecycleObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        deviceMonitor.stop()
        engineAndObservers.engine?.inputNode.removeTap(onBus: 0)
        engineAndObservers.engine?.stop()
        engineAndObservers.engine?.reset()
    }

    private func handleInterruption(_ reason: String, generation: UInt64? = nil) {
        lock.lock()
        guard recording || starting,
              generation.map(recordingFence.accepts) ?? true else {
            lock.unlock()
            return
        }
        if starting {
            pendingInterruptionReason = pendingInterruptionReason ?? reason
            lock.unlock()
            return
        }
        lock.unlock()
        terminalize(.interrupt(reason), generation: generation)
    }

    @_spi(Testing)
    public var testIsStarting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return starting
    }

    @_spi(Testing)
    public var testIsFinishing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finishing
    }

    @_spi(Testing)
    public var testLatchedFailure: String? {
        lock.lock()
        defer { lock.unlock() }
        switch latchedTerminal {
        case .failure(let reason), .interrupt(let reason):
            return reason
        case .none:
            return nil
        }
    }

    @_spi(Testing)
    public func testClaimStart() throws -> UInt64 {
        try claimStart()
    }

    @_spi(Testing)
    public func testInstallPipeline(_ pipeline: CapturePipeline, recording: Bool = false) {
        lock.lock()
        self.pipeline = pipeline
        boundPipelineGeneration = pipeline.generation
        failureReported = false
        latchedTerminal = nil
        if recording {
            starting = false
            self.recording = true
        }
        lock.unlock()
    }

    @_spi(Testing)
    public func testNotifyFailure(_ reason: String, generation: UInt64) {
        latchTerminal(.failure(reason), generation: generation)
    }

    @_spi(Testing)
    public func testBeginEngineTeardown() {
        beginEngineTeardown()
    }

    @_spi(Testing)
    public func testNotifyTerminalized(generation: UInt64) {
        lock.lock()
        let pipeline = self.pipeline
        lock.unlock()
        guard let pipeline else {
            return
        }
        markCaptureIdle(generation: generation, pipeline: pipeline)
    }

    @_spi(Testing)
    public func testNoteInterruption(_ reason: String, generation: UInt64) {
        handleInterruption(reason, generation: generation)
    }

    @_spi(Testing)
    public func testApplyEngineStart(generation: UInt64) {
        if let reason = applyEngineStartResult(generation: generation) {
            terminalize(.interrupt(reason), generation: generation)
        }
    }
}
