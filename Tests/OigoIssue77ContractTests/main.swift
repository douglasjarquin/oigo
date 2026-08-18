import Foundation
import OigoCore
import OigoInsertion

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
@MainActor
private struct OigoIssue77ContractTests {
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("target-contract alternate editable role", testAlternateEditableRole),
            ("target-contract read-only conventional role", testReadOnlyConventionalRole),
            ("target-contract stable identity corroboration", testStableIdentityCorroboration),
            ("target-contract token preserves identifier-less identity", testTokenPreservesIdentifierLessIdentity),
            ("target-contract explicit wrapper change fails closed", testExplicitWrapperChangeFailsClosed),
            ("target-contract hash collision fails closed", testHashCollisionFailsClosed),
            ("target-contract secure field veto", testSecureFieldVeto),
            ("insertion-contract capture precedes microphone permission", testCapturePrecedesMicrophonePermission),
            ("insertion-contract dispatch is not verification", testDispatchIsNotVerification),
            ("insertion-contract dispatch failure retains clipboard", testDispatchFailureRetainsClipboard),
            ("insertion-contract verified acknowledgement", testVerifiedAcknowledgement),
            ("history-paste-again", testHistoryPasteAgain),
            ("history-paste-again timeout", testHistoryPasteAgainTimeout),
            ("history-paste-again cancellation", testHistoryPasteAgainCancellation)
        ]
        let filter = CommandLine.arguments.dropFirst()
            .drop(while: { $0 != "--filter" })
            .dropFirst()
            .first
        let selected = tests.filter { filter == nil || $0.0.contains(filter ?? "") }
        guard !selected.isEmpty else {
            print("FAIL: no issue #77 contract scenarios matched filter")
            exit(1)
        }

        var failures = 0
        for (name, test) in selected {
            do {
                try await test()
                print("GREEN: issue #77 " + name)
            } catch {
                failures += 1
                print("RED: issue #77 " + name + ": " + String(describing: error))
            }
        }
        if failures > 0 {
            print("FAILURES=" + String(failures))
            exit(1)
        }
        print("GREEN: all issue #77 contract scenarios")
    }

    private static func testAlternateEditableRole() throws {
        let snapshot = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "custom-field",
            role: "AXCustomEditor",
            isSecureTextField: false,
            capabilities: InsertionTargetCapabilities(
                supportsValue: true,
                valueIsSettable: true,
                supportsSelectedText: false,
                selectedTextIsSettable: false
            )
        )
        let result = TargetValidation.evaluate(
            snapshot: snapshot,
            currentProcessIdentifier: 42,
            currentBundleIdentifier: "com.example.editor",
            currentFocusedElementIdentifier: "custom-field",
            currentRole: "AXCustomEditor",
            currentIsSecureTextField: false,
            accessibilityTrusted: true,
            currentCapabilities: InsertionTargetCapabilities(
                supportsValue: true,
                valueIsSettable: true,
                supportsSelectedText: false,
                selectedTextIsSettable: false
            )
        )
        guard result == .safe else {
            throw ContractFailure(message: "capable editable target was rejected by role: " + String(describing: result))
        }
    }

    private static func testReadOnlyConventionalRole() throws {
        let snapshot = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "read-only-field",
            role: "AXTextField",
            isSecureTextField: false,
            capabilities: InsertionTargetCapabilities(
                supportsValue: true,
                valueIsSettable: false,
                supportsSelectedText: false,
                selectedTextIsSettable: false
            )
        )
        let result = TargetValidation.evaluate(
            snapshot: snapshot,
            currentProcessIdentifier: 42,
            currentBundleIdentifier: "com.example.editor",
            currentFocusedElementIdentifier: "read-only-field",
            currentRole: "AXTextField",
            currentIsSecureTextField: false,
            accessibilityTrusted: true,
            currentCapabilities: InsertionTargetCapabilities(
                supportsValue: true,
                valueIsSettable: false,
                supportsSelectedText: false,
                selectedTextIsSettable: false
            )
        )
        guard result != .safe else {
            throw ContractFailure(message: "read-only conventional role was accepted without a settable capability")
        }
    }

    private static func testHashCollisionFailsClosed() throws {
        let snapshot = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "ax-collision",
            role: "AXTextArea",
            isSecureTextField: false
        )
        let result = TargetValidation.evaluate(
            snapshot: snapshot,
            currentProcessIdentifier: 42,
            currentBundleIdentifier: "com.example.editor",
            currentFocusedElementIdentifier: "ax-collision",
            currentRole: "AXTextArea",
            currentIsSecureTextField: false,
            accessibilityTrusted: true
        )
        guard result != .safe else {
            throw ContractFailure(message: "hash-only identity authorized a target")
        }
    }

    private static func testStableIdentityCorroboration() throws {
        let capturedIdentity = InsertionTargetIdentity(
            accessibilityIdentifier: "field-a",
            windowIdentifier: "window-a",
            role: "AXCustomEditor",
            subrole: "AXTextArea",
            ancestry: ["AXWindow:window-a"]
        )
        let rewrappedIdentity = InsertionTargetIdentity(
            accessibilityIdentifier: "field-a",
            windowIdentifier: "window-a",
            role: "AXCustomEditor",
            subrole: "AXTextArea",
            ancestry: ["AXWindow:window-a"]
        )
        let capabilities = InsertionTargetCapabilities(
            supportsValue: true,
            valueIsSettable: true,
            supportsSelectedText: false,
            selectedTextIsSettable: false
        )
        let snapshot = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: nil,
            role: "AXCustomEditor",
            isSecureTextField: false,
            identity: capturedIdentity,
            capabilities: capabilities
        )
        let sameTarget = TargetValidation.evaluate(
            snapshot: snapshot,
            currentProcessIdentifier: 42,
            currentBundleIdentifier: "com.example.editor",
            currentFocusedElementIdentifier: nil,
            currentRole: "AXCustomEditor",
            currentIsSecureTextField: false,
            accessibilityTrusted: true,
            currentIdentity: rewrappedIdentity,
            identityMatch: nil,
            currentCapabilities: capabilities
        )
        guard sameTarget == .safe else {
            throw ContractFailure(message: "separate wrappers with corroborating identity were rejected")
        }

        let collidedIdentity = InsertionTargetIdentity(
            accessibilityIdentifier: "field-b",
            windowIdentifier: "window-b",
            role: "AXCustomEditor",
            subrole: "AXTextArea",
            ancestry: ["AXWindow:window-b"]
        )
        let collision = TargetValidation.evaluate(
            snapshot: snapshot,
            currentProcessIdentifier: 42,
            currentBundleIdentifier: "com.example.editor",
            currentFocusedElementIdentifier: "ax-collision",
            currentRole: "AXCustomEditor",
            currentIsSecureTextField: false,
            accessibilityTrusted: true,
            currentIdentity: collidedIdentity,
            identityMatch: false,
            currentCapabilities: capabilities
        )
        guard collision != .safe else {
            throw ContractFailure(message: "colliding wrappers were authorized by a hash-like identifier")
        }
    }

    private static func testSecureFieldVeto() throws {
        let snapshot = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "password",
            role: "AXTextField",
            isSecureTextField: true
        )
        let result = TargetValidation.evaluate(
            snapshot: snapshot,
            currentProcessIdentifier: 42,
            currentBundleIdentifier: "com.example.editor",
            currentFocusedElementIdentifier: "password",
            currentRole: "AXTextField",
            currentIsSecureTextField: false,
            accessibilityTrusted: true
        )
        guard result == .secureTextField else {
            throw ContractFailure(message: "secure target was not rejected first")
        }
    }

    private static func testExplicitWrapperChangeFailsClosed() throws {
        let snapshot = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: nil,
            role: "AXCustomEditor",
            isSecureTextField: false,
            identity: InsertionTargetIdentity(
                accessibilityIdentifier: "field-a",
                windowIdentifier: "window-a",
                role: "AXCustomEditor",
                ancestry: ["AXWindow:window-a"]
            ),
            capabilities: editableCapabilities()
        )
        let result = TargetValidation.evaluate(
            snapshot: snapshot,
            currentProcessIdentifier: 42,
            currentBundleIdentifier: "com.example.editor",
            currentFocusedElementIdentifier: nil,
            currentRole: "AXCustomEditor",
            currentIsSecureTextField: false,
            accessibilityTrusted: true,
            currentIdentity: InsertionTargetIdentity(
                windowIdentifier: "window-a",
                role: "AXCustomEditor",
                ancestry: ["AXWindow:window-a"]
            ),
            identityMatch: false,
            currentCapabilities: editableCapabilities()
        )
        guard result == .focusedElementChanged else {
            throw ContractFailure(message: "an explicitly different Accessibility element was authorized by shared window metadata")
        }
    }

    private static func testTokenPreservesIdentifierLessIdentity() throws {
        let token = UUID()
        let identity = InsertionTargetIdentity(
            role: "AXCustomEditor",
            subrole: "AXTextArea"
        )
        let first = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: nil,
            role: "AXCustomEditor",
            isSecureTextField: false,
            identity: identity,
            captureToken: token
        )
        let sameElement = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: nil,
            role: "AXCustomEditor",
            isSecureTextField: false,
            identity: identity,
            captureToken: token
        )
        let differentElement = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: nil,
            role: "AXCustomEditor",
            isSecureTextField: false,
            identity: identity,
            captureToken: UUID()
        )
        guard first.matches(sameElement),
              !first.matches(differentElement) else {
            throw ContractFailure(message: "identifier-less AX elements were matched without an equality-derived token")
        }

        let collidingIdentity = InsertionTargetIdentity(
            accessibilityIdentifier: "shared-field",
            windowIdentifier: "window-a",
            role: "AXCustomEditor",
            subrole: "AXTextArea"
        )
        let firstWithToken = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: nil,
            role: "AXCustomEditor",
            isSecureTextField: false,
            identity: collidingIdentity,
            captureToken: UUID()
        )
        let secondWithToken = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: nil,
            role: "AXCustomEditor",
            isSecureTextField: false,
            identity: collidingIdentity,
            captureToken: UUID()
        )
        guard !firstWithToken.matches(secondWithToken) else {
            throw ContractFailure(message: "distinct captured elements with colliding public metadata were authorized")
        }
    }

    private static func testCapturePrecedesMicrophonePermission() async throws {
        let trace = EventTrace()
        let environment = FakeTargetEnvironment(validation: .safe, trace: trace)
        let service = InsertionService(
            targetEnvironment: environment,
            pasteboard: FakePasteboard(),
            eventSender: FakeEventSender()
        )
        let target = try await service.captureTargetBeforeMicrophonePermission {
            trace.events.append("permission")
        }
        guard trace.events == ["capture", "permission"],
              target.frontmostProcessIdentifier == 42 else {
            throw ContractFailure(message: "microphone permission was requested before target capture")
        }
    }

    private static func testDispatchIsNotVerification() throws {
        let (store, session) = try persistedSession(rawText: "transcript")
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let target = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "field",
            role: "AXTextArea",
            isSecureTextField: false
        )
        let result = InsertionService(
            targetEnvironment: FakeTargetEnvironment(validation: .safe),
            pasteboard: FakePasteboard(),
            eventSender: FakeEventSender(result: .dispatched)
        ).insertRawText(for: session, store: store, target: target)
        guard result.outcome != .pasted else {
            throw ContractFailure(message: "event dispatch was falsely reported as verified paste")
        }
    }

    private static func testVerifiedAcknowledgement() throws {
        let (store, session) = try persistedSession(rawText: "verified transcript")
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let target = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "field",
            role: "AXTextArea",
            isSecureTextField: false
        )
        let result = InsertionService(
            targetEnvironment: FakeTargetEnvironment(validation: .safe),
            pasteboard: FakePasteboard(),
            eventSender: FakeEventSender(result: .verified)
        ).insertRawText(for: session, store: store, target: target)
        guard result.outcome == .pasted else {
            throw ContractFailure(message: "an explicit acknowledgement did not produce the verified outcome")
        }
    }

    private static func testDispatchFailureRetainsClipboard() throws {
        let (store, session) = try persistedSession(rawText: "dispatch failure transcript")
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let pasteboard = FakePasteboard()
        let result = InsertionService(
            targetEnvironment: FakeTargetEnvironment(validation: .safe),
            pasteboard: pasteboard,
            eventSender: FakeEventSender(result: .failed)
        ).insertRawText(
            for: session,
            store: store,
            target: InsertionTargetSnapshot(
                frontmostProcessIdentifier: 42,
                bundleIdentifier: "com.example.editor",
                focusedElementIdentifier: "field",
                role: "AXTextArea",
                isSecureTextField: false
            )
        )
        guard result.outcome == .copied,
              result.reasonCode == .eventDispatchFailed,
              pasteboard.writes == ["dispatch failure transcript"] else {
            throw ContractFailure(message: "dispatch failure discarded the clipboard fallback or reported the wrong outcome")
        }
    }

    private static func testHistoryPasteAgain() async throws {
        let trace = EventTrace()
        var captures = [
            historyTarget(identifier: "field-a"),
            historyTarget(identifier: "field-b"),
            historyTarget(identifier: "field-b")
        ]
        let handoff = InsertionTargetHandoff(
            maxAttempts: 4,
            waitForDestination: {
                trace.events.append("wait")
            }
        )
        let flow = InsertionPasteAgainFlow(handoff: handoff)
        let result = await flow.run(
            capture: {
                trace.events.append("capture")
                return captures.removeFirst()
            },
            paste: { _ in
                trace.events.append("dispatch")
                return InsertionResult(outcome: .dispatched)
            },
            copyOnly: { _ in
                trace.events.append("copy")
                return InsertionResult(outcome: .copied)
            },
            recordOutcome: { _ in
                trace.events.append("record")
                trace.events.append("restore")
            }
        )
        guard result.outcome == .dispatched,
              trace.events == [
                  "wait", "capture", "wait", "capture", "wait", "capture",
                  "dispatch", "record", "restore"
              ] else {
            throw ContractFailure(message: "History Paste Again did not wait for a stable target and restore focus after recording")
        }
    }

    private static func testHistoryPasteAgainTimeout() async throws {
        let trace = EventTrace()
        let handoff = InsertionTargetHandoff(
            maxAttempts: 2,
            waitForDestination: {
                trace.events.append("wait")
            }
        )
        let flow = InsertionPasteAgainFlow(handoff: handoff)
        let result = await flow.run(
            capture: {
                trace.events.append("capture")
                return InsertionTargetSnapshot(
                    frontmostProcessIdentifier: 0,
                    bundleIdentifier: nil,
                    focusedElementIdentifier: nil,
                    role: nil,
                    isSecureTextField: false
                )
            },
            paste: { _ in
                trace.events.append("dispatch")
                return InsertionResult(outcome: .dispatched)
            },
            copyOnly: { selection in
                guard selection == .timedOut else {
                    return InsertionResult(outcome: .failed)
                }
                trace.events.append("copy")
                return InsertionResult(
                    outcome: .copied,
                    reasonCode: .targetHandoffTimedOut
                )
            },
            recordOutcome: { _ in
                trace.events.append("record")
                trace.events.append("restore")
            }
        )
        guard result.outcome == .copied,
              result.reasonCode == .targetHandoffTimedOut,
              trace.events == ["wait", "capture", "wait", "capture", "copy", "record", "restore"] else {
            throw ContractFailure(message: "Paste Again timeout did not preserve clipboard-only safety")
        }
    }

    private static func testHistoryPasteAgainCancellation() async throws {
        let trace = EventTrace()
        let cancellation = CancellationController()
        let handoff = InsertionTargetHandoff(
            maxAttempts: 2,
            waitForDestination: {
                trace.events.append("wait")
                await Task.yield()
                cancellation.requestCancellation()
            }
        )
        let flow = InsertionPasteAgainFlow(handoff: handoff)
        let operation = Task { @MainActor in
            await flow.run(
                capture: {
                    trace.events.append("capture")
                    return historyTarget(identifier: "field")
                },
                paste: { _ in
                    trace.events.append("dispatch")
                    return InsertionResult(outcome: .dispatched)
                },
                copyOnly: { selection in
                    guard selection == .cancelled else {
                        return InsertionResult(outcome: .failed)
                    }
                    trace.events.append("copy")
                    return InsertionResult(
                        outcome: .copied,
                        reasonCode: .targetHandoffCancelled
                    )
                },
                recordOutcome: { _ in
                    trace.events.append("record")
                    trace.events.append("restore")
                }
            )
        }
        cancellation.cancel = { operation.cancel() }
        let result = await operation.value
        guard result.outcome == .copied,
              result.reasonCode == .targetHandoffCancelled,
              trace.events == ["wait", "copy", "record", "restore"] else {
            throw ContractFailure(message: "Paste Again cancellation dispatched or recorded the wrong outcome")
        }
    }

    private static func historyTarget(identifier: String) -> InsertionTargetSnapshot {
        InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: identifier,
            role: "AXTextArea",
            isSecureTextField: false
        )
    }

    private static func editableCapabilities() -> InsertionTargetCapabilities {
        InsertionTargetCapabilities(
            supportsValue: true,
            valueIsSettable: true,
            supportsSelectedText: false,
            selectedTextIsSettable: false
        )
    }

    private static func persistedSession(rawText: String) throws -> (SessionStore, DictationSession) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue77-" + UUID().uuidString, isDirectory: true)
        let store = try SessionStore(rootDirectory: root)
        var session = try store.createSession()
        session = try store.persistRawText(rawText, for: session)
        session = try store.update(session, state: .completed)
        return (store, session)
    }
}

