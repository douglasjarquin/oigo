import Foundation
import OigoCore

public struct InsertionTargetIdentity: Equatable, Sendable {
    public let accessibilityIdentifier: String?
    public let windowIdentifier: String?
    public let role: String?
    public let subrole: String?
    public let ancestry: [String]

    public init(
        accessibilityIdentifier: String? = nil,
        windowIdentifier: String? = nil,
        role: String? = nil,
        subrole: String? = nil,
        ancestry: [String] = []
    ) {
        self.accessibilityIdentifier = accessibilityIdentifier?.isEmpty == false
            ? accessibilityIdentifier
            : nil
        self.windowIdentifier = windowIdentifier?.isEmpty == false
            ? windowIdentifier
            : nil
        self.role = role?.isEmpty == false ? role : nil
        self.subrole = subrole?.isEmpty == false ? subrole : nil
        self.ancestry = ancestry
    }

    public var hasCorroboratingEvidence: Bool {
        accessibilityIdentifier != nil
            || windowIdentifier != nil
            || ancestry.contains {
                let components = $0.split(
                    separator: ":",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                return components.count == 2
                    && !components[0].isEmpty
                    && !components[1].isEmpty
            }
    }

    public func corroborates(with other: InsertionTargetIdentity) -> Bool {
        guard let accessibilityIdentifier,
              let otherIdentifier = other.accessibilityIdentifier,
              accessibilityIdentifier == otherIdentifier else {
            return false
        }
        if let windowIdentifier, let otherWindowIdentifier = other.windowIdentifier {
            guard windowIdentifier == otherWindowIdentifier else {
                return false
            }
        }
        if let role, let otherRole = other.role {
            guard role == otherRole else {
                return false
            }
        }
        if let subrole, let otherSubrole = other.subrole {
            guard subrole == otherSubrole else {
                return false
            }
        }
        if !ancestry.isEmpty, !other.ancestry.isEmpty {
            guard ancestry == other.ancestry else {
                return false
            }
        }
        return true
    }
}

public struct InsertionTargetCapabilities: Equatable, Sendable {
    public let supportsValue: Bool
    public let valueIsSettable: Bool
    public let supportsSelectedText: Bool
    public let selectedTextIsSettable: Bool
    public let isEnabled: Bool?

    public init(
        supportsValue: Bool,
        valueIsSettable: Bool,
        supportsSelectedText: Bool,
        selectedTextIsSettable: Bool,
        isEnabled: Bool? = true
    ) {
        self.supportsValue = supportsValue
        self.valueIsSettable = valueIsSettable
        self.supportsSelectedText = supportsSelectedText
        self.selectedTextIsSettable = selectedTextIsSettable
        self.isEnabled = isEnabled
    }

    public var isEditable: Bool {
        isEnabled != false
            && ((supportsValue && valueIsSettable)
                || (supportsSelectedText && selectedTextIsSettable))
    }
}

public struct InsertionTargetSnapshot: Equatable, Sendable {
    public let frontmostProcessIdentifier: Int32
    public let bundleIdentifier: String?
    public let focusedElementIdentifier: String?
    public let role: String?
    public let isSecureTextField: Bool
    public let identity: InsertionTargetIdentity?
    public let capabilities: InsertionTargetCapabilities?
    public let captureToken: UUID?

    public init(
        frontmostProcessIdentifier: Int32,
        bundleIdentifier: String?,
        focusedElementIdentifier: String?,
        role: String?,
        isSecureTextField: Bool,
        identity: InsertionTargetIdentity? = nil,
        capabilities: InsertionTargetCapabilities? = nil,
        captureToken: UUID? = nil
    ) {
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.focusedElementIdentifier = focusedElementIdentifier
        self.role = role
        self.isSecureTextField = isSecureTextField
        self.identity = identity
        self.capabilities = capabilities
        self.captureToken = captureToken
    }

    public var canBeSelectedForPaste: Bool {
        frontmostProcessIdentifier > 0
            && (captureToken != nil
                || identity?.hasCorroboratingEvidence == true
                || (focusedElementIdentifier != nil
                    && focusedElementIdentifier?.isEmpty == false
                    && focusedElementIdentifier?.hasPrefix("ax-") == false))
    }

    public func matches(_ other: InsertionTargetSnapshot) -> Bool {
        guard frontmostProcessIdentifier == other.frontmostProcessIdentifier,
              bundleIdentifier == other.bundleIdentifier,
              isSecureTextField == other.isSecureTextField else {
            return false
        }
        if let captureToken, let otherCaptureToken = other.captureToken {
            return captureToken == otherCaptureToken
        }
        if captureToken != nil || other.captureToken != nil {
            return false
        }
        if let identity, let otherIdentity = other.identity {
            return identity.corroborates(with: otherIdentity)
        }
        if identity != nil || other.identity != nil {
            return false
        }
        if let role, let otherRole = other.role, role != otherRole {
            return false
        }
        guard let focusedElementIdentifier,
              let otherFocusedElementIdentifier = other.focusedElementIdentifier,
              !focusedElementIdentifier.isEmpty,
              !otherFocusedElementIdentifier.isEmpty,
              !focusedElementIdentifier.hasPrefix("ax-"),
              !otherFocusedElementIdentifier.hasPrefix("ax-") else {
            return false
        }
        return focusedElementIdentifier == otherFocusedElementIdentifier
    }
}

public enum TargetValidation: Equatable, Sendable {
    case safe
    case accessibilityUnavailable
    case applicationChanged
    case focusedElementChanged
    case secureTextField
    case missingFocusedElement
    case unsupportedTarget
    case readOnlyTarget
    case disabledTarget
    case ambiguousTarget

