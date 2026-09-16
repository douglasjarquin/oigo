import Foundation
import OigoCore
import OigoHotKey

@MainActor
extension OigoIssue82ContractTests {
    static func testProductionBridge() throws {
        var state = DictationState.idle
        var trace: [String] = []
        var starts = 0
        var stops = 0
        let scheduler = ManualGestureScheduler()
        let operationBridge = GlobalShortcutOperationBridge(
            state: { state },
            start: {
                starts += 1
                trace.append("start:keyboard")
            },
            stop: {
                stops += 1
                trace.append("stop:keyboard")
            },
            clock: { scheduler.now },
            scheduler: { delay, action in scheduler.schedule(after: delay, action: action) }
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

        scheduler.setNow(milliseconds: 0)
        backend.emit(.pressed, generation: generation)
        state = .recording
        productionBridge.observeState()
        scheduler.setNow(milliseconds: 350)
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
        scheduler.setNow(milliseconds: 1_000)
        backend.emit(.pressed, generation: replacementGeneration)
        backend.emit(.pressed, generation: replacementGeneration)
        state = .recording
        productionBridge.observeState()
        scheduler.setNow(milliseconds: 1_350)
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

    static func testProductionBridgeLifecycleResets() throws {
        var state = DictationState.idle
        var actions: [String] = []
        let scheduler = ManualGestureScheduler()
        let operationBridge = GlobalShortcutOperationBridge(
            state: { state },
            start: { actions.append("start") },
            stop: { actions.append("stop") },
            clock: { scheduler.now },
            scheduler: { delay, action in scheduler.schedule(after: delay, action: action) }
        )
        let productionBridge = GlobalShortcutProductionBridge(operations: operationBridge)

        scheduler.setNow(milliseconds: 0)
        productionBridge.receive(GlobalShortcutEvent(edge: .pressed, generation: 1))
        state = .recording
        scheduler.setNow(milliseconds: 100)
        productionBridge.receive(GlobalShortcutEvent(edge: .released, generation: 1))
        guard operationBridge.gesturePhase == .awaitingSecondPress,
              operationBridge.ownsKeyboardOperation else {
            throw ContractFailure(message: "fixture did not establish pending keyboard ownership")
        }

        for reason in ["popover", "onboarding", "cancel", "interruption", "shutdown"] {
            productionBridge.reset()
            guard operationBridge.gesturePhase == .idle,
                  !operationBridge.ownsKeyboardOperation else {
                throw ContractFailure(message: "\(reason) reset retained keyboard ownership")
            }
        }
        scheduler.fireRetiredAction(at: 0)
        guard actions == ["start"] else {
            throw ContractFailure(message: "retired reset callback invoked an operation actions=\(actions)")
        }

        state = .idle
        scheduler.setNow(milliseconds: 1_000)
        productionBridge.receive(GlobalShortcutEvent(edge: .pressed, generation: 2))
        state = .recording
        scheduler.setNow(milliseconds: 1_350)
        productionBridge.receive(GlobalShortcutEvent(edge: .released, generation: 2))
        guard actions == ["start", "start", "stop"] else {
            throw ContractFailure(message: "fresh operation did not resume after interruption actions=\(actions)")
        }
        print("RESET_RECEIPT reasons=popover,onboarding,cancel,interruption,shutdown repeated=safe retired-timeout=ignored fresh=start,stop")
    }

    static func testAppShortcutLifecycleOrdering() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/Oigo/OigoAppDelegate.swift"),
            encoding: .utf8
        )
        let start = try sourceSlice(
            source,
            from: "    private func performStartDictation(handle: AppOperationHandle) async {",
            to: "    private func performFinishDictation(handle: AppOperationHandle) async {"
        )
        let startRequest = try sourceSlice(
            source,
            from: "    private func startDictation(kind: AppOperationKind = .dictation) {",
            to: "    private func finishDictation() {"
        )
        let acceptedStart = try sourceSlice(
            startRequest,
            from: "        case .success(let handle):",
            to: "        }\n    }"
        )
        let capture = try requiredOffset("let capturedTarget = try await insertion.captureTargetBeforeMicrophonePermission", in: start)
        let publish = try requiredOffset("hudGeometrySnapshot = hudGeometrySession.beginDictation", in: start)
        guard !acceptedStart.contains("updateSurface()"), capture < publish else {
            throw ContractFailure(message: "startup UI publication can precede target capture")
        }

        for (name, begin, end) in [
            ("popover", "    private func handleMouseToggle(allowBeforeSetup: Bool = false) {", "    private func handleGlobalShortcut(_ event: GlobalShortcutEvent) {"),
            ("cancel", "    private func cancelTestDictation() {", "    private func performStartDictation(handle: AppOperationHandle) async {"),
            ("interruption", "    private func handleWorkspaceInterruption(_ reason: String) {", "    private func handleMouseToggle(allowBeforeSetup: Bool = false) {")
        ] {
            let body = try sourceSlice(source, from: begin, to: end)
            guard body.contains("resetShortcutInput()") else {
                throw ContractFailure(message: "\(name) lifecycle does not reset shortcut ownership")
            }
        }

        let onboarding = try sourceSlice(
            source,
            from: "            startTest: { [weak self] generation in",
            to: "            openHistory: { [weak self] in"
        )
        for marker in ["startTest:", "stopTest:", "cancelTest:"] {
            guard onboarding.contains(marker) else {
                throw ContractFailure(message: "missing onboarding lifecycle marker \(marker)")
            }
        }
        let startTest = try sourceSlice(onboarding, from: "startTest:", to: "stopTest:")
        let stopTest = try sourceSlice(onboarding, from: "stopTest:", to: "cancelTest:")
        let launch = try sourceSlice(
            source,
            from: "    func applicationDidFinishLaunching(_ notification: Notification) {",
            to: "    func applicationDidBecomeActive(_ notification: Notification) {"
        )
        let shutdown = try sourceSlice(
            source,
            from: "    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {",
            to: "    private func finishApplicationTermination() async {"
        )
        let replacement = try sourceSlice(
            source,
            from: "    private func saveShortcut(_ candidate: ToggleShortcut) -> OigoShortcutValidation {",
            to: "    func settingsShortcutOwnerBundle() -> OigoSettingsShortcutOwnerBundle {"
        )
        guard startTest.contains("resetShortcutInput()"),
              stopTest.contains("resetShortcutInput()"),
              launch.contains("resetShortcutInput()"),
              try requiredOffset("resetShortcutInput()", in: shutdown)
                < requiredOffset("try shortcutRegistration.shutdown()", in: shutdown),
              try requiredOffset("resetShortcutInput()", in: replacement)
                < requiredOffset("guard validation.isAvailable", in: replacement) else {
            throw ContractFailure(message: "launch, replacement, onboarding, or shutdown lifecycle did not reset shortcut ownership")
        }
        print("ORDER_RECEIPT target=captured-before-ui resets=popover,onboarding-start,onboarding-stop,cancel,interruption,shutdown")
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func sourceSlice(_ source: String, from begin: String, to end: String) throws -> String {
        guard let beginRange = source.range(of: begin),
              let endRange = source.range(of: end, range: beginRange.upperBound..<source.endIndex) else {
            throw ContractFailure(message: "could not locate AppDelegate contract boundary")
        }
        return String(source[beginRange.lowerBound..<endRange.lowerBound])
    }

    private static func requiredOffset(_ marker: String, in source: String) throws -> Int {
        guard let range = source.range(of: marker) else {
            throw ContractFailure(message: "missing AppDelegate ordering marker \(marker)")
        }
        return source.distance(from: source.startIndex, to: range.lowerBound)
    }
}
