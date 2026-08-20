import AVFAudio
import Foundation
import OigoCore

public final class OnboardingSourceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let deviceMonitor: AudioDeviceMonitoring
    private let inputRouter: AudioInputDeviceRouting
    private var engine: AVAudioEngine?
    private var adapter: CanonicalMonoAdapter?
    private var onUpdate: (@Sendable (OigoOnboardingSourceProbeUpdate) -> Void)?
    private var generation: UInt64 = 0
    private var running = false
    private var selectedInput: OigoInputSelection = .systemDefault
    private var selectedChannel: Int = OigoInputChannelPolicy.defaultIndex

    public init(
        deviceMonitor: AudioDeviceMonitoring = SystemAudioDeviceMonitor(),
        inputRouter: AudioInputDeviceRouting = SystemAudioInputDeviceRouter()
    ) {
        self.deviceMonitor = deviceMonitor
        self.inputRouter = inputRouter
    }

    deinit {
        stopLockedResources()
    }

    public func start(
        selection: OigoInputSelection,
        channel: Int,
        generation: UInt64,
        onUpdate: @escaping @Sendable (OigoOnboardingSourceProbeUpdate) -> Void
    ) {
        stop()
        lock.lock()
        self.generation = generation
        self.selectedInput = selection
        self.selectedChannel = OigoInputChannelPolicy.sanitized(channel)
        self.onUpdate = onUpdate
        running = true
        lock.unlock()

        do {
            try startEngine(generation: generation)
        } catch {
            emit(
                generation: generation,
                accepted: false,
                health: .silent,
                meterLevel: 0
            )
            stop()
        }
    }

    public func stop() {
        lock.lock()
        generation += 1
        running = false
        onUpdate = nil
        adapter = nil
        let engine = self.engine
        self.engine = nil
        lock.unlock()
        teardown(engine)
        deviceMonitor.stop()
    }

    private func startEngine(generation: UInt64) throws {
        guard Bundle.main.bundleIdentifier != nil else {
            throw AudioRecorderError.missingApplicationBundle
        }
        let permission = AVAudioApplication.shared.recordPermission
        guard permission == .granted else {
            throw AudioRecorderError.microphonePermission(String(describing: permission))
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let devices = try deviceMonitor.currentDevices()
        lock.lock()
        let selection = selectedInput
        let channel = selectedChannel
        lock.unlock()

        var routedChannelCount = 0
        let device = try OigoInputDeviceCatalog.resolveAndRouteBeforeInspection(
            selection,
            from: devices,
            route: { [inputRouter] device in
                try inputRouter.route(inputNode: inputNode, to: device.deviceID)
            },
            inspect: { _ in
                let format = inputNode.inputFormat(forBus: 0)
                guard format.sampleRate.isFinite,
                      format.sampleRate > 0,
                      format.channelCount > 0 else {
                    throw AudioRecorderError.invalidInputFormat
                }
                routedChannelCount = Int(format.channelCount)
                guard OigoInputChannelPolicy.isValid(channel, channelCount: routedChannelCount) else {
                    throw AudioRecorderError.selectedChannelUnavailable
                }
            }
        )
        _ = device
        let sourceFormat = inputNode.inputFormat(forBus: 0)
        let adapter = try CanonicalMonoAdapter(
            sourceFormat: sourceFormat,
            selectedChannel: channel
        )
        lock.lock()
        guard running, self.generation == generation else {
            lock.unlock()
            return
        }
        self.engine = engine
        self.adapter = adapter
        lock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
            self?.handle(buffer, generation: generation)
        }
        try engine.start()
        deviceMonitor.start { [weak self] devices in
            self?.handleDeviceChange(devices, generation: generation)
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        lock.lock()
        guard running, self.generation == generation, let adapter else {
            lock.unlock()
            return
        }
        let selection = selectedInput
        let channel = selectedChannel
        lock.unlock()

        guard let converted = try? adapter.convert(buffer),
              converted.frameLength > 0,
              let samples = converted.floatChannelData?.pointee else {
            return
        }
        let frameCount = Int(converted.frameLength)
        var peak: Float = 0
        for index in 0..<frameCount {
            peak = max(peak, abs(samples[index]))
        }
        let health = OigoOnboardingSignalHealth.classify(peakAbsolute: peak)
        let capture = AudioCaptureBuffer(
            frameCount: frameCount,
            sampleRate: adapter.canonicalCaptureFormat.sampleRate,
            channelCount: 1,
            pcmData: Data(count: frameCount * MemoryLayout<Float>.size)
        )
        emit(
            generation: generation,
            usedInput: selection,
            usedChannel: channel,
            accepted: OigoOnboardingEvidenceMachine.isUsableCanonicalBuffer(capture),
            health: health,
            meterLevel: min(1, peak)
        )
    }

    private func handleDeviceChange(_ devices: [OigoInputDevice], generation: UInt64) {
        lock.lock()
        guard running, self.generation == generation else {
            lock.unlock()
            return
        }
        let selection = selectedInput
        lock.unlock()
        do {
            _ = try OigoInputDeviceCatalog.resolve(selection, from: devices)
        } catch {
            emit(
                generation: generation,
                accepted: false,
                health: .silent,
                meterLevel: 0
            )
            stop()
        }
    }

    private func emit(
        generation: UInt64,
        usedInput: OigoInputSelection? = nil,
        usedChannel: Int? = nil,
        accepted: Bool,
        health: OigoOnboardingSignalHealth,
        meterLevel: Float
    ) {
        lock.lock()
        guard running, self.generation == generation, let onUpdate else {
            lock.unlock()
            return
        }
        let update = OigoOnboardingSourceProbeUpdate(
            generation: generation,
            usedInput: usedInput ?? selectedInput,
            usedChannel: usedChannel ?? selectedChannel,
            acceptedCanonicalBuffer: accepted,
            signalHealth: health,
            meterLevel: meterLevel
        )
        lock.unlock()
        onUpdate(update)
    }

    private func teardown(_ engine: AVAudioEngine?) {
        guard let engine else {
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
    }

    private func stopLockedResources() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        adapter = nil
        onUpdate = nil
        running = false
        deviceMonitor.stop()
    }
}
