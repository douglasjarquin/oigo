import AppKit
import OigoCore
import OigoHotKey

final class ShortcutRecorderScenario: NativeUIContractScenario {
    override class var scenarioName: String {
        "shortcut-recorder"
    }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task07" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }

        try MainActor.assumeIsolated {
            try assertNestedEvidenceRootIsCreated(arguments: arguments)
            let selected = arguments.fixtureRoot.lastPathComponent
            guard ["task-07", "success", "failure"].contains(selected) else {
                throw ContractInputError(category: "unsupported-shortcut-fixture")
            }
            if selected != "failure" {
                try runSuccess()
            }
            if selected != "success" {
                try runFailureAndReuse()
            }
            print(
                "PASS shortcut-recorder focus=first-responder keyCode=0 capture-count=1 "
                    + "repeat=ignored modifiers=0xf00 cancel=preserved clear=default-committed "
                    + "focus-loss=preserved reuse=committed"
            )
        }
    }

    private static func assertNestedEvidenceRootIsCreated(arguments: ContractArguments) throws {
        let nestedEvidenceRoot = arguments.evidenceRoot
            .appendingPathComponent("shortcut-recorder-nested-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: nestedEvidenceRoot) }
        guard !FileManager.default.fileExists(atPath: nestedEvidenceRoot.path) else {
            throw ContractInputError(category: "stale-nested-evidence-root")
        }
        let nested = try ContractArguments.parse([
            "--scenario", scenarioName,
            "--defaults-suite", arguments.defaultsSuite,
            "--fixture-root", arguments.fixtureRoot.path,
            "--evidence-root", nestedEvidenceRoot.path
        ])
        var isDirectory = ObjCBool(false)
        let normalizedNestedEvidenceRoot = nestedEvidenceRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard nested.evidenceRoot.path == normalizedNestedEvidenceRoot.path,
              FileManager.default.fileExists(atPath: nestedEvidenceRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ContractInputError(category: "nested-evidence-root-not-created")
        }
    }

    @MainActor
    private static func runSuccess() throws {
        let harness = makeHarness()
        let expected = ToggleShortcut(
            keyCode: 0,
            modifiers: ToggleShortcutModifiers.command
                | ToggleShortcutModifiers.control
                | ToggleShortcutModifiers.option
                | ToggleShortcutModifiers.shift
        )

        harness.recorder.beginRecording()
        guard harness.window.firstResponder === harness.recorder,
              harness.recorder.isRecording,
              harness.recorder.accessibilityValue() as? String == "Press a shortcut" else {
            throw ContractInputError(category: "recorder-focus-not-claimed")
        }

        harness.recorder.keyDown(with: try keyEvent(
            keyCode: 0,
            modifiers: [.command, .control, .option, .shift],
            isARepeat: true
        ))
        guard harness.recorder.isRecording,
              harness.recorder.shortcut == ToggleShortcut.default,
              harness.target.invocationCount == 0 else {
            throw ContractInputError(category: "repeated-keydown-was-captured")
        }

        harness.recorder.keyDown(with: try keyEvent(
            keyCode: 0,
            modifiers: [.command, .control, .option, .shift],
            isARepeat: false
        ))
        guard !harness.recorder.isRecording,
              harness.recorder.shortcut == expected,
              harness.target.invocationCount == 1,
              harness.target.lastSender === harness.recorder,
              harness.recorder.accessibilityValue() as? String == "⌃⌥⇧⌘A" else {
            throw ContractInputError(category: "key-code-zero-capture-failed")
        }
    }

    @MainActor
    private static func runFailureAndReuse() throws {
        let harness = makeHarness()
        let committed = ToggleShortcut(keyCode: 13, modifiers: ToggleShortcutModifiers.command)
        harness.recorder.restoreCandidate(committed)

        harness.recorder.beginRecording()
        harness.recorder.keyDown(with: try keyEvent(keyCode: 12, modifiers: [], isARepeat: false))
        guard harness.recorder.isRecording,
              harness.recorder.shortcut == committed,
              harness.target.invocationCount == 0,
              harness.recorder.validationError?.contains("modifier") == true else {
            throw ContractInputError(category: "modifier-free-key-was-accepted")
        }

        harness.recorder.keyDown(with: try keyEvent(keyCode: 12, modifiers: [.capsLock], isARepeat: false))
        guard harness.recorder.isRecording,
              harness.recorder.shortcut == committed,
              harness.target.invocationCount == 0,
              harness.recorder.validationError?.contains("supported") == true else {
            throw ContractInputError(category: "unsupported-modifier-was-accepted")
        }

        harness.recorder.cancelOperation(nil)
        guard !harness.recorder.isRecording,
              harness.recorder.shortcut == committed,
              harness.target.invocationCount == 0 else {
            throw ContractInputError(category: "cancel-operation-mutated-committed-shortcut")
        }

        harness.recorder.beginRecording()
        harness.recorder.keyDown(with: try keyEvent(keyCode: 53, modifiers: [], isARepeat: false))
        guard !harness.recorder.isRecording,
              harness.recorder.shortcut == committed,
              harness.target.invocationCount == 0 else {
            throw ContractInputError(category: "escape-mutated-committed-shortcut")
        }

        harness.recorder.beginRecording()
        guard harness.recorder.resignFirstResponder() else {
            throw ContractInputError(category: "focus-loss-not-delivered")
        }
        guard !harness.recorder.isRecording,
              harness.recorder.shortcut == committed,
              harness.target.invocationCount == 0 else {
            throw ContractInputError(category: "focus-loss-left-stale-recorder")
        }

        let reuse = ToggleShortcut(keyCode: 12, modifiers: ToggleShortcutModifiers.command)
        harness.recorder.beginRecording()
        harness.recorder.keyDown(with: try keyEvent(keyCode: 12, modifiers: [.command], isARepeat: false))
        guard !harness.recorder.isRecording,
              harness.recorder.shortcut == reuse,
              harness.target.invocationCount == 1,
              harness.target.lastSender === harness.recorder else {
            throw ContractInputError(category: "post-cancel-reuse-failed")
        }

        try runClearTransaction()
    }

    @MainActor
    private static func runClearTransaction() throws {
        let harness = makeHarness()
        let custom = ToggleShortcut(keyCode: 13, modifiers: ToggleShortcutModifiers.command)
        let registrar = ScenarioRegistrar(active: custom)
        let transaction = ShortcutConfigurationTransaction(
            committedShortcut: custom,
            registrar: registrar,
            onEvent: { _ in }
        )
        var persisted = custom
        harness.recorder.restoreCandidate(custom)
        harness.recorder.onCandidateChange = { transaction.setCandidate($0) }

        harness.recorder.beginRecording()
        harness.recorder.clearShortcut()
        guard !harness.recorder.isRecording,
              harness.recorder.shortcut == .default,
              transaction.candidateShortcut == .default,
              harness.target.invocationCount == 1,
              harness.target.lastSender === harness.recorder else {
            throw ContractInputError(category: "clear-did-not-remove-custom-candidate")
        }

        guard transaction.clear(
            persist: { persisted = $0 },
            restore: { persisted = custom }
        ).isAvailable,
              transaction.committedShortcut == .default,
              transaction.candidateShortcut == .default,
              persisted == .default,
              registrar.status == .active(.default, generation: 2) else {
            throw ContractInputError(category: "clear-did-not-commit-canonical-default")
        }
    }

    @MainActor
    private static func makeHarness() -> Harness {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 44),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let recorder = ShortcutRecorderControl(shortcut: .default)
        recorder.frame = NSRect(x: 0, y: 0, width: 280, height: 44)
        let target = RecorderActionTarget()
        recorder.target = target
        recorder.action = #selector(RecorderActionTarget.capture(_:))
        window.contentView?.addSubview(recorder)
        return Harness(
            window: window,
            recorder: recorder,
            target: target
        )
    }

    @MainActor
    private static func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isARepeat: Bool
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: isARepeat,
            keyCode: keyCode
        ) else {
            throw ContractInputError(category: "key-event-construction-failed")
        }
        return event
    }

    @MainActor
    private struct Harness {
        let window: NSWindow
        let recorder: ShortcutRecorderControl
        let target: RecorderActionTarget
    }
}

@MainActor
private final class RecorderActionTarget: NSObject {
    private(set) var invocationCount = 0
    private(set) weak var lastSender: AnyObject?

    @objc func capture(_ sender: Any?) {
        invocationCount += 1
        lastSender = sender as AnyObject?
    }
}
