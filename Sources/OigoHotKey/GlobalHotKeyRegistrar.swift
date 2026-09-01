import AppKit
import Carbon.HIToolbox
import OigoCore

public enum GlobalShortcutRegistrationError: Error, Equatable, CustomStringConvertible, Sendable {
    case installHandler(OSStatus)
    case registerHotKey(OSStatus)
    case registerHotKeyCleanup(registerStatus: OSStatus, removeHandlerStatus: OSStatus)
    case unregisterHotKey(OSStatus)
    case removeHandler(OSStatus)

    public var description: String {
        switch self {
        case .installHandler(let status):
            return "could not install the global shortcut handler (OSStatus \(status))"
        case .registerHotKey(let status):
            return "could not register the global shortcut (OSStatus \(status)); choose another shortcut"
        case .registerHotKeyCleanup(let registerStatus, let removeHandlerStatus):
            return "could not register the global shortcut (OSStatus \(registerStatus)) or remove its handler (OSStatus \(removeHandlerStatus))"
        case .unregisterHotKey(let status):
            return "could not unregister the global shortcut (OSStatus \(status))"
        case .removeHandler(let status):
            return "could not remove the global shortcut handler (OSStatus \(status))"
        }
    }
}

public enum GlobalShortcutRegistrarError: Error, Equatable, CustomStringConvertible, Sendable {
    case replacementTeardown(previous: String, candidateCleanup: String?)
    case teardown([String])

    public var description: String {
        switch self {
        case .replacementTeardown(let previous, nil):
            return "previous shortcut teardown failed: \(previous); the candidate was removed and registration is inactive"
        case .replacementTeardown(let previous, let candidateCleanup?):
            return "previous shortcut teardown failed: \(previous); candidate cleanup also failed: \(candidateCleanup); registration is inactive"
        case .teardown(let failures):
            return "shortcut teardown failed: \(failures.joined(separator: "; ")); registration is inactive"
        }
    }
}

@MainActor
public final class CarbonGlobalShortcutBackend: GlobalShortcutRegistrationBackend {
    private final class RegistrationHandle: GlobalShortcutRegistrationHandle {
        let generation: UInt64
        let hotKeyID: EventHotKeyID
        let receive: @MainActor (GlobalShortcutEvent) -> Void
        var hotKey: EventHotKeyRef?
        var eventHandler: EventHandlerRef?

        init(
            generation: UInt64,
            hotKeyID: EventHotKeyID,
            receive: @escaping @MainActor (GlobalShortcutEvent) -> Void
        ) {
            self.generation = generation
            self.hotKeyID = hotKeyID
            self.receive = receive
        }

        func handle(_ event: EventRef?) -> OSStatus {
            guard let event else {
                return noErr
            }

            var eventHotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &eventHotKeyID
            )
            guard status == noErr,
                  eventHotKeyID.signature == hotKeyID.signature,
                  eventHotKeyID.id == hotKeyID.id else {
                return noErr
            }

            let edge: GlobalShortcutEdge
            switch UInt32(GetEventKind(event)) {
            case UInt32(kEventHotKeyPressed):
                edge = .pressed
            case UInt32(kEventHotKeyReleased):
                edge = .released
            default:
                return noErr
            }
            let shortcutEvent = GlobalShortcutEvent(edge: edge, generation: generation)
            Task { @MainActor [receive] in
                receive(shortcutEvent)
            }
            return noErr
        }

