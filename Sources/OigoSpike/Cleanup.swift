import Foundation
import FoundationModels

private final class CleanupResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CleanupRecord, Never>?
    private var resolvedRecord: CleanupRecord?
    private var resolved = false

    func install(_ continuation: CheckedContinuation<CleanupRecord, Never>) {
        lock.lock()
        if let resolvedRecord {
            lock.unlock()
            continuation.resume(returning: resolvedRecord)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ record: CleanupRecord) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        resolvedRecord = record
        let continuation = self.continuation
        lock.unlock()
        continuation?.resume(returning: record)
    }
}

public enum CleanupStatus: Equatable, Sendable {
    case cleaned
    case unavailable(String)
    case timedOut
    case failed(String)
}

public struct CleanupRecord: Equatable, Sendable {
    public let rawText: String
    public let cleanedText: String?
    public let status: CleanupStatus

    public init(rawText: String, cleanedText: String?, status: CleanupStatus) {
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.status = status
    }

    public var displayedText: String {
        cleanedText ?? rawText
    }
}

public enum CleanupFallback {
    public static func unavailable(rawText: String, reason: String) -> CleanupRecord {
        CleanupRecord(rawText: rawText, cleanedText: nil, status: .unavailable(reason))
    }

    public static func timedOut(rawText: String) -> CleanupRecord {
        CleanupRecord(rawText: rawText, cleanedText: nil, status: .timedOut)
    }

    public static func failed(rawText: String, error: Error) -> CleanupRecord {
        CleanupRecord(rawText: rawText, cleanedText: nil, status: .failed(String(describing: error)))
    }

    public static func run(
        rawText: String,
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> String
    ) async -> CleanupRecord {
        let resolution = CleanupResolution()
        let responseTask = Task {
            do {
                let cleanedText = try await operation()
                resolution.resolve(
                    CleanupRecord(
                        rawText: rawText,
                        cleanedText: cleanedText,
                        status: .cleaned
                    )
                )
            } catch {
                resolution.resolve(CleanupFallback.failed(rawText: rawText, error: error))
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                resolution.resolve(CleanupFallback.timedOut(rawText: rawText))
            } catch {
            }
        }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<CleanupRecord, Never>) in
            resolution.install(continuation)
        }
        responseTask.cancel()
        timeoutTask.cancel()
        return result
    }
}

@available(macOS 26.0, *)
public final class FoundationModelsCleaner: @unchecked Sendable {
    private let signposts: PipelineSignposts?

    public init(signposts: PipelineSignposts? = nil) {
        self.signposts = signposts
    }

    public func clean(
        rawText: String,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async -> CleanupRecord {
        defer { signposts?.mark(.cleanup) }
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            return CleanupFallback.unavailable(
                rawText: rawText,
                reason: String(describing: model.availability)
            )
        }

        let instructions = "Rewrite the transcript as a strict meaning-preserving cleanup. Do not add, remove, infer, or normalize technical terms. Return only the cleaned transcript."
        let session = LanguageModelSession(model: model, instructions: instructions)
        return await CleanupFallback.run(
            rawText: rawText,
            timeoutNanoseconds: timeoutNanoseconds
        ) {
            let response = try await session.respond(to: rawText)
            return response.content
        }
    }

}
