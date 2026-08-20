import Foundation

public enum AppOperationKind: String, Codable, CaseIterable, Equatable, Sendable {
    case dictation
    case retry
    case cleanAgain
    case reapplyDictionary
    case pasteAgain
    case onboardingTest
    case interruption
    case shutdown
    case maintenance

    public var isSessionMutating: Bool {
        true
    }

    public var isDictationLifecycle: Bool {
        self == .dictation || self == .onboardingTest
    }

    public var busyDescription: String {
        switch self {
        case .dictation, .onboardingTest:
            "dictation is running"
        case .retry:
            "transcription retry is running"
        case .cleanAgain:
            "Clean Again is running"
        case .reapplyDictionary:
            "Reapply Dictionary is running"
        case .pasteAgain:
            "Paste Again is running"
        case .interruption:
            "an interruption is being handled"
        case .shutdown:
            "Oigo is quitting"
        case .maintenance:
            "maintenance is running"
        }
    }

    var registryStage: TranscriptionStage {
        switch self {
        case .dictation, .onboardingTest:
            .startup
        case .retry, .cleanAgain, .reapplyDictionary, .pasteAgain, .maintenance:
            .retry
        case .interruption:
            .interruption
        case .shutdown:
            .shutdown
        }
    }
}

public enum AppOperationBusyReason: Error, Equatable, Sendable, CustomStringConvertible {
    case shutdown
    case occupied(AppOperationKind)

    public var description: String {
        userMessage
    }

    public var userMessage: String {
        switch self {
        case .shutdown:
            "Oigo is quitting."
        case .occupied(let kind):
            "Oigo is busy: " + kind.busyDescription + ". Try again in a moment."
        }
    }
}

public struct AppOperationHandle: Equatable, Sendable {
    public let id: UUID
    public let generation: UInt64
    public let kind: AppOperationKind

    public init(id: UUID, generation: UInt64, kind: AppOperationKind) {
        self.id = id
        self.generation = generation
        self.kind = kind
    }
}

public struct AppOperationTimeoutPolicy: Equatable, Sendable {
    /// One monotonic app-level budget for Quit. Noncooperative children are fenced when it expires.
    public let quit: Duration

    public static let production = Self(
        quit: TranscriptionTimeoutPolicy.production.budget(for: .shutdown)
    )

    @_spi(Testing)
    public static let testing = Self(quit: .milliseconds(50))

    public var nanoseconds: UInt64 {
        Self.nanoseconds(for: quit)
    }

    static func nanoseconds(for duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = UInt64(max(0, components.seconds))
        let attoseconds = UInt64(max(0, components.attoseconds))
        return seconds &* 1_000_000_000 &+ attoseconds / 1_000_000_000
    }
}

public struct AppCommandAvailability: Equatable, Sendable {
    public let canStartDictation: Bool
    public let canStopDictation: Bool
    public let canRetry: Bool
    public let canCleanAgain: Bool
    public let canReapplyDictionary: Bool
    public let canPasteAgain: Bool
    public let canRunOnboardingTest: Bool
    public let canCancelOnboardingTest: Bool
    public let canRunMaintenance: Bool
    public let settingsApplyToNextDictation: Bool
    public let busyReason: AppOperationBusyReason?

    public var isOnboardingTestActive: Bool {
        canStopDictation
            || canCancelOnboardingTest
            || occupiedDictationLifecycle
    }

    public var onboardingTestActionTitle: String {
        isOnboardingTestActive ? "Stop test dictation" : "Start test dictation"
    }

    public var canUseOnboardingTestAction: Bool {
        if isOnboardingTestActive {
            return canStopDictation || canCancelOnboardingTest
        }
        return canRunOnboardingTest
    }

    private var occupiedDictationLifecycle: Bool {
        if case .occupied(let kind) = busyReason {
            return kind.isDictationLifecycle
        }
        return false
    }