    public static func evaluate(
        snapshot: InsertionTargetSnapshot,
        currentProcessIdentifier: Int32,
        currentBundleIdentifier: String?,
        currentFocusedElementIdentifier: String?,
        currentRole: String?,
        currentIsSecureTextField: Bool,
        accessibilityTrusted: Bool,
        currentIdentity: InsertionTargetIdentity? = nil,
        identityMatch: Bool? = nil,
        currentCapabilities: InsertionTargetCapabilities? = nil
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
        guard snapshot.focusedElementIdentifier != nil
                || snapshot.identity != nil
                || currentIdentity != nil else {
            return .missingFocusedElement
        }
        guard !currentIsSecureTextField else {
            return .secureTextField
        }

        if let expectedIdentity = snapshot.identity {
            guard let currentIdentity else {
                return .ambiguousTarget
            }
            if identityMatch == false {
                return .focusedElementChanged
            }
            guard identityMatch == true
                    || expectedIdentity.corroborates(with: currentIdentity) else {
                return .ambiguousTarget
            }
        } else {
            guard let expectedIdentifier = snapshot.focusedElementIdentifier else {
                return .missingFocusedElement
            }
            guard let currentFocusedElementIdentifier else {
                return .missingFocusedElement
            }
            guard !expectedIdentifier.isEmpty,
                  !currentFocusedElementIdentifier.isEmpty,
                  !expectedIdentifier.hasPrefix("ax-"),
                  currentFocusedElementIdentifier == expectedIdentifier else {
                return expectedIdentifier.hasPrefix("ax-")
                    ? .ambiguousTarget
                    : .focusedElementChanged
            }
        }

        if let snapshotRole = snapshot.role,
           let currentRole,
           snapshotRole != currentRole {
            return .focusedElementChanged
        }

        guard let capabilities = currentCapabilities ?? snapshot.capabilities else {
            return .unsupportedTarget
        }
        guard capabilities.isEnabled != false else {
            return .disabledTarget
        }
        guard capabilities.supportsValue || capabilities.supportsSelectedText else {
            return .unsupportedTarget
        }
        guard capabilities.isEditable else {
            return .readOnlyTarget
        }
        return .safe
    }
}

public enum InsertionEventResult: Equatable, Sendable {
    case dispatched
    case verified
    case targetUnsafe(TargetValidation)
    case failed
}

@MainActor
public protocol InsertionTargetEnvironment: AnyObject {
    func capture() -> InsertionTargetSnapshot
    func validate(_ snapshot: InsertionTargetSnapshot) -> TargetValidation
    func discard(_ snapshot: InsertionTargetSnapshot)
}

public extension InsertionTargetEnvironment {
    func discard(_ snapshot: InsertionTargetSnapshot) {
        _ = snapshot
    }
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

public enum InsertionReasonCode: String, Codable, CaseIterable, Equatable, Sendable {
    case insertionAlreadyAttempted = "insertion_already_attempted"
    case insertionClaimFailed = "insertion_claim_failed"
    case transcriptReadFailed = "transcript_read_failed"
    case transcriptEmpty = "transcript_empty"
    case clipboardWriteFailed = "clipboard_write_failed"
    case accessibilityUnavailable = "accessibility_unavailable"
    case applicationChanged = "application_changed"
    case focusedElementChanged = "focused_element_changed"
    case missingFocusedElement = "missing_focused_element"
    case secureField = "secure_field"
    case unsupportedTarget = "unsupported_target"
    case readOnlyTarget = "read_only_target"
    case disabledTarget = "disabled_target"
    case ambiguousTarget = "ambiguous_target"
    case eventDispatchFailed = "event_dispatch_failed"
    case targetChangedDuringDispatch = "target_changed_during_dispatch"
    case targetHandoffTimedOut = "target_handoff_timed_out"
    case targetHandoffCancelled = "target_handoff_cancelled"
}

public struct InsertionResult: Equatable, Sendable {
    public let outcome: InsertionOutcome
    public let reason: String?
    public let reasonCode: InsertionReasonCode?

    public init(
        outcome: InsertionOutcome,
        reason: String? = nil,
        reasonCode: InsertionReasonCode? = nil
    ) {
        self.outcome = outcome
        self.reasonCode = reasonCode
        self.reason = reason ?? reasonCode?.rawValue
    }
}