        func close() throws {
            if let hotKey {
                let status = UnregisterEventHotKey(hotKey)
                guard status == noErr else {
                    throw GlobalShortcutRegistrationError.unregisterHotKey(status)
                }
                self.hotKey = nil
            }
            if let eventHandler {
                let status = RemoveEventHandler(eventHandler)
                guard status == noErr else {
                    throw GlobalShortcutRegistrationError.removeHandler(status)
                }
                self.eventHandler = nil
            }
        }
    }

    private var nextEventID: UInt32 = 0
    private var retainedFailedRegistrations: [RegistrationHandle] = []

    public init() {}

    public func register(
        shortcut: ToggleShortcut,
        generation: UInt64,
        receive: @escaping @MainActor (GlobalShortcutEvent) -> Void
    ) throws -> any GlobalShortcutRegistrationHandle {
        nextEventID = nextEventID == UInt32.max ? 1 : nextEventID + 1
        let handle = RegistrationHandle(
            generation: generation,
            hotKeyID: EventHotKeyID(signature: 0x4F49474F, id: nextEventID),
            receive: receive
        )
        var eventTypes = [
            EventTypeSpec(
                eventClass: UInt32(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: UInt32(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]
        let userData = Unmanaged.passUnretained(handle).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else {
                    return noErr
                }
                let handle = Unmanaged<RegistrationHandle>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                return handle.handle(event)
            },
            eventTypes.count,
            &eventTypes,
            userData,
            &handle.eventHandler
        )
        guard handlerStatus == noErr else {
            throw GlobalShortcutRegistrationError.installHandler(handlerStatus)
        }

        let hotKeyStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            handle.hotKeyID,
            GetApplicationEventTarget(),
            0,
            &handle.hotKey
        )
        guard hotKeyStatus == noErr else {
            do {
                try handle.close()
            } catch let GlobalShortcutRegistrationError.removeHandler(removeHandlerStatus) {
                retainedFailedRegistrations.append(handle)
                throw GlobalShortcutRegistrationError.registerHotKeyCleanup(
                    registerStatus: hotKeyStatus,
                    removeHandlerStatus: removeHandlerStatus
                )
            }
            throw GlobalShortcutRegistrationError.registerHotKey(hotKeyStatus)
        }
        return handle
    }

    public func unregister(_ handle: any GlobalShortcutRegistrationHandle) throws {
        try (handle as? RegistrationHandle)?.close()
    }
}

@MainActor
public final class CarbonGlobalShortcutRegistrar {
    private struct ActiveRegistration {
        let shortcut: ToggleShortcut
        let generation: UInt64
        let handle: any GlobalShortcutRegistrationHandle
        let action: @MainActor (GlobalShortcutEvent) -> Void
    }

    private let backend: any GlobalShortcutRegistrationBackend
    private var activeRegistration: ActiveRegistration?
    private var retainedFailedHandles: [any GlobalShortcutRegistrationHandle] = []
    private var nextGenerationValue: UInt64 = 0

    public private(set) var status = GlobalShortcutRegistrationStatus.inactive(
        "Global shortcut is not registered"
    )
    public private(set) var lastError: String?

    public init(backend: any GlobalShortcutRegistrationBackend = CarbonGlobalShortcutBackend()) {
        self.backend = backend
    }

    public func register(
        shortcut: ToggleShortcut,
        onEvent: @escaping @MainActor (GlobalShortcutEvent) -> Void
    ) throws {
        if let activeRegistration,
           activeRegistration.shortcut == shortcut {
            self.activeRegistration = ActiveRegistration(
                shortcut: shortcut,
                generation: activeRegistration.generation,
                handle: activeRegistration.handle,
                action: onEvent
            )
            lastError = nil
            return
        }

        let generation = nextGeneration()
        let eventAction: @MainActor (GlobalShortcutEvent) -> Void = { [weak self] event in
            self?.deliver(event)
        }
        do {
            let handle = try backend.register(
                shortcut: shortcut,
                generation: generation,
                receive: eventAction
            )
            let candidate = ActiveRegistration(
                shortcut: shortcut,
                generation: generation,
                handle: handle,
                action: onEvent
            )
            if let previous = activeRegistration {
                do {
                    try backend.unregister(previous.handle)
                } catch {
                    failClosed(retaining: previous.handle)
                    let previousFailure = String(describing: error)
                    let candidateCleanupFailure: String?
                    do {
                        try backend.unregister(candidate.handle)
                        candidateCleanupFailure = nil
                    } catch {
                        retainedFailedHandles.append(candidate.handle)
                        candidateCleanupFailure = String(describing: error)
                    }
                    let failure = GlobalShortcutRegistrarError.replacementTeardown(
                        previous: previousFailure,
                        candidateCleanup: candidateCleanupFailure
                    )
                    lastError = failure.description
                    status = .inactive(failure.description)
                    throw failure
                }
            }
            activeRegistration = candidate
            status = .active(shortcut, generation: generation)
            lastError = nil
        } catch {
            let reason = String(describing: error)
            lastError = reason
            if activeRegistration == nil {
                status = .inactive(reason)
            }
            throw error
        }
    }

