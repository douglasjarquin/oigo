import Foundation
import os

public enum DictationState: String, CaseIterable, Codable, Sendable {
    case idle
    case preparing
    case recording
    case finalizing
    case cleaning
    case inserting
    case complete
    case failed
    case cancelled
    case interrupted
}

public enum DictationEvent: String, CaseIterable, Codable, Sendable {
    case start
    case prepared
    case stop
    case finalized
    case cleaned
    case inserted
    case reset
    case cancel
    case fail
    case interrupt
}

public enum DictationTransitionError: Error, Equatable, CustomStringConvertible, Sendable {
    case illegal(from: DictationState, event: DictationEvent)

    public var description: String {
        switch self {
        case .illegal(let from, let event):
            return "illegal dictation transition: " + from.rawValue + " + " + event.rawValue
        }
    }
}

public struct DictationStateMachine: Sendable {
    public struct Transition: Equatable, Sendable {
        public let from: DictationState
        public let event: DictationEvent
        public let to: DictationState

        public init(from: DictationState, event: DictationEvent, to: DictationState) {
            self.from = from
            self.event = event
            self.to = to
        }
    }

    public struct TransitionKey: Hashable, Sendable {
        public let from: DictationState
        public let event: DictationEvent

        public init(from: DictationState, event: DictationEvent) {
            self.from = from
            self.event = event
        }
    }

    public private(set) var state: DictationState

    public init(initialState: DictationState = .idle) {
        state = initialState
    }

    public static let legalTransitions: [Transition] = [
        Transition(from: .idle, event: .start, to: .preparing),
        Transition(from: .preparing, event: .prepared, to: .recording),
        Transition(from: .recording, event: .stop, to: .finalizing),
        Transition(from: .finalizing, event: .finalized, to: .cleaning),
        Transition(from: .cleaning, event: .cleaned, to: .inserting),
        Transition(from: .inserting, event: .inserted, to: .complete),
        Transition(from: .complete, event: .reset, to: .idle),
        Transition(from: .failed, event: .reset, to: .idle),
        Transition(from: .cancelled, event: .reset, to: .idle),
        Transition(from: .interrupted, event: .reset, to: .idle),
        Transition(from: .complete, event: .start, to: .preparing),
        Transition(from: .failed, event: .start, to: .preparing),
        Transition(from: .cancelled, event: .start, to: .preparing),
        Transition(from: .interrupted, event: .start, to: .preparing),
        Transition(from: .preparing, event: .cancel, to: .cancelled),
        Transition(from: .recording, event: .cancel, to: .cancelled),
        Transition(from: .finalizing, event: .cancel, to: .cancelled),
        Transition(from: .cleaning, event: .cancel, to: .cancelled),
        Transition(from: .inserting, event: .cancel, to: .cancelled),
        Transition(from: .preparing, event: .fail, to: .failed),
        Transition(from: .recording, event: .fail, to: .failed),
        Transition(from: .finalizing, event: .fail, to: .failed),
        Transition(from: .cleaning, event: .fail, to: .failed),
        Transition(from: .inserting, event: .fail, to: .failed),
        Transition(from: .preparing, event: .interrupt, to: .interrupted),
        Transition(from: .recording, event: .interrupt, to: .interrupted),
        Transition(from: .finalizing, event: .interrupt, to: .interrupted),
        Transition(from: .cleaning, event: .interrupt, to: .interrupted),
        Transition(from: .inserting, event: .interrupt, to: .interrupted)
    ]

    @discardableResult
    public mutating func apply(_ event: DictationEvent) throws -> DictationState {
        guard let transition = Self.legalTransitions.first(where: {
            $0.from == state && $0.event == event
        }) else {
            throw DictationTransitionError.illegal(from: state, event: event)
        }
        state = transition.to
        return state
    }
}

public struct DictationTransitionRecord: Equatable, Sendable {
    public let from: DictationState
    public let event: DictationEvent
    public let to: DictationState

    public init(from: DictationState, event: DictationEvent, to: DictationState) {
        self.from = from
        self.event = event
        self.to = to
    }
}

