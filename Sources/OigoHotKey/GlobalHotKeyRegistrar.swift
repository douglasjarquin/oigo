import Carbon.HIToolbox
import OigoCore

public enum GlobalShortcutRegistrationError: Error, Equatable, CustomStringConvertible, Sendable {
    case installHandler(OSStatus)
    case registerHotKey(OSStatus)

    public var description: String {
        switch self {
        case .installHandler(let status):
            return "could not install the global shortcut handler (OSStatus \(status))"
        case .registerHotKey(let status):
            return "could not register the global shortcut (OSStatus \(status)); choose another shortcut"
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

        func close() {
            if let hotKey {
                UnregisterEventHotKey(hotKey)
                self.hotKey = nil
            }
            if let eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
        }
    }

    private var nextEventID: UInt32 = 0

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
            handle.close()
            throw GlobalShortcutRegistrationError.registerHotKey(hotKeyStatus)
        }
        return handle
    }

    public func unregister(_ handle: any GlobalShortcutRegistrationHandle) {
        (handle as? RegistrationHandle)?.close()
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
            let previous = activeRegistration
            activeRegistration = ActiveRegistration(
                shortcut: shortcut,
                generation: generation,
                handle: handle,
                action: onEvent
            )
            status = .active(shortcut, generation: generation)
            lastError = nil
            if let previous {
                backend.unregister(previous.handle)
            }
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
            backend.unregister(handle)
            lastError = nil
        } catch {
            lastError = String(describing: error)
            throw error
        }
    }

    public func unregister() {
        if let activeRegistration {
            backend.unregister(activeRegistration.handle)
        }
        activeRegistration = nil
        _ = nextGeneration()
        status = .inactive("Global shortcut is not registered")
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
}
