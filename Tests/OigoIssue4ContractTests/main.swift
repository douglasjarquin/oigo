import AVFAudio
import Foundation
import OigoCore
import OigoCapture

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
@MainActor
private struct OigoIssue4ContractTests {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let filter: String? = if let index = arguments.firstIndex(of: "--filter"),
                                     arguments.indices.contains(index + 1) {
            arguments[index + 1]
        } else {
            nil
        }
        let normalizedFilter = filter?.replacingOccurrences(of: "-", with: " ")
        let tests: [(String, () async throws -> Void)] = [
            ("session store atomic metadata", testSessionStoreAtomicMetadata),
            ("recovery preserves audio", testRecoveryPreservesAudio),
            ("session discoverability", testSessionDiscoverability),
            ("session metadata path safety", testSessionMetadataPathSafety),
            ("descriptor-bound live capture", testDescriptorBoundLiveCapture),
            ("lifecycle teardown", testLifecycleTeardown),
            ("capture buffer forwarding", testCaptureBufferForwarding),
            ("100 start-stop cycles", testStartStopCycles),
            ("actionable capture failure", testActionableCaptureFailure),
            ("interruption recovery", testInterruptionRecovery),
            ("playback verification", testPlaybackVerification),
            ("shutdown retention", testShutdownRetention),
            ("actionable host failure", testActionableHostFailure)
        ]

        var failures = 0
        for (name, test) in tests where normalizedFilter == nil || name.contains(normalizedFilter ?? "") {
            do {
                try await test()
                print("GREEN: " + name)
            } catch {
                failures += 1
                print("FAIL: " + name + ": " + String(describing: error))
            }
        }

        if failures == 0 {
            print("GREEN: all issue #4 contract scenarios")
            exit(0)
        }