    public static func evaluate(
        coordinatorState: DictationState,
        occupiedKind: AppOperationKind?,
        acceptingCommands: Bool,
        setupComplete: Bool,
        storageReady: Bool
    ) -> AppCommandAvailability {
        let busyReason: AppOperationBusyReason?
        if !acceptingCommands {
            busyReason = .shutdown
        } else if let occupiedKind {
            busyReason = .occupied(occupiedKind)
        } else {
            busyReason = nil
        }
        let idleForSessionWork = acceptingCommands && occupiedKind == nil && storageReady
        let terminalCoordinator = [
            DictationState.idle,
            .complete,
            .failed,
            .cancelled,
            .interrupted
        ].contains(coordinatorState)
        let dictationOccupied = occupiedKind?.isDictationLifecycle == true
        let canStart = setupComplete
            && idleForSessionWork
            && terminalCoordinator
        // A live dictation-lifecycle handle is stoppable even before setup completes.
        let canStop = acceptingCommands
            && storageReady
            && dictationOccupied
            && (coordinatorState == .recording || coordinatorState == .preparing)
        let canHistoryAction = idleForSessionWork && terminalCoordinator
        return AppCommandAvailability(
            canStartDictation: canStart,
            canStopDictation: canStop,
            canRetry: canHistoryAction,
            canCleanAgain: canHistoryAction,
            canReapplyDictionary: canHistoryAction,
            canPasteAgain: canHistoryAction,
            canRunOnboardingTest: idleForSessionWork && terminalCoordinator,
            canCancelOnboardingTest: acceptingCommands && occupiedKind == .onboardingTest,
            canRunMaintenance: canHistoryAction,
            settingsApplyToNextDictation: occupiedKind != nil,
            busyReason: busyReason
        )
    }
}

public struct AppShutdownOutcome: Equatable, Sendable {
    public let repliedWithinBudget: Bool
    public let fencedLoserCount: Int
    public let elapsedNanoseconds: UInt64
    public let budgetNanoseconds: UInt64

    public init(
        repliedWithinBudget: Bool,
        fencedLoserCount: Int,
        elapsedNanoseconds: UInt64 = 0,
        budgetNanoseconds: UInt64 = 0
    ) {
        self.repliedWithinBudget = repliedWithinBudget
        self.fencedLoserCount = fencedLoserCount
        self.elapsedNanoseconds = elapsedNanoseconds
        self.budgetNanoseconds = budgetNanoseconds
    }
}

@MainActor
public final class AppOperationGate {
    private struct Slot {
        var handle: AppOperationHandle
        var task: Task<Void, Never>?
        var taskGeneration: UInt64
        var registryToken: UUID?
    }

    private struct FencedLoser {
        let handle: AppOperationHandle
        let task: Task<Void, Never>
    }

    private let registry: OperationTaskRegistry
    private var generation: UInt64 = 0
    private var slot: Slot?
    private var acceptingCommands = true
    private var fencedLosers: [UUID: FencedLoser] = [:]

    public init(registry: OperationTaskRegistry = OperationTaskRegistry()) {
        self.registry = registry
    }

    public var currentHandle: AppOperationHandle? {
        slot?.handle
    }

    public var currentKind: AppOperationKind? {
        slot?.handle.kind
    }

    public var isIdle: Bool {
        slot == nil && acceptingCommands
    }

    public var isAcceptingCommands: Bool {
        acceptingCommands
    }

    public var fencedLoserCount: Int {
        fencedLosers.count
    }

    public var activeOwnedCount: Int {
        registry.activeCount + (slot == nil ? 0 : 1)
    }

    @_spi(Testing)
    public var registryActiveCount: Int {
        registry.activeCount
    }

    public func availability(
        coordinatorState: DictationState,
        setupComplete: Bool = true,
        storageReady: Bool = true
    ) -> AppCommandAvailability {
        AppCommandAvailability.evaluate(
            coordinatorState: coordinatorState,
            occupiedKind: currentKind,
            acceptingCommands: acceptingCommands,
            setupComplete: setupComplete,
            storageReady: storageReady
        )
    }

    public func begin(
        _ kind: AppOperationKind
    ) -> Result<AppOperationHandle, AppOperationBusyReason> {
        if !acceptingCommands {
            return .failure(.shutdown)
        }
        if let current = slot?.handle {
            return .failure(.occupied(current.kind))
        }
        generation &+= 1
        let handle = AppOperationHandle(id: UUID(), generation: generation, kind: kind)
        slot = Slot(handle: handle, task: nil, taskGeneration: 0, registryToken: nil)
        return .success(handle)
    }

    @discardableResult
    public func beginAndRun(
        _ kind: AppOperationKind,
        completes: Bool = true,
        operation: @escaping @MainActor () async -> Void
    ) -> Result<AppOperationHandle, AppOperationBusyReason> {
        switch begin(kind) {
        case .failure(let reason):
            return .failure(reason)
        case .success(let handle):
            run(handle, completes: completes, operation: operation)
            return .success(handle)
        }
    }

