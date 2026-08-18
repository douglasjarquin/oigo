import Foundation

public enum InsertionTargetHandoffResult: Equatable, Sendable {
    case ready(InsertionTargetSnapshot)
    case timedOut
    case cancelled
}

@MainActor
public final class InsertionTargetHandoff {
    private let maxAttempts: Int
    private let waitForDestination: @MainActor () async -> Void

    public init(
        maxAttempts: Int = 6,
        waitForDestination: @escaping @MainActor () async -> Void = { await Task.yield() }
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.waitForDestination = waitForDestination
    }

    public func select(
        capture: @escaping @MainActor () -> InsertionTargetSnapshot,
        discard: @escaping @MainActor (InsertionTargetSnapshot) -> Void = { _ in }
    ) async -> InsertionTargetHandoffResult {
        var previous: InsertionTargetSnapshot?
        for _ in 0..<maxAttempts {
            if Task.isCancelled {
                if let previous {
                    discard(previous)
                }
                return .cancelled
            }
            await waitForDestination()
            if Task.isCancelled {
                if let previous {
                    discard(previous)
                }
                return .cancelled
            }
            let current = capture()
            guard current.canBeSelectedForPaste else {
                discard(current)
                previous = nil
                continue
            }
            if let previous, previous.matches(current) {
                return .ready(current)
            }
            if let previous {
                discard(previous)
            }
            previous = current
        }
        if let previous {
            discard(previous)
        }
        return .timedOut
    }
}

@MainActor
public final class InsertionPasteAgainFlow {
    private let handoff: InsertionTargetHandoff

    public init(handoff: InsertionTargetHandoff) {
        self.handoff = handoff
    }

    public func run(
        capture: @escaping @MainActor () -> InsertionTargetSnapshot,
        paste: @escaping @MainActor (InsertionTargetSnapshot) -> InsertionResult,
        copyOnly: @escaping @MainActor (InsertionTargetHandoffResult) -> InsertionResult,
        recordOutcome: @escaping @MainActor (InsertionResult) -> Void,
        discard: @escaping @MainActor (InsertionTargetSnapshot) -> Void = { _ in },
        restoreFocus: @escaping @MainActor () -> Void = {}
    ) async -> InsertionResult {
        let selection = await handoff.select(capture: capture, discard: discard)
        let result: InsertionResult
        if Task.isCancelled {
            if case .ready(let target) = selection {
                discard(target)
            }
            result = copyOnly(selection)
        } else {
            switch selection {
            case .ready(let target):
                result = paste(target)
            case .timedOut, .cancelled:
                result = copyOnly(selection)
            }
        }
        recordOutcome(result)
        restoreFocus()
        return result
    }
}