        print("FAILURES=" + String(failures))
        exit(1)
    }

    private static func testSessionStoreAtomicMetadata() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        var session = try store.createSession(now: Date(timeIntervalSince1970: 1_000))

        guard FileManager.default.fileExists(atPath: session.metadataURL.path) else {
            throw ContractFailure(message: "session metadata was not created before capture")
        }

        for offset in 0..<100 {
            session = try store.update(
                session,
                state: .recording,
                at: Date(timeIntervalSince1970: 1_000 + Double(offset))
            )
            let data = try Data(contentsOf: session.metadataURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            _ = try decoder.decode(SessionMetadata.self, from: data)
        }
    }

    private static func testRecoveryPreservesAudio() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        var session = try store.createSession(now: Date(timeIntervalSince1970: 2_000))
        session = try store.update(
            session,
            state: .recording,
            at: Date(timeIntervalSince1970: 2_001)
        )
        try Data([0, 1, 2, 3]).write(to: session.audioURL)

        let recovered = try store.recoverUnfinishedSessions(at: Date(timeIntervalSince1970: 2_100))
        guard recovered.count == 1,
              recovered[0].metadata.state == .interrupted,
              FileManager.default.fileExists(atPath: session.audioURL.path) else {
            throw ContractFailure(message: "recovery did not preserve audio and mark the session interrupted")
        }
    }

    private static func testSessionDiscoverability() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let first = try store.createSession(now: Date(timeIntervalSince1970: 3_000))
        let second = try store.createSession(now: Date(timeIntervalSince1970: 3_001))

        let sessions = try store.listSessions()
        guard sessions.contains(where: { $0.id == first.id }),
              first.audioURL.lastPathComponent == "audio.caf",
              first.rawTextURL.lastPathComponent == "raw.txt",
              first.cleanTextURL.lastPathComponent == "clean.txt" else {
            throw ContractFailure(message: "session model did not expose discoverable modeled paths")
        }

        try store.remove(id: first.id)
        guard FileManager.default.fileExists(atPath: root.path),
              try store.load(id: second.id).id == second.id else {
            throw ContractFailure(message: "removing one session removed the store root or another session")
        }
    }

    private static func testLifecycleTeardown() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let coordinator = DictationCoordinator()
        let session = try coordinator.startRecording(
            using: capture,
            store: store,
            now: Date(timeIntervalSince1970: 4_000)
        )
        capture.sendBuffer()
        try coordinator.stopRecording(at: Date(timeIntervalSince1970: 4_001))

        let saved = try store.load(id: session.id)
        guard coordinator.state == .complete,
              !capture.isActive,
              capture.streamFinished,
              saved.metadata.state == .completed,
              saved.metadata.duration == 1 else {
            throw ContractFailure(message: "stop did not finish capture resources and persist completion")
        }
    }

    private static func testSessionMetadataPathSafety() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let session = try store.createSession(now: Date(timeIntervalSince1970: 3_500))
        let originalData = try Data(contentsOf: session.metadataURL)
        var metadataObject = try JSONSerialization.jsonObject(with: originalData) as! [String: Any]
        metadataObject["audioFileName"] = "../outside.caf"
        let mutatedData = try JSONSerialization.data(withJSONObject: metadataObject, options: [.sortedKeys])
        try mutatedData.write(to: session.metadataURL, options: [.atomic])

        do {
            _ = try store.load(id: session.id)
            throw ContractFailure(message: "session metadata accepted a filename outside the session directory")
        } catch let error as SessionStoreError {
            guard case .invalidMetadata = error else {
                throw ContractFailure(message: "unexpected metadata validation error: " + String(describing: error))
            }
        }

        try originalData.write(to: session.metadataURL, options: [.atomic])
        let outsideRoot = root.deletingLastPathComponent().appendingPathComponent(
            "oigo-issue4-outside-" + UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        let outsideSession = outsideRoot.appendingPathComponent("linked-session", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideSession, withIntermediateDirectories: true)
        let outsideMetadata = SessionMetadata(
            id: UUID(),
            directoryName: "linked-session",
            createdAt: Date(timeIntervalSince1970: 3_500),
            updatedAt: Date(timeIntervalSince1970: 3_500),
            state: .completed
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(outsideMetadata).write(
            to: outsideSession.appendingPathComponent("session.json"),
            options: [.atomic]
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-session"),
            withDestinationURL: outsideSession
        )

        do {
            _ = try store.listSessions()
            throw ContractFailure(message: "symlinked session directory escaped the store root")
        } catch let error as SessionStoreError {
            guard case .invalidSessionDirectory = error else {
                throw ContractFailure(message: "unexpected symlink validation error: " + String(describing: error))
            }
        }
    }

    private static func testDescriptorBoundLiveCapture() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("oigo-issue4-recorder-outside-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside sentinel".utf8).write(to: outside, options: [.atomic])

        let capture = DescriptorAwareAudioCapture(outsideURL: outside, store: store)
        let coordinator = DictationCoordinator()
        let session = try coordinator.startRecording(using: capture, store: store)
        let completed = try coordinator.stopRecording()
        guard capture.secureStartCalled,
              try Data(contentsOf: outside) == Data("outside sentinel".utf8),
              completed.metadata.audioByteCount == 0,
              (try? store.load(id: session.id).metadata.state) == .completed else {
            throw ContractFailure(message: "live capture did not use the root-bound descriptor seam")
        }
    }

    private static func testStartStopCycles() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let coordinator = DictationCoordinator()
        let capture = FakeAudioCapture()

        for index in 0..<100 {
            let start = Date(timeIntervalSince1970: 5_000 + Double(index * 2))
            _ = try coordinator.startRecording(using: capture, store: store, now: start)
            capture.sendBuffer()
            try coordinator.stopRecording(at: start.addingTimeInterval(1))
            guard !capture.isActive, capture.streamFinished else {
                throw ContractFailure(message: "capture resource remained active at cycle " + String(index))
            }
        }
    }

    private static func testCaptureBufferForwarding() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let coordinator = DictationCoordinator()
        let receipt = BufferReceipt()
        _ = try coordinator.startRecording(
            using: capture,
            store: store,
            onBuffer: { buffer in
                receipt.buffer = buffer
            }
        )
        capture.sendBuffer(frames: 512)

        guard receipt.buffer?.frameCount == 512,
              receipt.buffer?.channelCount == 1,
              receipt.buffer?.pcmData.isEmpty == false else {
            throw ContractFailure(message: "capture did not forward the recorded buffer to its consumer")
        }
        _ = try coordinator.cancelRecording()
    }

    private static func testActionableCaptureFailure() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let coordinator = DictationCoordinator()
        let session = try coordinator.startRecording(using: capture, store: store)
        capture.fail("input device was unplugged")
        await Task.yield()

        let saved = try store.load(id: session.id)
        guard coordinator.state == .failed,
              saved.metadata.state == .failed,
              saved.metadata.failureReason?.contains("unplugged") == true,
              !capture.isActive else {
            throw ContractFailure(message: "capture failure was not actionable or did not release resources")
        }
    }

    private static func testInterruptionRecovery() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let coordinator = DictationCoordinator()
        let session = try coordinator.startRecording(using: capture, store: store)
        capture.interrupt("audio input configuration changed")
        await Task.yield()

        let saved = try store.load(id: session.id)
        guard coordinator.state == .interrupted,
              saved.metadata.state == .interrupted,
              saved.metadata.failureReason?.contains("configuration") == true,
              !capture.isActive else {
            throw ContractFailure(message: "audio interruption did not preserve and release the session")
        }
    }

    private static func testPlaybackVerification() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = CAFTestAudioCapture()
        let coordinator = DictationCoordinator()
        let session = try coordinator.startRecording(using: capture, store: store)
        capture.sendBuffer(frames: 1_600)
        try coordinator.stopRecording()

        let frames = try AudioPlayback.playableFrameLength(at: session.audioURL)
        guard frames > 0 else {
            throw ContractFailure(message: "completed CAF was not playable")
        }
    }

    private static func testShutdownRetention() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let coordinator = DictationCoordinator()
        let session = try coordinator.startRecording(using: capture, store: store)
        let cancelled = try coordinator.cancelRecording()

        guard session.id == cancelled.id,
              cancelled.metadata.state == .cancelled,
              FileManager.default.fileExists(atPath: cancelled.directoryURL.path),
              !capture.isActive else {
            throw ContractFailure(message: "cancelled session was not retained or capture was not released")
        }

        let second = try coordinator.startRecording(using: capture, store: store)
        coordinator.shutdown()
        let interrupted = try store.load(id: second.id)

        guard interrupted.metadata.state == .interrupted,
              FileManager.default.fileExists(atPath: interrupted.directoryURL.path) else {
            throw ContractFailure(message: "interrupted shutdown session was not retained")
        }
    }

    private static func testActionableHostFailure() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let session = try store.createSession()
        let descriptor = try store.createAudioFileDescriptor(for: session)
        let recorder = AudioRecorder()

        do {
            try recorder.start(
                to: descriptor,
                onBuffer: { _ in },
                onFinish: {},
                onInterruption: { _ in },
                onFailure: { _ in }
            )
            recorder.cancel()
            print("host_boundary_capture=started")
            guard !recorder.isRecording else {
                throw ContractFailure(message: "successful capture did not release recorder resources")
            }
        } catch let error as AudioRecorderError {
            let description = error.description
            print("host_boundary_error=" + description)
            guard description.contains("microphone") || description.contains("application bundle") else {
                throw ContractFailure(message: "microphone failure was not actionable: " + description)
            }
            guard !recorder.isRecording else {
                throw ContractFailure(message: "failed capture left recorder active")
            }
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue4-contract-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
        print("CLEANUP: removed " + root.path)
    }
}

