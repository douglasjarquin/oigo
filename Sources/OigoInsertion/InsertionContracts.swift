import Foundation
import OigoCore

public struct InsertionTargetSnapshot: Equatable, Sendable {
    public let frontmostProcessIdentifier: Int32
    public let bundleIdentifier: String?
    public let focusedElementIdentifier: String?
    public let role: String?
    public let isSecureTextField: Bool

    public init(
        frontmostProcessIdentifier: Int32,
        bundleIdentifier: String?,
        focusedElementIdentifier: String?,
        role: String?,
        isSecureTextField: Bool
    ) {
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.focusedElementIdentifier = focusedElementIdentifier
        self.role = role
        self.isSecureTextField = isSecureTextField
    }
}

public enum TargetValidation: Equatable, Sendable {
    case safe
    case accessibilityUnavailable
    case applicationChanged
    case focusedElementChanged
    case secureTextField
    case missingFocusedElement
    case nonEditableRole

    public static func evaluate(
        snapshot: InsertionTargetSnapshot,
        currentProcessIdentifier: Int32,
        currentBundleIdentifier: String?,
        currentFocusedElementIdentifier: String?,
        currentRole: String?,
        currentIsSecureTextField: Bool,
        accessibilityTrusted: Bool
    ) -> TargetValidation {
        guard !snapshot.isSecureTextField else {
            return .secureTextField
        }
        guard accessibilityTrusted else {
            return .accessibilityUnavailable
        }
        guard currentProcessIdentifier == snapshot.frontmostProcessIdentifier,
              currentBundleIdentifier == snapshot.bundleIdentifier else {
            return .applicationChanged
        }
        guard let expectedIdentifier = snapshot.focusedElementIdentifier,
              let currentFocusedElementIdentifier else {
            return .missingFocusedElement
        }
        guard !currentIsSecureTextField else {
            return .secureTextField
        }
        guard currentFocusedElementIdentifier == expectedIdentifier,
              currentRole == snapshot.role else {
            return .focusedElementChanged
        }
        guard Self.editableRoles.contains(currentRole ?? "") else {
            return .nonEditableRole
        }
        return .safe
    }

    private static let editableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField"
    ]
}

public enum InsertionEventResult: Equatable, Sendable {
    case sent
    case targetUnsafe(TargetValidation)
    case failed
}

@MainActor
public protocol InsertionTargetEnvironment: AnyObject {
    func capture() -> InsertionTargetSnapshot
    func validate(_ snapshot: InsertionTargetSnapshot) -> TargetValidation
}

@MainActor
public protocol InsertionPasteboard: AnyObject {
    func write(_ rawText: String) -> Bool
}

@MainActor
public protocol InsertionEventSender: AnyObject {
    func sendPaste(
        to processIdentifier: Int32,
        revalidate: () -> TargetValidation
    ) -> InsertionEventResult
}

public struct InsertionResult: Equatable, Sendable {
    public let outcome: InsertionOutcome
    public let reason: String?

    public init(outcome: InsertionOutcome, reason: String? = nil) {
        self.outcome = outcome
        self.reason = reason
    }
}
