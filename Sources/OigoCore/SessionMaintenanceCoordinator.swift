import Foundation

public enum SessionMaintenanceTrigger: Equatable, Sendable {
    case startup
    case sessionTerminal
    case settingsChanged
    case explicit
}

public struct SessionMaintenanceSummary: Equatable, Sendable {
    public let inspectedDirectoryCount: Int
    public let skippedDirectoryCount: Int
    public let removedSessionCount: Int
    public let removedAudioCount: Int
    public let moreWorkRemains: Bool

    public init(
        inspectedDirectoryCount: Int,
        skippedDirectoryCount: Int,
        removedSessionCount: Int,
        removedAudioCount: Int,
        moreWorkRemains: Bool
    ) {
        self.inspectedDirectoryCount = inspectedDirectoryCount
        self.skippedDirectoryCount = skippedDirectoryCount
        self.removedSessionCount = removedSessionCount
        self.removedAudioCount = removedAudioCount
        self.moreWorkRemains = moreWorkRemains
    }

    public init(_ result: SessionMaintenanceResult) {
        self.init(
            inspectedDirectoryCount: result.inspectedDirectoryCount,
            skippedDirectoryCount: result.skippedDirectoryCount,
            removedSessionCount: result.removedSessionIDs.count,
            removedAudioCount: result.removedAudioSessionIDs.count,
            moreWorkRemains: result.moreWorkRemains
        )
    }

    public var sanitizedMessage: String {
        let removed = removedSessionCount + removedAudioCount
        if inspectedDirectoryCount == 0 && removed == 0 {
            return "Idle maintenance found nothing to remove."
        }
        var message = "Idle maintenance inspected "
            + String(inspectedDirectoryCount)
            + " folder"
            + (inspectedDirectoryCount == 1 ? "" : "s")
        if removed > 0 {
            message += " and removed "
                + String(removed)
                + " expired artifact set"
                + (removed == 1 ? "" : "s")
        }
        if moreWorkRemains {
            message += "; more work remains"
        }
        return message + "."
    }
}

@MainActor
public final class SessionMaintenanceCoordinator {
    public typealias CanRun = () -> Bool
    public typealias BeginRun = () -> Bool
    public typealias EndRun = () -> Void
    public typealias Perform = @Sendable (SessionMaintenanceCursor?) throws -> SessionMaintenanceResult

    private let canRun: CanRun
    private let beginRun: BeginRun
    private let endRun: EndRun
    private let perform: Perform
    private let onComplete: ((SessionMaintenanceSummary) -> Void)?
    private var pending = false
    private var running = false
    private var preempted = false
    private var cursor: SessionMaintenanceCursor?
    private var lastSummary: SessionMaintenanceSummary?
    private var activeTask: Task<Void, Never>?
    private var requestCount = 0
    private var runCount = 0

    public init(
        canRun: @escaping CanRun,
        beginRun: @escaping BeginRun = { true },
        endRun: @escaping EndRun = {},
        perform: @escaping Perform,
        onComplete: ((SessionMaintenanceSummary) -> Void)? = nil
    ) {
        self.canRun = canRun
        self.beginRun = beginRun
        self.endRun = endRun
        self.perform = perform
        self.onComplete = onComplete
    }

    @_spi(Testing)
    public var isRunning: Bool {
        running
    }

    @_spi(Testing)
    public var hasPendingWork: Bool {
        pending
    }

    @_spi(Testing)
    public var coalescedRequestCount: Int {
        requestCount
    }

    @_spi(Testing)
    public var performedPassCount: Int {
        runCount
    }

    public var sanitizedLastSummary: SessionMaintenanceSummary? {
        lastSummary
    }

    public func request(_ trigger: SessionMaintenanceTrigger) {
        _ = trigger
        requestCount += 1
        pending = true
        preempted = false
        startIfNeeded()
    }

    public func preempt() {
        preempted = true
        activeTask?.cancel()
    }

    public func resumeIfNeeded() {
        preempted = false
        startIfNeeded()
    }

    @_spi(Testing)
    public func waitUntilIdle(timeoutNanoseconds: UInt64 = 1_000_000_000) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while running && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return !running
    }

    private func startIfNeeded() {
        guard !running, pending else {
            return
        }
        guard !preempted, canRun() else {
            return
        }
        guard beginRun() else {
            return
        }
        running = true
        pending = false
        let cursor = self.cursor
        let perform = self.perform
        activeTask = Task.detached { [weak self] in
            let result = Result { try perform(cursor) }
            await self?.finish(result)
        }
    }

    private func finish(_ result: Result<SessionMaintenanceResult, Error>) {
        endRun()
        runCount += 1
        running = false
        activeTask = nil
        switch result {
        case .success(let maintenance):
            lastSummary = SessionMaintenanceSummary(maintenance)
            cursor = maintenance.moreWorkRemains ? maintenance.cursor : nil
            pending = maintenance.moreWorkRemains
            onComplete?(SessionMaintenanceSummary(maintenance))
        case .failure:
            lastSummary = nil
            pending = false
        }
        if preempted {
            pending = true
        }
    }
}