private final class BufferReceipt: @unchecked Sendable {
    var buffer: AudioCaptureBuffer?
}

private final class FakeAudioCapture: AudioCapturing, @unchecked Sendable {
    private var onBuffer: (@Sendable (AudioCaptureBuffer) -> Void)?
    private var onFinish: (@Sendable () -> Void)?
    private var onInterruption: (@Sendable (String) -> Void)?
    private var onFailure: (@Sendable (String) -> Void)?

    private(set) var isActive = false
    private(set) var streamFinished = false

    func start(
        to descriptor: AudioFileDescriptor,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        descriptor.close()
        self.onBuffer = onBuffer
        self.onFinish = onFinish
        self.onInterruption = onInterruption
        self.onFailure = onFailure
        isActive = true
        streamFinished = false
    }

    func stop() throws {
        finish()
    }

    func cancel() {
        finish()
    }

    func sendBuffer(frames: Int = 1) {
        onBuffer?(
            AudioCaptureBuffer(
                frameCount: frames,
                sampleRate: 16_000,
                channelCount: 1,
                pcmData: Data(repeating: 0, count: frames * 2)
            )
        )
    }

    func fail(_ message: String) {
        onFailure?(message)
    }

    func interrupt(_ reason: String) {
        onInterruption?(reason)
    }

