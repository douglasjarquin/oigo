import Foundation

public enum TranscriptionStage: String, Codable, CaseIterable, Equatable, Sendable, CustomStringConvertible {
    case startup
    case finalization
    case retry
    case cancellation
    case interruption
    case shutdown

    public var description: String {
        rawValue
    }
}

public struct TranscriptionTimeoutPolicy: Equatable, Sendable {
    public let startup: Duration
    public let finalization: Duration
    public let retry: Duration
    public let cancellation: Duration
    public let interruption: Duration
    public let shutdown: Duration

    public static let production = Self(
        startup: .seconds(15),
        finalization: .seconds(8),
        retry: .seconds(20),
        cancellation: .seconds(2),
        interruption: .seconds(2),
        shutdown: .seconds(3)
    )

    @_spi(Testing)
    public static let testing = Self(
        startup: .milliseconds(50),
        finalization: .milliseconds(100),
        retry: .milliseconds(100),
        cancellation: .milliseconds(100),
        interruption: .milliseconds(100),
        shutdown: .milliseconds(100)
    )

    @_spi(Testing)
    public init(
        startup: Duration,
        finalization: Duration,
        retry: Duration,
        cancellation: Duration,
        interruption: Duration,
        shutdown: Duration
    ) {
        self.startup = startup
        self.finalization = finalization
        self.retry = retry
        self.cancellation = cancellation
        self.interruption = interruption
        self.shutdown = shutdown
    }

    public func budget(for stage: TranscriptionStage) -> Duration {
        switch stage {
        case .startup:
            startup
        case .finalization:
            finalization
        case .retry:
            retry
        case .cancellation:
            cancellation
        case .interruption:
            interruption
        case .shutdown:
            shutdown
        }
    }
}

public enum BoundedOperationError: Error, Equatable, Sendable, CustomStringConvertible {
    case timedOut(TranscriptionStage)

    public var stage: TranscriptionStage {
        switch self {
        case .timedOut(let stage):
            stage
        }
    }

    public var description: String {
        switch self {
        case .timedOut(let stage):
            return "speech operation timed out during " + stage.rawValue
        }
    }
}

public enum BoundedOperation {
    public static func run<Value: Sendable>(
        operationID: UUID,
        stage: TranscriptionStage,
        timeout: Duration,
        registry: OperationTaskRegistry,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = Race<Value>()
        let operationToken = registry.reserve(operationID: operationID, stage: stage)
        let operationTask = Task<Void, Never> {
            defer { registry.release(operationToken) }
            do {
                race.complete(.completed(.success(try await operation())))
            } catch {
                race.complete(.completed(.failure(error)))
            }
        }
        registry.attach(operationTask, to: operationToken)

        let timeoutTask = Task<Void, Never> {
            do {
                try await Task.sleep(for: timeout)
                race.complete(.timedOut)
            } catch {
            }
        }
        let event = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                race.install(continuation)
            }
        }, onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            race.complete(.cancelled)
        })
        switch event {
        case .completed(let result):
            timeoutTask.cancel()
            return try result.get()
        case .timedOut:
            operationTask.cancel()
            throw BoundedOperationError.timedOut(stage)
        case .cancelled:
            operationTask.cancel()
            timeoutTask.cancel()
            throw CancellationError()
        }
    }
}

fileprivate final class Race<Value: Sendable>: @unchecked Sendable {
    fileprivate enum Event {
        case completed(Result<Value, Error>)
        case timedOut
        case cancelled
    }

    private let lock = NSLock()
    private var event: Event?
    private var continuation: CheckedContinuation<Event, Never>?

    fileprivate func install(_ continuation: CheckedContinuation<Event, Never>) {
        let event: Event? = withLock {
            if let existing = self.event {
                return existing
            }
            self.continuation = continuation
            return nil
        }
        if let event {
            continuation.resume(returning: event)
        }
    }

    fileprivate func complete(_ event: Event) {
        let continuation: CheckedContinuation<Event, Never>? = withLock {
            guard self.event == nil else {
                return nil
            }
            self.event = event
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: event)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
