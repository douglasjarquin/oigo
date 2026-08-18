import Carbon.HIToolbox
import OigoCore

enum GlobalShortcutRegistrationError: Error, CustomStringConvertible {
    case installHandler(OSStatus)
    case registerHotKey(OSStatus)

    var description: String {
        switch self {
        case .installHandler(let status):
            return "could not install global shortcut handler: \(status)"
        case .registerHotKey(let status):
            return "could not register global shortcut: \(status)"
        }
    }
}

@MainActor
public final class CarbonGlobalShortcutRegistrar {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (@MainActor () -> Void)?
    private var hotKeyID = EventHotKeyID(signature: 0x4F49474F, id: 1)

    public init() {}

    public func register(
        shortcut: ToggleShortcut,
        action: @escaping @MainActor () -> Void
    ) throws {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: UInt32(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else {
                    return noErr
                }
                let registrar = Unmanaged<CarbonGlobalShortcutRegistrar>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                return registrar.handle(event)
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )
        guard handlerStatus == noErr else {
            throw GlobalShortcutRegistrationError.installHandler(handlerStatus)
        }

        let hotKeyStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard hotKeyStatus == noErr else {
            unregister()
            throw GlobalShortcutRegistrationError.registerHotKey(hotKeyStatus)
        }
    }

    public func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        action = nil
    }

    private func handle(_ event: EventRef?) -> OSStatus {
        guard let event else {
            return noErr
        }

        var pressedID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &pressedID
        )
        guard status == noErr,
              pressedID.signature == hotKeyID.signature,
              pressedID.id == hotKeyID.id else {
            return noErr
        }

        Task { @MainActor [action] in
            action?()
        }
        return noErr
    }
}