    private func finish() {
        guard isActive else {
            return
        }
        isActive = false
        streamFinished = true
        onFinish?()
        onBuffer = nil
        onFinish = nil
        onInterruption = nil
        onFailure = nil
    }
}

private final class DescriptorAwareAudioCapture: AudioCapturing, @unchecked Sendable {
    private let outsideURL: URL
    private let store: SessionStore
    private var onFinish: (@Sendable () -> Void)?
    private(set) var secureStartCalled = false
    private(set) var isActive = false

    init(outsideURL: URL, store: SessionStore) {
        self.outsideURL = outsideURL
        self.store = store
    }

    func start(
        to descriptor: AudioFileDescriptor,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        _ = descriptor.rawValue
        _ = onBuffer
        _ = onInterruption
        _ = onFailure
        guard let audioURL = try store.listSessions().first?.audioURL else {
            throw ContractFailure(message: "descriptor fixture could not locate the active session audio")
        }
        try FileManager.default.removeItem(at: audioURL)
        try Data(contentsOf: outsideURL).write(to: audioURL, options: [.atomic])
        descriptor.close()
        secureStartCalled = true
        self.onFinish = onFinish
        isActive = true
    }

    func stop() throws {
        guard isActive else {
            throw ContractFailure(message: "descriptor capture stopped while idle")
        }
        isActive = false
        onFinish?()
        onFinish = nil
    }

    func cancel() {
        isActive = false
        onFinish = nil
    }
}

private final class CAFTestAudioCapture: AudioCapturing, @unchecked Sendable {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var file: AVAudioFile?
    private var descriptor: AudioFileDescriptor?
    private var onBuffer: (@Sendable (AudioCaptureBuffer) -> Void)?
    private var onFinish: (@Sendable () -> Void)?
    private(set) var isActive = false

    func start(
        to descriptor: AudioFileDescriptor,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        _ = onInterruption
        _ = onFailure
        self.onBuffer = onBuffer
        do {
            file = try AVAudioFile(
                forWriting: URL(fileURLWithPath: "/dev/fd/\(descriptor.rawValue)"),
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            descriptor.close()
            throw error
        }
        self.descriptor = descriptor
        self.onFinish = onFinish
        isActive = true
    }

    func stop() throws {
        finish()
    }

    func cancel() {
        finish()
    }

    func sendBuffer(frames: AVAudioFrameCount) {
        guard isActive,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return
        }
        buffer.frameLength = frames
        do {
            try file?.write(from: buffer)
            onBuffer?(
                AudioCaptureBuffer(
                    frameCount: Int(frames),
                    sampleRate: format.sampleRate,
                    channelCount: Int(format.channelCount),
                    pcmData: Data()
                )
            )
        } catch {
            return
        }
    }

    private func finish() {
        guard isActive else {
            return
        }
        isActive = false
        file = nil
        descriptor?.close()
        descriptor = nil
        onBuffer = nil
        onFinish?()
        onFinish = nil
    }
}