@MainActor
private final class FakeTargetEnvironment: InsertionTargetEnvironment {
    let validation: TargetValidation
    let trace: EventTrace?

    init(validation: TargetValidation, trace: EventTrace? = nil) {
        self.validation = validation
        self.trace = trace
    }

    func capture() -> InsertionTargetSnapshot {
        trace?.events.append("capture")
        return InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "field",
            role: "AXTextArea",
            isSecureTextField: false
        )
    }

    func validate(_ snapshot: InsertionTargetSnapshot) -> TargetValidation {
        _ = snapshot
        return validation
    }
}

@MainActor
private final class EventTrace {
    var events: [String] = []
}

@MainActor
private final class CancellationController {
    var cancel: (() -> Void)?

    func requestCancellation() {
        cancel?()
    }
}

@MainActor
private final class FakePasteboard: InsertionPasteboard {
    private(set) var writes: [String] = []

    func write(_ rawText: String) -> Bool {
        writes.append(rawText)
        return true
    }
}

@MainActor
private final class FakeEventSender: InsertionEventSender {
    let result: InsertionEventResult

    init(result: InsertionEventResult = .dispatched) {
        self.result = result
    }

    func sendPaste(
        to processIdentifier: Int32,
        revalidate: () -> TargetValidation
    ) -> InsertionEventResult {
        _ = processIdentifier
        guard revalidate() == .safe else {
            return .failed
        }
        return result
    }
}
