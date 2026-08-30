import OigoCore
import OigoHotKey

@MainActor
extension OigoIssue82ContractTests {
    static func testProductionBridge() throws {
        var state = DictationState.idle
        var trace: [String] = []
        var starts = 0
        var stops = 0
        let operationBridge = GlobalShortcutOperationBridge(
            state: { state },
            start: {
                starts += 1
                trace.append("start:keyboard")
            },
            stop: {
                stops += 1
                trace.append("stop:keyboard")
            }
        )
        let productionBridge = GlobalShortcutProductionBridge(operations: operationBridge)
        let backend = RecordingRegistrationBackend()
        let registrar = CarbonGlobalShortcutRegistrar(backend: backend)
        let shortcut = ToggleShortcut(keyCode: 49, modifiers: 0x300)

        try registrar.register(shortcut: shortcut) { event in
            trace.append(event.edge == .pressed ? "pressed" : "released")
            productionBridge.receive(event)
        }
        let generation = try activeGeneration(of: registrar)

        backend.emit(.pressed, generation: generation)
        state = .recording
        productionBridge.observeState()
        backend.emit(.released, generation: generation)

        guard trace == ["pressed", "start:keyboard", "released", "stop:keyboard"] else {
            throw ContractFailure(message: "production callback trace was \(trace)")
        }

        print("TRACE: " + trace.joined(separator: " -> "))

        let replacement = ToggleShortcut(keyCode: 0, modifiers: 0x100)
        try registrar.register(shortcut: replacement) { event in
            trace.append(event.edge == .pressed ? "pressed" : "released")
            productionBridge.receive(event)
        }
        let replacementGeneration = try activeGeneration(of: registrar)

        trace.removeAll()
        operationBridge.reset()
        state = .idle
        starts = 0
        stops = 0
        backend.emit(.pressed, generation: replacementGeneration)
        backend.emit(.pressed, generation: replacementGeneration)
        state = .recording
        productionBridge.observeState()
        backend.emit(.released, generation: replacementGeneration)
        backend.emit(.released, generation: replacementGeneration)
        guard starts == 1, stops == 1 else {
            throw ContractFailure(message: "duplicate callbacks produced starts=\(starts) stops=\(stops) trace=\(trace)")
        }

        trace.removeAll()
        operationBridge.reset()
        state = .idle
        starts = 0
        stops = 0
        backend.emit(.released, generation: replacementGeneration)
        guard starts == 0, stops == 0 else {
            throw ContractFailure(message: "release-before-start produced a command trace=\(trace)")
        }

        trace.removeAll()
        operationBridge.reset()
        state = .recording
        backend.emit(.pressed, generation: replacementGeneration)
        backend.emit(.released, generation: replacementGeneration)
        guard starts == 0, stops == 0 else {
            throw ContractFailure(message: "mouse-owned recording received a keyboard stop trace=\(trace)")
        }

        trace.removeAll()
        state = .idle
        backend.emitRetired(.pressed, generation: generation)
        backend.emitRetired(.released, generation: generation)
        guard trace.isEmpty else {
            throw ContractFailure(message: "old-generation callbacks crossed the registrar fence trace=\(trace)")
        }

        print("COUNTS: keyboard_start=1 keyboard_stop=1 duplicate_operation=0 mouse_owned_stop=0 stale_generation_callback=0")
    }
}
