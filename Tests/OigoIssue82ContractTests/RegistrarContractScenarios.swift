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

        let callsBeforeDuplicate = backend.calls
        try registrar.register(shortcut: second, onEvent: { event in
            events.append(event)
        })
        guard backend.calls == callsBeforeDuplicate,
              backend.activeRegistrationCount == 1 else {
            throw ContractFailure(message: "duplicate registration was not rejected atomically")
        }
        print("STATE registrar-atomic edges=pressed,released order=candidate-register,previous-unregister active-count=1 duplicate=suppressed")
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
        backend.emitRetired(.pressed, generation: firstGeneration)
        guard events.isEmpty else {
            throw ContractFailure(message: "stale callback from a replaced generation was delivered")
        }

        let teardownBackend = RecordingRegistrationBackend()
        let teardownRegistrar = CarbonGlobalShortcutRegistrar(backend: teardownBackend)
        var previousOwnerEvents: [GlobalShortcutEvent] = []
        var candidateOwnerEvents: [GlobalShortcutEvent] = []
        try teardownRegistrar.register(shortcut: first, onEvent: { event in
            previousOwnerEvents.append(event)
        })
        let teardownFirstGeneration = try activeGeneration(of: teardownRegistrar)
        teardownBackend.failUnregisterFor = first
        var teardownFailurePropagated = false
        do {
            try teardownRegistrar.register(shortcut: second, onEvent: { event in
                candidateOwnerEvents.append(event)
            })
        } catch {
            teardownFailurePropagated = true
        }
        guard teardownFailurePropagated,
              teardownBackend.calls.suffix(3) == [
                  "register:12/256",
                  "unregister:49/768",
                  "unregister:12/256"
              ],
              teardownBackend.activeRegistrationCount == 1,
              !teardownRegistrar.status.isActive,
              teardownRegistrar.lastError?.contains("teardown failed") == true else {
            throw ContractFailure(message: "old-handle teardown failure did not clean the candidate and fail closed")
        }
        teardownBackend.emit(.pressed, generation: teardownFirstGeneration)
        if let candidateGeneration = teardownBackend.generation(for: second) {
            teardownBackend.emitRetired(.released, generation: candidateGeneration)
        }
        guard previousOwnerEvents.isEmpty, candidateOwnerEvents.isEmpty else {
            throw ContractFailure(message: "fail-closed registrar delivered a callback after teardown failure")
        }
        print("STATE registrar-failure candidate-failure=preserved stale=ignored teardown=propagated candidate-cleanup=complete active=false callbacks=0")
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
