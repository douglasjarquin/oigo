import AppKit
import ApplicationServices
import CoreGraphics
@_spi(Testing) import OigoCore

@MainActor
public final class InsertionService {
    private let targetEnvironment: InsertionTargetEnvironment
    private let pasteboard: InsertionPasteboard
    private let eventSender: InsertionEventSender
    private let faultInjector: DictationFaultInjector?
    private var attemptedSessionID: UUID?

    public init(
        targetEnvironment: InsertionTargetEnvironment = AccessibilityTargetEnvironment(),
        pasteboard: InsertionPasteboard = SystemInsertionPasteboard(),
        eventSender: InsertionEventSender = CommandVPasteEventSender()
    ) {
        self.targetEnvironment = targetEnvironment
        self.pasteboard = pasteboard
        self.eventSender = eventSender
        faultInjector = nil
    }

    @_spi(Testing)
    public init(
        targetEnvironment: InsertionTargetEnvironment = AccessibilityTargetEnvironment(),
        pasteboard: InsertionPasteboard = SystemInsertionPasteboard(),
        eventSender: InsertionEventSender = CommandVPasteEventSender(),
        faultInjector: DictationFaultInjector?
    ) {
        self.targetEnvironment = targetEnvironment
        self.pasteboard = pasteboard
        self.eventSender = eventSender
        self.faultInjector = faultInjector
    }

    public func captureTarget() -> InsertionTargetSnapshot {
        targetEnvironment.capture()
    }

    public func discardTarget(_ target: InsertionTargetSnapshot) {
        targetEnvironment.discard(target)
    }

    public func captureTargetBeforeMicrophonePermission(
        requestPermission: @escaping @MainActor () async throws -> Void
    ) async throws -> InsertionTargetSnapshot {
        let target = captureTarget()
        do {
            try await requestPermission()
        } catch {
            targetEnvironment.discard(target)
            throw error
        }
        return target
    }

    public func insertRawText(
        for session: DictationSession,
        store: SessionStore,
        target: InsertionTargetSnapshot
    ) -> InsertionResult {
        insertText(
            for: session,
            source: .raw,
            store: store,
            target: target
        )
    }

    public func insertText(
        for session: DictationSession,
        source: TranscriptInsertionSource,
        store: SessionStore,
        target: InsertionTargetSnapshot
    ) -> InsertionResult {
        defer { targetEnvironment.discard(target) }
        guard attemptedSessionID != session.id else {
            return InsertionResult(
                outcome: .failed,
                reasonCode: .insertionAlreadyAttempted
            )
        }

        let text: String
        do {
            text = try readText(source: source, for: session, store: store)
        } catch {
            return InsertionResult(
                outcome: .failed,
                reasonCode: .transcriptReadFailed
            )
        }
        guard !text.isEmpty else {
            return InsertionResult(
                outcome: .failed,
                reasonCode: .transcriptEmpty
            )
        }
        do {
            _ = try store.claimInsertion(for: session)
        } catch SessionStoreError.insertionAlreadyAttempted {
            return InsertionResult(
                outcome: .failed,
                reasonCode: .insertionAlreadyAttempted
            )
        } catch {
            return InsertionResult(
                outcome: .failed,
                reasonCode: .insertionClaimFailed
            )
        }
        attemptedSessionID = session.id
        guard pasteboard.write(text) else {
            return InsertionResult(
                outcome: .failed,
                reasonCode: .clipboardWriteFailed
            )
        }

        return performPaste(target: target)
    }

    public func pasteAgain(
        for session: DictationSession,
        store: SessionStore,
        target: InsertionTargetSnapshot
    ) -> InsertionResult {
        pasteAgain(
            for: session,
            source: .raw,
            store: store,
            target: target
        )
    }

    public func pasteAgain(
        for session: DictationSession,
        source: TranscriptInsertionSource,
        store: SessionStore,
        target: InsertionTargetSnapshot
    ) -> InsertionResult {
        defer { targetEnvironment.discard(target) }
        let text: String
        do {
            text = try readText(source: source, for: session, store: store)
        } catch {
            return InsertionResult(
                outcome: .failed,
                reasonCode: .transcriptReadFailed
            )
        }
        guard !text.isEmpty else {
            return InsertionResult(
                outcome: .failed,
                reasonCode: .transcriptEmpty
            )
        }
        guard pasteboard.write(text) else {
            return InsertionResult(
                outcome: .failed,
                reasonCode: .clipboardWriteFailed
            )
        }
        return performPaste(target: target)
    }

