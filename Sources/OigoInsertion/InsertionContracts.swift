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
    func sendPaste() -> Bool
}

public struct InsertionResult: Equatable, Sendable {
    public let outcome: InsertionOutcome
    public let reason: String?

    public init(outcome: InsertionOutcome, reason: String? = nil) {
        self.outcome = outcome
        self.reason = reason
    }
}
