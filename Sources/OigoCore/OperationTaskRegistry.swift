import Foundation

public struct OwnedOperationSnapshot: Equatable, Sendable {
    public let operationID: UUID
    public let stage: TranscriptionStage
    public let startedAtNanoseconds: UInt64

    public init(
        operationID: UUID,
        stage: TranscriptionStage,
        startedAtNanoseconds: UInt64
    ) {
        self.operationID = operationID
        self.stage = stage
        self.startedAtNanoseconds = startedAtNanoseconds
    }
}

public final class OperationTaskRegistry: @unchecked Sendable {
    private struct Entry {
        let operationID: UUID
        let stage: TranscriptionStage
        let startedAtNanoseconds: UInt64
        var task: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    public init() {}

    public var activeCount: Int {
        withLock { entries.count }
    }

    public func activeCount(for operationID: UUID) -> Int {
        withLock { entries.values.filter { $0.operationID == operationID }.count }
    }

    @_spi(Testing)
    public var snapshots: [OwnedOperationSnapshot] {
        withLock {
            entries.values.map {
                OwnedOperationSnapshot(
                    operationID: $0.operationID,
                    stage: $0.stage,
                    startedAtNanoseconds: $0.startedAtNanoseconds
                )
            }
        }
    }

    func reserve(
        operationID: UUID,
        stage: TranscriptionStage
    ) -> UUID {
        let token = UUID()
        withLock {
            entries[token] = Entry(
                operationID: operationID,
                stage: stage,
                startedAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
                task: nil
            )
        }
        return token
    }

    func attach(
        _ task: Task<Void, Never>,
        to token: UUID
    ) {
        withLock {
            guard var entry = entries[token] else {
                return
            }
            entry.task = task
            entries[token] = entry
        }
    }

    func release(_ token: UUID) {
        withLock {
            _ = entries.removeValue(forKey: token)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