    public func copyText(
        for session: DictationSession,
        source: TranscriptInsertionSource,
        store: SessionStore,
        reasonCode: InsertionReasonCode
    ) -> InsertionResult {
        let text: String
        do {
            text = try readText(source: source, for: session, store: store)
        } catch {
            return InsertionResult(
                outcome: .failed,
                reasonCode: .transcriptReadFailed
            )
        }
        guard !text.isEmpty else {
            return InsertionResult(
                outcome: .failed,
                reasonCode: .transcriptEmpty
            )
        }
        guard pasteboard.write(text) else {
            return InsertionResult(
                outcome: .failed,
                reasonCode: .clipboardWriteFailed
            )
        }
        return InsertionResult(outcome: .copied, reasonCode: reasonCode)
    }

    private func readText(
        source: TranscriptInsertionSource,
        for session: DictationSession,
        store: SessionStore
    ) throws -> String {
        switch source {
        case .raw:
            try store.readRawText(for: session)
        case .normalized:
            try store.readNormalizedText(for: session)
        case .clean:
            try store.readCleanText(for: session)
        }
    }

    private func performPaste(
        target: InsertionTargetSnapshot
    ) -> InsertionResult {
        if faultInjector?.consume(.targetLoss) == true {
            return Self.copyOnlyResult(for: .applicationChanged)
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
            case .dispatched:
                return InsertionResult(outcome: .dispatched)
            case .verified:
                return InsertionResult(outcome: .pasted)
            case .targetUnsafe(let validation):
                return Self.copyOnlyResult(for: validation)
            case .failed:
                return InsertionResult(
                    outcome: .copied,
                    reasonCode: .eventDispatchFailed
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
        case .unsupportedTarget:
            return Self.copyOnlyResult(for: .unsupportedTarget)
        case .readOnlyTarget:
            return Self.copyOnlyResult(for: .readOnlyTarget)
        case .disabledTarget:
            return Self.copyOnlyResult(for: .disabledTarget)
        case .ambiguousTarget:
            return Self.copyOnlyResult(for: .ambiguousTarget)
        }
    }

    private static func copyOnlyResult(for validation: TargetValidation) -> InsertionResult {
        switch validation {
        case .secureTextField:
            return InsertionResult(
                outcome: .secureRejected,
                reasonCode: .secureField
            )
        case .accessibilityUnavailable:
            return InsertionResult(
                outcome: .copied,
                reasonCode: .accessibilityUnavailable
            )
        case .applicationChanged:
            return InsertionResult(
                outcome: .copied,
                reasonCode: .applicationChanged
            )
        case .focusedElementChanged:
            return InsertionResult(
                outcome: .copied,
                reasonCode: .focusedElementChanged
            )
        case .missingFocusedElement:
            return InsertionResult(
                outcome: .copied,
                reasonCode: .missingFocusedElement
            )
        case .unsupportedTarget:
            return InsertionResult(
                outcome: .copied,
                reasonCode: .unsupportedTarget
            )
        case .readOnlyTarget:
            return InsertionResult(
                outcome: .copied,
                reasonCode: .readOnlyTarget
            )
        case .disabledTarget:
            return InsertionResult(
                outcome: .copied,
                reasonCode: .disabledTarget
            )
        case .ambiguousTarget:
            return InsertionResult(
                outcome: .copied,
                reasonCode: .ambiguousTarget
            )
        case .safe:
            return InsertionResult(
                outcome: .failed,
                reasonCode: .targetChangedDuringDispatch
            )
        }
    }
}

@MainActor
public final class AccessibilityTargetEnvironment: InsertionTargetEnvironment {
    private struct CapturedTarget {
        let token: UUID
        let element: AXUIElement
    }

    private var capturedTarget: CapturedTarget?

    public init() {}

