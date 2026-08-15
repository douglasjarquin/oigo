import Darwin
import Foundation
import OigoCore

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}
@main
@MainActor
private struct OigoIssue3ContractTests {
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("all legal state transitions", testAllLegalTransitions),
            ("illegal and duplicate transitions", testIllegalTransitions),
            ("toggle shortcut starts and stops", testToggleShortcut),
            ("one active task and quit cleanup", testTaskCleanup),
            ("quit cleanup from every state", testShutdownFromEveryState),
            ("idle policy", testIdlePolicy)
        ]

        var failures = 0
        for (name, test) in tests {
            do {
                try await test()
                print("GREEN: " + name)
            } catch {
                failures += 1
                print("FAIL: " + name + ": " + String(describing: error))
            }
        }

        if failures == 0 {
            print("GREEN: all issue #3 contract scenarios")
            exit(0)
        }

        print("FAILURES=" + String(failures))
        exit(1)
    }

    private static func testAllLegalTransitions() throws {
        for transition in DictationStateMachine.legalTransitions {
            var machine = DictationStateMachine(initialState: transition.from)
            let actual = try machine.apply(transition.event)
            guard actual == transition.to else {
                throw ContractFailure(
                    message: "expected (transition.from) + (transition.event) -> (transition.to), got (actual)"
                )
            }
        }
    }

    private static func testIllegalTransitions() throws {
        let legal = Set(
            DictationStateMachine.legalTransitions.map {
                DictationStateMachine.TransitionKey(
                    from: $0.from,
                    event: $0.event
                )
            }
        )

        for state in DictationState.allCases {
            for event in DictationEvent.allCases {
                let key = DictationStateMachine.TransitionKey(from: state, event: event)
                guard !legal.contains(key) else {
                    continue
                }

                var machine = DictationStateMachine(initialState: state)
                do {
                    _ = try machine.apply(event)
                    throw ContractFailure(
                        message: "illegal transition was accepted: (state) + (event)"
                    )
                } catch let error as DictationTransitionError {
                    guard case .illegal(let from, let rejectedEvent) = error,
                          from == state,
                          rejectedEvent == event else {
                        throw ContractFailure(
                            message: "wrong error for (state) + (event): (error)"
                        )
                    }
                }
            }
        }
    }

    private static func testToggleShortcut() throws {
        let shortcut = ToggleShortcut(keyCode: 49, modifiers: 0x100000)
        let coordinator = DictationCoordinator()
        let controller = ToggleShortcutController(
            shortcut: shortcut,
            coordinator: coordinator
        )

        let first = try controller.handle(
            ShortcutInput(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
        )
        guard first == .recording, coordinator.state == .recording else {
            throw ContractFailure(message: "first toggle did not enter recording")
        }

        let second = try controller.handle(
            ShortcutInput(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
        )
        guard second == .finalizing, coordinator.state == .finalizing else {
            throw ContractFailure(message: "second toggle did not enter finalizing")
        }

        do {
            _ = try controller.handle(ShortcutInput(keyCode: 36, modifiers: 0))
            throw ContractFailure(message: "unconfigured shortcut was accepted")
        } catch let error as ToggleShortcutError {
            guard error == .notMatching else {
                throw ContractFailure(message: "unexpected shortcut error: (error)")
            }
        }
    }

    private static func testTaskCleanup() async throws {
        let coordinator = DictationCoordinator()
        try coordinator.toggle()

        let task = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        try coordinator.register(task: task)

        do {
            try coordinator.register(
                task: Task<Void, Never> {
                    await Task.yield()
                }
            )
            throw ContractFailure(message: "parallel task registration was accepted")
        } catch let error as DictationCoordinatorError {
            guard error == .workAlreadyActive else {
                throw ContractFailure(message: "unexpected task error: (error)")
            }
        }

        coordinator.shutdown()
        _ = await task.value
        guard coordinator.activeTaskCount == 0,
              coordinator.state == .cancelled else {
            throw ContractFailure(message: "shutdown did not cancel state and active task")
        }
    }

    private static func testShutdownFromEveryState() {
        let activeStates: Set<DictationState> = [
            .preparing,
            .recording,
            .finalizing,
            .cleaning,
            .inserting
        ]

        for state in DictationState.allCases {
            let coordinator = DictationCoordinator(initialState: state)
            coordinator.shutdown()
            guard coordinator.activeTaskCount == 0 else {
                fatalError("active task remained after shutdown from (state)")
            }
            if activeStates.contains(state) {
                guard coordinator.state == .cancelled else {
                    fatalError("active state (state) did not cancel on shutdown")
                }
            }
        }
    }

    private static func testIdlePolicy() {
        guard !IdlePolicy.usesRecurringPolling,
              !IdlePolicy.createsProcessingServicesAtLaunch,
              IdlePolicy.maxIdlePhysicalFootprintBytes == 90 * 1024 * 1024,
              IdlePolicy.maxIdleCPUPercent == 0.5 else {
            fatalError("idle policy does not match issue #3 constraints")
        }
    }
}
