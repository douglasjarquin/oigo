import OigoCore
import OigoHotKey

@MainActor
final class RecordingRegistrationBackend: GlobalShortcutRegistrationBackend {
    private final class Handle: GlobalShortcutRegistrationHandle {
        let id: UInt64

        init(id: UInt64) {
            self.id = id
        }
    }

    private struct Registration {
        let shortcut: ToggleShortcut
        let generation: UInt64
        let handle: Handle
        let receive: @MainActor (GlobalShortcutEvent) -> Void
    }

    private var nextID: UInt64 = 0
    private var registrations: [Registration] = []
    private var retiredRegistrations: [Registration] = []
    private(set) var calls: [String] = []
    var failFor: ToggleShortcut?
    var failUnregisterFor: ToggleShortcut?

    func register(
        shortcut: ToggleShortcut,
        generation: UInt64,
        receive: @escaping @MainActor (GlobalShortcutEvent) -> Void
    ) throws -> any GlobalShortcutRegistrationHandle {
        calls.append("register:\(shortcut.keyCode)/\(shortcut.modifiers)")
        if failFor == shortcut {
            throw TestRegistrationError(shortcut: shortcut)
        }
        nextID += 1
        let handle = Handle(id: nextID)
        registrations.append(
            Registration(
                shortcut: shortcut,
                generation: generation,
                handle: handle,
                receive: receive
            )
        )
        return handle
    }

    func unregister(_ handle: any GlobalShortcutRegistrationHandle) throws {
        guard let handle = handle as? Handle else {
            return
        }
        if let registration = registrations.first(where: { $0.handle.id == handle.id }) {
            calls.append("unregister:\(registration.shortcut.keyCode)/\(registration.shortcut.modifiers)")
            if failUnregisterFor == registration.shortcut {
                throw TestTeardownError(shortcut: registration.shortcut)
            }
            retiredRegistrations.append(registration)
        }
        registrations.removeAll { $0.handle.id == handle.id }
    }

    func emit(_ edge: GlobalShortcutEdge, generation: UInt64) {
        for registration in registrations where registration.generation == generation {
            registration.receive(GlobalShortcutEvent(edge: edge, generation: generation))
        }
    }

    func emitRetired(_ edge: GlobalShortcutEdge, generation: UInt64) {
        for registration in retiredRegistrations where registration.generation == generation {
            registration.receive(GlobalShortcutEvent(edge: edge, generation: generation))
        }
    }

    var activeRegistrationCount: Int {
        registrations.count
    }

    func generation(for shortcut: ToggleShortcut) -> UInt64? {
        (registrations + retiredRegistrations)
            .last(where: { $0.shortcut == shortcut })?
            .generation
    }
}

struct TestTeardownError: Error, CustomStringConvertible {
    let shortcut: ToggleShortcut

    var description: String {
        "could not unregister shortcut \(shortcut.keyCode)/\(shortcut.modifiers)"
    }
}

struct TestRegistrationError: Error, CustomStringConvertible {
    let shortcut: ToggleShortcut

    var description: String {
        "could not register shortcut \(shortcut.keyCode)/\(shortcut.modifiers) because it is occupied"
    }
}