public final class DictationDiagnostics: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.oigo.app", category: "dictation")
    private let signpostLog = OSLog(subsystem: "com.oigo.app", category: "dictation")

    public init() {}

    public func record(_ transition: DictationTransitionRecord) {
        logger.info(
            "state transition \(transition.from.rawValue, privacy: .public) + \(transition.event.rawValue, privacy: .public) -> \(transition.to.rawValue, privacy: .public)"
        )
        os_signpost(.event, log: signpostLog, name: "state-transition")
    }

    public func record(_ message: String) {
        logger.info("\(message, privacy: .public)")
        os_signpost(.event, log: signpostLog, name: "coordinator-event")
    }
}

public enum DictationCoordinatorError: Error, Equatable, CustomStringConvertible, Sendable {
    case workAlreadyActive

    public var description: String {
        switch self {
        case .workAlreadyActive:
            return "dictation work is already active"
        }
    }
}

@MainActor
public final class DictationCoordinator {
    private var machine: DictationStateMachine
    private var activeTask: Task<Void, Never>?
    private let diagnostics: DictationDiagnostics

    public private(set) var transitionHistory: [DictationTransitionRecord] = []

    public var state: DictationState {
        machine.state
    }

    public var activeTaskCount: Int {
        activeTask == nil ? 0 : 1
    }

    public init(
        initialState: DictationState = .idle,
        diagnostics: DictationDiagnostics = DictationDiagnostics()
    ) {
        machine = DictationStateMachine(initialState: initialState)
        self.diagnostics = diagnostics
    }

    @discardableResult
    public func apply(_ event: DictationEvent) throws -> DictationState {
        let from = machine.state
        let next = try machine.apply(event)
        let transition = DictationTransitionRecord(from: from, event: event, to: next)
        transitionHistory.append(transition)
        diagnostics.record(transition)
        return next
    }

    public func toggle() throws {
        switch state {
        case .idle, .complete, .failed, .cancelled, .interrupted:
            _ = try apply(.start)
            _ = try apply(.prepared)
        case .recording:
            _ = try apply(.stop)
        case .preparing, .finalizing, .cleaning, .inserting:
            throw DictationTransitionError.illegal(from: state, event: .start)
        }
    }

    public func register(task: Task<Void, Never>) throws {
        guard activeTask == nil else {
            throw DictationCoordinatorError.workAlreadyActive
        }
        activeTask = task
        diagnostics.record("registered one active processing task")
    }

    public func finishTask() {
        activeTask = nil
        diagnostics.record("released active processing task")
    }

    public func shutdown() {
        activeTask?.cancel()
        activeTask = nil
        if [.preparing, .recording, .finalizing, .cleaning, .inserting].contains(state) {
            _ = try? apply(.cancel)
        }
        diagnostics.record("coordinator shutdown")
    }
}

public struct ToggleShortcut: Codable, Equatable, Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let `default` = ToggleShortcut(
        keyCode: 49,
        modifiers: 0x900
    )
}

public struct ShortcutInput: Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum ToggleShortcutError: Error, Equatable, CustomStringConvertible, Sendable {
    case notMatching

    public var description: String {
        switch self {
        case .notMatching:
            return "shortcut input does not match configured toggle"
        }
    }
}

@MainActor
public final class ToggleShortcutController {
    public private(set) var shortcut: ToggleShortcut
    private let coordinator: DictationCoordinator

    public init(
        shortcut: ToggleShortcut = .default,
        coordinator: DictationCoordinator
    ) {
        self.shortcut = shortcut
        self.coordinator = coordinator
    }

    public func update(shortcut: ToggleShortcut) {
        self.shortcut = shortcut
    }

    @discardableResult
    public func handle(_ input: ShortcutInput) throws -> DictationState {
        guard input == ShortcutInput(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.modifiers
        ) else {
            throw ToggleShortcutError.notMatching
        }
        try coordinator.toggle()
        return coordinator.state
    }
}

public enum IdlePolicy {
    public static let maxIdleCPUPercent = 0.5
    public static let maxIdlePhysicalFootprintBytes: UInt64 = 90 * 1024 * 1024
    public static let usesRecurringPolling = false
    public static let createsProcessingServicesAtLaunch = false
    public static let createsProcessingServicesOnDemand = true
    public static let networkRequestsWhileIdle = 0
    public static let thirdPartyRuntimeDependencies = 0
}