    public func probe(shortcut: ToggleShortcut) throws {
        if activeRegistration?.shortcut == shortcut {
            lastError = nil
            return
        }
        let generation = nextGeneration()
        let eventAction: @MainActor (GlobalShortcutEvent) -> Void = { [weak self] event in
            self?.deliver(event)
        }
        do {
            let handle = try backend.register(
                shortcut: shortcut,
                generation: generation,
                receive: eventAction
            )
            do {
                try backend.unregister(handle)
            } catch {
                if let activeRegistration {
                    retainedFailedHandles.append(activeRegistration.handle)
                    self.activeRegistration = nil
                }
                retainedFailedHandles.append(handle)
                _ = nextGeneration()
                let failure = GlobalShortcutRegistrarError.teardown([String(describing: error)])
                status = .inactive(failure.description)
                lastError = failure.description
                throw failure
            }
            lastError = nil
        } catch {
            lastError = String(describing: error)
            throw error
        }
    }

    public func unregister() throws {
        var handles = retainedFailedHandles
        retainedFailedHandles = []
        if let activeRegistration { handles.append(activeRegistration.handle) }
        activeRegistration = nil
        _ = nextGeneration()
        status = .inactive("Global shortcut is not registered")
        var failures: [String] = []
        for handle in handles {
            do {
                try backend.unregister(handle)
            } catch {
                retainedFailedHandles.append(handle)
                failures.append(String(describing: error))
            }
        }
        guard failures.isEmpty else {
            let failure = GlobalShortcutRegistrarError.teardown(failures)
            status = .inactive(failure.description)
            lastError = failure.description
            throw failure
        }
        lastError = nil
    }

    private func nextGeneration() -> UInt64 {
        nextGenerationValue = nextGenerationValue == UInt64.max ? 1 : nextGenerationValue + 1
        return nextGenerationValue
    }

    private func deliver(_ event: GlobalShortcutEvent) {
        guard let activeRegistration,
              activeRegistration.generation == event.generation else {
            return
        }
        activeRegistration.action(event)
    }

    private func failClosed(retaining handle: any GlobalShortcutRegistrationHandle) {
        retainedFailedHandles.append(handle)
        activeRegistration = nil
        _ = nextGeneration()
    }
}

@MainActor
public final class FnKeyMonitor {
    public typealias Handler = @MainActor (FnShortcutGestureEdge, TimeInterval) -> Void

    private let handler: Handler
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var edgeDetector = FnKeyEdgeDetector()

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func start() {
        guard globalMonitor == nil, localMonitor == nil else {
            return
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.receive(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.receive(event)
            return event
        }
    }

    public var isGlobalMonitoringActive: Bool {
        globalMonitor != nil
    }

    public func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        edgeDetector.reset()
    }

    private func receive(_ event: NSEvent) {
        guard let edge = edgeDetector.receive(
            keyCode: event.keyCode,
            functionFlagSet: event.modifierFlags.contains(.function)
        ) else {
            return
        }
        handler(edge, event.timestamp)
    }
}

public struct FnKeyEdgeDetector: Sendable {
    private var functionKeyDown = false

    public init() {}

    public mutating func receive(
        keyCode: UInt16,
        functionFlagSet: Bool
    ) -> FnShortcutGestureEdge? {
        guard keyCode == UInt16(kVK_Function), functionFlagSet != functionKeyDown else {
            return nil
        }
        functionKeyDown = functionFlagSet
        return functionFlagSet ? .pressed : .released
    }

    public mutating func reset() {
        functionKeyDown = false
    }
}

public enum FixedFnShortcutRegistrationError: Error, Equatable, CustomStringConvertible, Sendable {
    case nonFnShortcut

    public var description: String {
        "Only the fixed Fn shortcut is supported"
    }
}

@MainActor
public final class FixedFnShortcutRegistrationClient: GlobalShortcutRegistrationClient {
    private var generation: UInt64 = 0

    public private(set) var status = GlobalShortcutRegistrationStatus.inactive(
        "Global shortcut registration is waiting for setup"
    )
    public private(set) var lastError: String?

    public init() {}

    public func register(
        shortcut: ToggleShortcut,
        onEvent: @escaping @MainActor (GlobalShortcutEvent) -> Void
    ) throws {
        _ = onEvent
        guard shortcut == .fixedFn else {
            throw FixedFnShortcutRegistrationError.nonFnShortcut
        }
        generation += 1
        status = .active(shortcut, generation: generation)
        lastError = nil
    }

    public func probe(shortcut: ToggleShortcut) throws {
        guard shortcut == .fixedFn else {
            throw FixedFnShortcutRegistrationError.nonFnShortcut
        }
        lastError = nil
    }

    public func unregister() throws {
        status = .inactive("Global shortcut is not registered")
        lastError = nil
    }
}
