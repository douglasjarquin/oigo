import Carbon.HIToolbox
import ApplicationServices
import CoreGraphics
import OigoCore

public enum GlobalShortcutRegistrationError: Error, Equatable, CustomStringConvertible, Sendable {
    case installHandler(OSStatus)
    case registerHotKey(OSStatus)
    case registerHotKeyCleanup(registerStatus: OSStatus, removeHandlerStatus: OSStatus)
    case unregisterHotKey(OSStatus)
    case removeHandler(OSStatus)
    case functionKeyPermissionRequired
    case functionKeyTapUnavailable

    public var description: String {
        switch self {
        case .functionKeyPermissionRequired:
            return "Fn requires Accessibility permission. Enable Oigo in System Settings > Privacy & Security > Accessibility, then save the shortcut again"
        case .functionKeyTapUnavailable:
            return "Could not create the Fn keyboard event tap. Check Oigo's Accessibility permission, then save the shortcut again"
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
    private let functionKeyBackend: any GlobalShortcutRegistrationBackend

    public init(functionKeyBackend: any GlobalShortcutRegistrationBackend = FunctionKeyShortcutBackend()) {
        self.functionKeyBackend = functionKeyBackend
    }

    public func register(
        shortcut: ToggleShortcut,
        generation: UInt64,
        receive: @escaping @MainActor (GlobalShortcutEvent) -> Void
    ) throws -> any GlobalShortcutRegistrationHandle {
        if shortcut.isFunctionKey {
            return try functionKeyBackend.register(shortcut: shortcut, generation: generation, receive: receive)
        }
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
        if let handle = handle as? RegistrationHandle {
            try handle.close()
        } else {
            try functionKeyBackend.unregister(handle)
        }
    }
}

@MainActor
public final class FunctionKeyShortcutBackend: GlobalShortcutRegistrationBackend {
    private let accessibilityTrusted: () -> Bool

    public init(accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.accessibilityTrusted = accessibilityTrusted
    }

    private final class Handle: GlobalShortcutRegistrationHandle {
        let generation: UInt64
        let receive: @MainActor (GlobalShortcutEvent) -> Void
        var tap: CFMachPort?
        var source: CFRunLoopSource?
        var state = FunctionKeyShortcutState(
            isDown: CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        )

        init(generation: UInt64, receive: @escaping @MainActor (GlobalShortcutEvent) -> Void) {
            self.generation = generation
            self.receive = receive
        }

        func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let edge = state.reset(
                    isDown: CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
                ) {
                    deliver(edge)
                }
                if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard type == .flagsChanged,
                  event.getIntegerValueField(.keyboardEventKeycode) == Int64(ToggleShortcut.fnKeyCode) else {
                return Unmanaged.passUnretained(event)
            }
            if let edge = state.update(isDown: event.flags.contains(.maskSecondaryFn)) {
                deliver(edge)
            }
            return nil
        }

        private func deliver(_ edge: GlobalShortcutEdge) {
            let event = GlobalShortcutEvent(edge: edge, generation: generation)
            Task { @MainActor [receive] in receive(event) }
        }

        func close() {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            tap = nil
            source = nil
        }
    }

    public func register(
        shortcut: ToggleShortcut,
        generation: UInt64,
        receive: @escaping @MainActor (GlobalShortcutEvent) -> Void
    ) throws -> any GlobalShortcutRegistrationHandle {
        guard shortcut == .fn else {
            throw ShortcutConfigurationError.invalidCommittedShortcut("The Fn backend only accepts Fn by itself")
        }
        guard accessibilityTrusted() else {
            throw GlobalShortcutRegistrationError.functionKeyPermissionRequired
        }
        let handle = Handle(generation: generation, receive: receive)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let handle = Unmanaged<Handle>.fromOpaque(context).takeUnretainedValue()
                let consumed = MainActor.assumeIsolated {
                    handle.handle(type: type, event: event) == nil
                }
                return consumed ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(handle).toOpaque()
        ) else {
            throw GlobalShortcutRegistrationError.functionKeyTapUnavailable
        }
        handle.tap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            handle.close()
            throw GlobalShortcutRegistrationError.functionKeyTapUnavailable
        }
        handle.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            handle.close()
            throw GlobalShortcutRegistrationError.functionKeyTapUnavailable
        }
        return handle
    }

    public func unregister(_ handle: any GlobalShortcutRegistrationHandle) throws {
        (handle as? Handle)?.close()
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