    public func capture() -> InsertionTargetSnapshot {
        let application = NSWorkspace.shared.frontmostApplication
        let processIdentifier = application?.processIdentifier ?? 0
        let bundleIdentifier = application?.bundleIdentifier
        guard processIdentifier > 0 else {
            capturedTarget = nil
            return InsertionTargetSnapshot(
                frontmostProcessIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier,
                focusedElementIdentifier: nil,
                role: nil,
                isSecureTextField: false,
                identity: nil,
                capabilities: nil,
                captureToken: nil
            )
        }

        guard let focused = focusedElement(for: processIdentifier) else {
            capturedTarget = nil
            return InsertionTargetSnapshot(
                frontmostProcessIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier,
                focusedElementIdentifier: nil,
                role: nil,
                isSecureTextField: false,
                identity: nil,
                capabilities: nil,
                captureToken: nil
            )
        }
        let role = stringAttribute(kAXRoleAttribute, from: focused)
        let subrole = stringAttribute(kAXSubroleAttribute, from: focused)
        let identity = targetIdentity(for: focused, role: role, subrole: subrole)
        let capabilities = targetCapabilities(for: focused)
        let token: UUID
        if let capturedTarget,
           CFEqual(capturedTarget.element, focused) {
            token = capturedTarget.token
        } else {
            token = UUID()
        }
        capturedTarget = CapturedTarget(token: token, element: focused)
        return InsertionTargetSnapshot(
            frontmostProcessIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            focusedElementIdentifier: identity.accessibilityIdentifier,
            role: role,
            isSecureTextField: Self.isSecure(role: role, subrole: subrole),
            identity: identity,
            capabilities: capabilities,
            captureToken: token
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
        let identity = targetIdentity(for: focused, role: role, subrole: subrole)
        let identityMatch: Bool?
        if let capturedTarget,
           capturedTarget.token == snapshot.captureToken {
            identityMatch = CFEqual(capturedTarget.element, focused)
        } else {
            identityMatch = nil
        }
        return TargetValidation.evaluate(
            snapshot: snapshot,
            currentProcessIdentifier: application.processIdentifier,
            currentBundleIdentifier: application.bundleIdentifier,
            currentFocusedElementIdentifier: identity.accessibilityIdentifier,
            currentRole: role,
            currentIsSecureTextField: Self.isSecure(role: role, subrole: subrole),
            accessibilityTrusted: true,
            currentIdentity: identity,
            identityMatch: identityMatch,
            currentCapabilities: targetCapabilities(for: focused)
        )
    }

    public func discard(_ snapshot: InsertionTargetSnapshot) {
        guard capturedTarget?.token == snapshot.captureToken else {
            return
        }
        capturedTarget = nil
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

    private func targetIdentity(
        for element: AXUIElement,
        role: String?,
        subrole: String?
    ) -> InsertionTargetIdentity {
        let window = copyElement(kAXWindowAttribute, from: element)
        let windowIdentifier = window.flatMap {
            stringAttribute(kAXIdentifierAttribute, from: $0)
        }
        var ancestry: [String] = []
        var parent = copyElement(kAXParentAttribute, from: element)
        for _ in 0..<8 {
            guard let current = parent else {
                break
            }
            let parentRole = stringAttribute(kAXRoleAttribute, from: current) ?? "unknown"
            let parentIdentifier = stringAttribute(kAXIdentifierAttribute, from: current)
            ancestry.append(parentRole + ":" + (parentIdentifier ?? ""))
            parent = copyElement(kAXParentAttribute, from: current)
        }
        return InsertionTargetIdentity(
            accessibilityIdentifier: stringAttribute(kAXIdentifierAttribute, from: element),
            windowIdentifier: windowIdentifier,
            role: role,
            subrole: subrole,
            ancestry: ancestry
        )
    }

    private func targetCapabilities(for element: AXUIElement) -> InsertionTargetCapabilities {
        let attributes = attributeNames(for: element)
        let supportsValue = attributes.contains(kAXValueAttribute)
        let supportsSelectedText = attributes.contains(kAXSelectedTextAttribute)
        return InsertionTargetCapabilities(
            supportsValue: supportsValue,
            valueIsSettable: supportsValue && isSettable(kAXValueAttribute, on: element),
            supportsSelectedText: supportsSelectedText,
            selectedTextIsSettable: supportsSelectedText
                && isSettable(kAXSelectedTextAttribute, on: element),
            isEnabled: boolAttribute(kAXEnabledAttribute, from: element)
        )
    }

    private func attributeNames(for element: AXUIElement) -> Set<String> {
        var value: CFArray?
        guard AXUIElementCopyAttributeNames(element, &value) == .success,
              let value else {
            return []
        }
        return Set((value as? [Any] ?? []).compactMap { $0 as? String })
    }

    private func isSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
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
        return .dispatched
    }
}
