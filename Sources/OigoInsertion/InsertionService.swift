import AppKit
import ApplicationServices
import CoreGraphics
import OigoCore

@MainActor
public final class InsertionService {
    private let targetEnvironment: InsertionTargetEnvironment
    private let pasteboard: InsertionPasteboard
    private let eventSender: InsertionEventSender
    private var attemptedSessionID: UUID?

    public init(
        targetEnvironment: InsertionTargetEnvironment = AccessibilityTargetEnvironment(),
        pasteboard: InsertionPasteboard = SystemInsertionPasteboard(),
        eventSender: InsertionEventSender = CommandVPasteEventSender()
    ) {
        self.targetEnvironment = targetEnvironment
        self.pasteboard = pasteboard
        self.eventSender = eventSender
    }

    public func captureTarget() -> InsertionTargetSnapshot {
        targetEnvironment.capture()
    }

    public func insertRawText(
        for session: DictationSession,
        store: SessionStore,
        target: InsertionTargetSnapshot
    ) -> InsertionResult {
        guard let persistedSession = try? store.load(id: session.id) else {
            return InsertionResult(
                outcome: .failed,
                reason: "session insertion state could not be read"
            )
        }
        guard persistedSession.metadata.insertionOutcome == nil else {
            return InsertionResult(
                outcome: .failed,
                reason: "insertion was already attempted for this session"
            )
        }
        guard attemptedSessionID != session.id else {
            return InsertionResult(
                outcome: .failed,
                reason: "insertion was already attempted for this session"
            )
        }
        attemptedSessionID = session.id

        let rawText: String
        do {
            rawText = try store.readRawText(for: session)
        } catch {
            return InsertionResult(
                outcome: .failed,
                reason: "raw transcript could not be read: " + String(describing: error)
            )
        }
        guard !rawText.isEmpty else {
            return InsertionResult(
                outcome: .failed,
                reason: "raw transcript was empty"
            )
        }
        guard pasteboard.write(rawText) else {
            return InsertionResult(
                outcome: .failed,
                reason: "raw transcript could not be written to the clipboard"
            )
        }

        switch targetEnvironment.validate(target) {
        case .secureTextField:
            return Self.copyOnlyResult(for: .secureTextField)
        case .safe:
            switch eventSender.sendPaste(
                to: target.frontmostProcessIdentifier,
                revalidate: { [targetEnvironment] in
                    targetEnvironment.validate(target)
                }
            ) {
            case .sent:
                return InsertionResult(outcome: .pasted)
            case .targetUnsafe(let validation):
                return Self.copyOnlyResult(for: validation)
            case .failed:
                return InsertionResult(
                    outcome: .failed,
                    reason: "Command-V could not be synthesized"
                )
            }
        case .accessibilityUnavailable:
            return Self.copyOnlyResult(for: .accessibilityUnavailable)
        case .applicationChanged:
            return Self.copyOnlyResult(for: .applicationChanged)
        case .focusedElementChanged:
            return Self.copyOnlyResult(for: .focusedElementChanged)
        case .missingFocusedElement:
            return Self.copyOnlyResult(for: .missingFocusedElement)
        case .nonEditableRole:
            return Self.copyOnlyResult(for: .nonEditableRole)
        }
    }

    private static func copyOnlyResult(for validation: TargetValidation) -> InsertionResult {
        switch validation {
        case .secureTextField:
            return InsertionResult(
                outcome: .secureRejected,
                reason: "target is a secure text field"
            )
        case .accessibilityUnavailable:
            return InsertionResult(
                outcome: .copied,
                reason: "Accessibility permission is unavailable"
            )
        case .applicationChanged:
            return InsertionResult(
                outcome: .copied,
                reason: "the frontmost application changed"
            )
        case .focusedElementChanged:
            return InsertionResult(
                outcome: .copied,
                reason: "the focused element changed"
            )
        case .missingFocusedElement:
            return InsertionResult(
                outcome: .copied,
                reason: "the focused element is unavailable"
            )
        case .nonEditableRole:
            return InsertionResult(
                outcome: .copied,
                reason: "the focused element is not a conventional editable field"
            )
        case .safe:
            return InsertionResult(
                outcome: .failed,
                reason: "target safety changed while Command-V was being synthesized"
            )
        }
    }
}

@MainActor
public final class AccessibilityTargetEnvironment: InsertionTargetEnvironment {
    public init() {}

    public func capture() -> InsertionTargetSnapshot {
        let application = NSWorkspace.shared.frontmostApplication
        let processIdentifier = application?.processIdentifier ?? 0
        let bundleIdentifier = application?.bundleIdentifier
        guard processIdentifier > 0 else {
            return InsertionTargetSnapshot(
                frontmostProcessIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier,
                focusedElementIdentifier: nil,
                role: nil,
                isSecureTextField: false
            )
        }

        let focused = focusedElement(for: processIdentifier)
        let role = focused.flatMap { stringAttribute(kAXRoleAttribute, from: $0) }
        let subrole = focused.flatMap { stringAttribute(kAXSubroleAttribute, from: $0) }
        return InsertionTargetSnapshot(
            frontmostProcessIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            focusedElementIdentifier: focused.map(elementIdentifier),
            role: role,
            isSecureTextField: Self.isSecure(role: role, subrole: subrole)
        )
    }

    public func validate(_ snapshot: InsertionTargetSnapshot) -> TargetValidation {
        guard !snapshot.isSecureTextField else {
            return .secureTextField
        }
        guard AXIsProcessTrusted() else {
            return .accessibilityUnavailable
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier == snapshot.frontmostProcessIdentifier,
              application.bundleIdentifier == snapshot.bundleIdentifier else {
            return .applicationChanged
        }
        guard let focused = focusedElement(for: application.processIdentifier) else {
            return .missingFocusedElement
        }

        let role = stringAttribute(kAXRoleAttribute, from: focused)
        let subrole = stringAttribute(kAXSubroleAttribute, from: focused)
        return TargetValidation.evaluate(
            snapshot: snapshot,
            currentProcessIdentifier: application.processIdentifier,
            currentBundleIdentifier: application.bundleIdentifier,
            currentFocusedElementIdentifier: elementIdentifier(focused),
            currentRole: role,
            currentIsSecureTextField: Self.isSecure(role: role, subrole: subrole),
            accessibilityTrusted: true
        )
    }

    private func focusedElement(for processIdentifier: Int32) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        return copyElement(kAXFocusedUIElementAttribute, from: application)
    }

    private func copyElement(
        _ attribute: String,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func stringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func elementIdentifier(_ element: AXUIElement) -> String {
        "ax-" + String(CFHash(element), radix: 16)
    }

    private static func isSecure(role: String?, subrole: String?) -> Bool {
        role == String(kAXSecureTextFieldSubrole) || subrole == String(kAXSecureTextFieldSubrole)
    }

}

@MainActor
public final class SystemInsertionPasteboard: InsertionPasteboard {
    public init() {}

    public func write(_ rawText: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(rawText, forType: .string)
    }
}

@MainActor
public final class CommandVPasteEventSender: InsertionEventSender {
    public init() {}

    public func sendPaste(
        to processIdentifier: Int32,
        revalidate: () -> TargetValidation
    ) -> InsertionEventResult {
        guard processIdentifier > 0 else {
            return .failed
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9,
            keyDown: false
        ) else {
            return .failed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        let validation = revalidate()
        guard validation == .safe else {
            return .targetUnsafe(validation)
        }
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
        return .sent
    }
}
