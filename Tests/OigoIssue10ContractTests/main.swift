import Darwin
import Foundation
@_spi(Testing) import OigoCore

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
@available(macOS 26.0, *)
@MainActor
private struct OigoIssue10ContractTests {
    static func main() async {
        let filter = CommandLine.arguments.dropFirst().drop(while: { $0 != "--filter" }).dropFirst().first
        let tests: [(String, () async throws -> Void)] = [
            ("capture failure persists durable code after metadata fault", testCaptureFailurePersistsDurableCodeAfterMetadataFault),
            ("device interruption records stable code", testDeviceInterruptionRecordsStableCode),
            ("stale callback cannot fail a new session", testStaleCallbackCannotFailNewSession),
            ("rapid cancellation cycles release capture", testRapidCancellationCyclesReleaseCapture)
        ]

        var failures = 0
        var matched = 0
        for (name, test) in tests where filter == nil || name.contains(filter ?? "") {
            matched += 1
            do {
                try await test()
                print("GREEN: " + name)
            } catch {
                failures += 1
                print("FAIL: " + name + ": " + String(describing: error))
            }
        }

        if matched == 0 {
            print("FAIL: no issue #10 contract scenarios matched filter")
            exit(1)
        }
        if failures == 0 {
            print("GREEN: all issue #10 contract scenarios")
            exit(0)
        }
        print("FAILURES=" + String(failures))
        exit(1)
    }

    private static func testCaptureFailurePersistsDurableCodeAfterMetadataFault() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = ScriptedAudioCapture()
        let coordinator = DictationCoordinator()
        let session = try coordinator.startRecording(using: capture, store: store)
        capture.writePartialCapture()
        store.failNextMetadataWriteForTesting()
        capture.emitFailure("audio file write failed: disk full")
        await Task.yield()

        let saved = try store.load(id: session.id)
        let metadata = try metadataObject(at: saved.metadataURL)
        guard coordinator.state == .failed,
              saved.metadata.state == .failed,
              saved.metadata.failureReason?.contains("disk full") == true,
              metadata["failureCode"] as? String == "audio_write_failed",
              saved.metadata.audioByteCount ?? 0 > 0,
              FileManager.default.fileExists(atPath: saved.audioURL.path),
              !capture.isActive else {
            throw ContractFailure(message: "capture failure did not durably preserve partial audio, stable failure code, and terminal cleanup")
        }
    }

    private static func testDeviceInterruptionRecordsStableCode() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = ScriptedAudioCapture()
        let coordinator = DictationCoordinator()
        let session = try coordinator.startRecording(using: capture, store: store)
        capture.writePartialCapture()
        capture.emitInterruption("default input device changed: AirPods connected")
        await Task.yield()

        let saved = try store.load(id: session.id)
        let metadata = try metadataObject(at: saved.metadataURL)
        guard coordinator.state == .interrupted,
              saved.metadata.state == .interrupted,
              saved.metadata.failureReason?.contains("AirPods") == true,
              metadata["failureCode"] as? String == "audio_input_device_changed",
              saved.metadata.audioByteCount ?? 0 > 0,
              !capture.isActive else {
            throw ContractFailure(message: "input-device interruption did not leave an actionable, durable terminal session")
        }
    }

    private static func testStaleCallbackCannotFailNewSession() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = ScriptedAudioCapture()
        let coordinator = DictationCoordinator()
        let first = try coordinator.startRecording(using: capture, store: store)
        _ = try coordinator.cancelRecording()
        let second = try coordinator.startRecording(using: capture, store: store)

        capture.emitFailure("stale device failure", callbackIndex: 0)
        await Task.yield()

        let savedFirst = try store.load(id: first.id)
        let savedSecond = try store.load(id: second.id)
        guard savedFirst.metadata.state == .cancelled,
              savedSecond.metadata.state == .recording,
              coordinator.state == .recording,
              capture.isActive else {
            throw ContractFailure(message: "a callback from a completed session changed the newer session")
        }
        _ = try coordinator.cancelRecording()
    }

    private static func testRapidCancellationCyclesReleaseCapture() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = ScriptedAudioCapture()
        let coordinator = DictationCoordinator()

        for index in 0..<100 {
            let session = try coordinator.startRecording(
                using: capture,
                store: store,
                now: Date(timeIntervalSince1970: 20_000 + Double(index))
            )
            let cancelled = try coordinator.cancelRecording(
                at: Date(timeIntervalSince1970: 20_000 + Double(index) + 0.5)
            )
            guard session.id == cancelled.id,
                  cancelled.metadata.state == .cancelled,
                  coordinator.activeTaskCount == 0,
                  !capture.isActive else {
                throw ContractFailure(message: "cancellation cycle (index) left capture or coordinator work active")
            }
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue10-contract-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
        print("CLEANUP: removed " + root.path)
    }

    private static func metadataObject(at url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ContractFailure(message: "session metadata was not a JSON object")
        }
        return object
    }
}

private final class ScriptedAudioCapture: AudioCapturing, @unchecked Sendable {
    private struct Callbacks {
        let onFinish: @Sendable () -> Void
        let onInterruption: @Sendable (String) -> Void
        let onFailure: @Sendable (String) -> Void
    }

    private var callbacks: [Callbacks] = []
    private var descriptor: AudioFileDescriptor?
    private(set) var isActive = false
    private var activeCallbackIndex: Int?

    func start(
        to descriptor: AudioFileDescriptor,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        _ = onBuffer
        self.descriptor = descriptor
        callbacks.append(
            Callbacks(
                onFinish: onFinish,
                onInterruption: onInterruption,
                onFailure: onFailure
            )
        )
        activeCallbackIndex = callbacks.count - 1
        isActive = true
    }

    func stop() throws {
        cancel()
    }

    func cancel() {
        guard isActive else {
            return
        }
        isActive = false
        if let activeCallbackIndex {
            callbacks[activeCallbackIndex].onFinish()
        }
        self.activeCallbackIndex = nil
        descriptor?.close()
        descriptor = nil
    }

    func writePartialCapture() {
        let data = Data(repeating: 0x41, count: 64)
        guard let descriptor else {
            return
        }
        _ = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor.rawValue, bytes.baseAddress, data.count)
        }
    }

    func emitFailure(_ reason: String, callbackIndex: Int? = nil) {
        let index = callbackIndex ?? activeCallbackIndex ?? callbacks.count - 1
        guard callbacks.indices.contains(index) else {
            return
        }
        callbacks[index].onFailure(reason)
    }

    func emitInterruption(_ reason: String) {
        guard let index = activeCallbackIndex, callbacks.indices.contains(index) else {
            return
        }
        callbacks[index].onInterruption(reason)
    }
}
