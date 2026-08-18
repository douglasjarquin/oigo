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
        let tests: [(String, () throws -> Void)] = [
            ("target alternate editable role", testAlternateEditableRole),
            ("target read-only conventional role", testReadOnlyConventionalRole),
            ("target stable identity corroboration", testStableIdentityCorroboration),
            ("target hash collision fails closed", testHashCollisionFailsClosed),
            ("target secure field veto", testSecureFieldVeto),
            ("insertion dispatch is not verification", testDispatchIsNotVerification)
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
                try test()
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
            identityMatch: false,
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

    private static func testDispatchIsNotVerification() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue77-red-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootDirectory: root)
        var session = try store.createSession()
        session = try store.persistRawText("transcript", for: session)
        session = try store.update(session, state: .completed)
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
            eventSender: FakeEventSender()
        ).insertRawText(for: session, store: store, target: target)
        guard result.outcome != .pasted else {
            throw ContractFailure(message: "event dispatch was falsely reported as verified paste")
        }
    }
}

@MainActor
private final class FakeTargetEnvironment: InsertionTargetEnvironment {
    let validation: TargetValidation

    init(validation: TargetValidation) {
        self.validation = validation
    }

    func capture() -> InsertionTargetSnapshot {
        InsertionTargetSnapshot(
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
private final class FakePasteboard: InsertionPasteboard {
    func write(_ rawText: String) -> Bool {
        _ = rawText
        return true
    }
}

@MainActor
private final class FakeEventSender: InsertionEventSender {
    func sendPaste(
        to processIdentifier: Int32,
        revalidate: () -> TargetValidation
    ) -> InsertionEventResult {
        _ = processIdentifier
        _ = revalidate()
        return .dispatched
    }
}
