import OigoCore
import OigoHotKey

@MainActor
extension OigoIssue82ContractTests {
    static func testRegistrarAtomicReplacement() throws {
        let backend = RecordingRegistrationBackend()
        let registrar = CarbonGlobalShortcutRegistrar(backend: backend)
        let first = ToggleShortcut(keyCode: 49, modifiers: 0x300)
        let second = ToggleShortcut(keyCode: 0, modifiers: 0x100)
        var events: [GlobalShortcutEvent] = []

        try registrar.register(shortcut: first, onEvent: { event in
            events.append(event)
        })
        let firstGeneration = try activeGeneration(of: registrar)
        backend.emit(.pressed, generation: firstGeneration)
        backend.emit(.released, generation: firstGeneration)
        guard events.map(\.edge) == [.pressed, .released] else {
            throw ContractFailure(message: "registrar did not deliver both press and release edges")
        }

        let callsBeforeProbe = backend.calls
        try registrar.probe(shortcut: second)
        guard backend.calls == callsBeforeProbe + ["register:0/256", "unregister:0/256"],
              try activeShortcut(of: registrar) == first else {
            throw ContractFailure(message: "successful validation probe displaced the working registration")
        }

        try registrar.register(shortcut: second, onEvent: { event in
            events.append(event)
        })
        guard backend.calls.suffix(2) == ["register:0/256", "unregister:49/768"],
              try activeShortcut(of: registrar) == second else {
            throw ContractFailure(message: "replacement did not register the candidate before removing the prior shortcut")
        }
    }

    static func testRegistrarFailureAndGeneration() throws {
        let backend = RecordingRegistrationBackend()
        let registrar = CarbonGlobalShortcutRegistrar(backend: backend)
        let first = ToggleShortcut(keyCode: 49, modifiers: 0x300)
        let second = ToggleShortcut(keyCode: 12, modifiers: 0x100)
        var events: [GlobalShortcutEvent] = []
        try registrar.register(shortcut: first, onEvent: { event in
            events.append(event)
        })
        let firstGeneration = try activeGeneration(of: registrar)
        backend.failFor = second

        do {
            try registrar.register(shortcut: second, onEvent: { event in
                events.append(event)
            })
            throw ContractFailure(message: "failed candidate registration was accepted")
        } catch let error as TestRegistrationError {
            guard error.description.contains("12/256") else {
                throw ContractFailure(message: "candidate failure was not actionable")
            }
        }

        guard try activeShortcut(of: registrar) == first,
              backend.calls.suffix(1) == ["register:12/256"],
              registrar.lastError?.contains("12/256") == true else {
            throw ContractFailure(message: "failed replacement removed or hid the prior working registration")
        }

        backend.failFor = nil
        try registrar.register(shortcut: second, onEvent: { event in
            events.append(event)
        })
        backend.emit(.pressed, generation: firstGeneration)
        guard events.isEmpty else {
            throw ContractFailure(message: "stale callback from a replaced generation was delivered")
        }
    }

    static func activeGeneration(of registrar: CarbonGlobalShortcutRegistrar) throws -> UInt64 {
        guard case .active(_, let generation) = registrar.status else {
            throw ContractFailure(message: "registrar was not active")
        }
        return generation
    }

    static func activeShortcut(of registrar: CarbonGlobalShortcutRegistrar) throws -> ToggleShortcut {
        guard case .active(let shortcut, _) = registrar.status else {
            throw ContractFailure(message: "registrar was not active")
        }
        return shortcut
    }
}