    public func run(
        _ handle: AppOperationHandle,
        completes: Bool = true,
        operation: @escaping @MainActor () async -> Void
    ) {
        guard isCurrent(handle), var slot else {
            return
        }
        slot.task?.cancel()
        slot.taskGeneration &+= 1
        let taskGeneration = slot.taskGeneration
        if let previousToken = slot.registryToken {
            registry.release(previousToken)
        }
        let token = registry.reserve(operationID: handle.id, stage: handle.kind.registryStage)
        slot.registryToken = token
        let task = Task { @MainActor [weak self] in
            await operation()
            guard let self else {
                return
            }
            self.finishRun(
                handle: handle,
                taskGeneration: taskGeneration,
                token: token,
                completes: completes
            )
        }
        registry.attach(task, to: token)
        slot.task = task
        self.slot = slot
    }

    public func isCurrent(_ handle: AppOperationHandle) -> Bool {
        slot?.handle == handle
    }

    public func complete(_ handle: AppOperationHandle) {
        guard isCurrent(handle), let slot else {
            return
        }
        if let token = slot.registryToken {
            registry.release(token)
        }
        self.slot = nil
    }

    public func cancelCurrent() {
        slot?.task?.cancel()
    }

    public func preempt(
        _ kind: AppOperationKind
    ) -> AppOperationHandle {
        if let current = slot {
            current.task?.cancel()
            if let token = current.registryToken {
                registry.release(token)
            }
            if let task = current.task {
                fencedLosers[current.handle.id] = FencedLoser(
                    handle: current.handle,
                    task: task
                )
            }
            slot = nil
        }
        generation &+= 1
        let handle = AppOperationHandle(id: UUID(), generation: generation, kind: kind)
        if kind == .shutdown {
            acceptingCommands = false
        }
        slot = Slot(handle: handle, task: nil, taskGeneration: 0, registryToken: nil)
        return handle
    }

    public func enterShutdown() -> AppOperationHandle {
        if let current = slot, current.handle.kind == .shutdown, acceptingCommands == false {
            return current.handle
        }
        return preempt(.shutdown)
    }

    public func finishShutdown(
        timeout: Duration,
        work: @escaping @MainActor () async -> Void
    ) async -> AppShutdownOutcome {
        let started = DispatchTime.now()
        let budgetNanoseconds = AppOperationTimeoutPolicy.nanoseconds(for: timeout)
        let handle = enterShutdown()
        cancelCurrent()
        fencedLosers.values.forEach { $0.task.cancel() }
        run(handle, completes: false, operation: work)
        let workTask = slot?.task
        let timedOut: Bool
        if let workTask {
            let race = await runUntilTimeout(timeout) {
                await workTask.value
            }
            timedOut = race
        } else {
            timedOut = false
        }
        if timedOut {
            fenceCurrentLosers()
        } else {
            complete(handle)
        }
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds
        return AppShutdownOutcome(
            repliedWithinBudget: timedOut || elapsedNanoseconds <= budgetNanoseconds,
            fencedLoserCount: fencedLosers.count,
            elapsedNanoseconds: elapsedNanoseconds,
            budgetNanoseconds: budgetNanoseconds
        )
    }

    private func finishRun(
        handle: AppOperationHandle,
        taskGeneration: UInt64,
        token: UUID,
        completes: Bool
    ) {
        if let fenced = fencedLosers[handle.id] {
            _ = fenced
            fencedLosers.removeValue(forKey: handle.id)
            registry.release(token)
            return
        }
        guard isCurrent(handle),
              slot?.taskGeneration == taskGeneration else {
            registry.release(token)
            return
        }
        registry.release(token)
        if var slot, slot.registryToken == token {
            slot.registryToken = nil
            slot.task = nil
            self.slot = slot
        }
        if completes {
            complete(handle)
        }
    }

    private func fenceCurrentLosers() {
        guard let slot else {
            return
        }
        slot.task?.cancel()
        if let token = slot.registryToken {
            registry.release(token)
        }
        if let task = slot.task {
            fencedLosers[slot.handle.id] = FencedLoser(handle: slot.handle, task: task)
        }
        generation &+= 1
        self.slot = nil
    }

    private func runUntilTimeout(
        _ timeout: Duration,
        operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let race = TimeoutRace()
        let work = Task {
            await operation()
            race.complete(timedOut: false)
        }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
                race.complete(timedOut: true)
            } catch {
            }
        }
        let timedOut = await race.wait()
        if timedOut {
            work.cancel()
        }
        timer.cancel()
        return timedOut
    }
}

private final class TimeoutRace: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func complete(timedOut: Bool) {
        let continuation: CheckedContinuation<Bool, Never>? = withLock {
            guard self.timedOut == nil else {
                return nil
            }
            self.timedOut = timedOut
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: timedOut)
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let existing: Bool? = withLock {
                if let timedOut {
                    return timedOut
                }
                self.continuation = continuation
                return nil
            }
            if let existing {
                continuation.resume(returning: existing)
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
