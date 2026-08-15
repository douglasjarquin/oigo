import Darwin
import Foundation
import os

public enum SignpostEvent: String, Sendable {
    case recordingStart = "recording-start"
    case firstAudioBuffer = "first-audio-buffer"
    case firstVolatileResult = "first-volatile-result"
    case finalResult = "final-result"
    case cleanup = "cleanup"
    case resourceRelease = "resource-release"
}

public final class PipelineSignposts: @unchecked Sendable {
    private let log = OSLog(subsystem: "com.oigo.spike", category: "dictation")

    public init() {}

    public func mark(_ event: SignpostEvent) {
        switch event {
        case .recordingStart:
            os_signpost(.event, log: log, name: "recording-start")
        case .firstAudioBuffer:
            os_signpost(.event, log: log, name: "first-audio-buffer")
        case .firstVolatileResult:
            os_signpost(.event, log: log, name: "first-volatile-result")
        case .finalResult:
            os_signpost(.event, log: log, name: "final-result")
        case .cleanup:
            os_signpost(.event, log: log, name: "cleanup")
        case .resourceRelease:
            os_signpost(.event, log: log, name: "resource-release")
        }
    }
}

public struct ResourceMeasurement: Equatable, Sendable {
    public let runs: Int
    public let initialMaximumResidentBytes: UInt64
    public let finalMaximumResidentBytes: UInt64
    public let maximumResidentDeltaBytes: UInt64
    public let bounded: Bool

    public init(
        runs: Int,
        initialMaximumResidentBytes: UInt64,
        finalMaximumResidentBytes: UInt64,
        maximumResidentDeltaBytes: UInt64,
        bounded: Bool
    ) {
        self.runs = runs
        self.initialMaximumResidentBytes = initialMaximumResidentBytes
        self.finalMaximumResidentBytes = finalMaximumResidentBytes
        self.maximumResidentDeltaBytes = maximumResidentDeltaBytes
        self.bounded = bounded
    }
}

public enum ResourceMeasurementRunner {
    public static func measure(
        runs: Int,
        operation: () -> Void
    ) -> ResourceMeasurement {
        let safeRuns = max(1, runs)
        let initial = maximumResidentBytes()
        for _ in 0..<safeRuns {
            operation()
        }
        let final = maximumResidentBytes()
        let delta = final >= initial ? final - initial : 0
        return ResourceMeasurement(
            runs: safeRuns,
            initialMaximumResidentBytes: initial,
            finalMaximumResidentBytes: final,
            maximumResidentDeltaBytes: delta,
            bounded: delta < 32 * 1024 * 1024
        )
    }

    private static func maximumResidentBytes() -> UInt64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return UInt64(max(0, usage.ru_maxrss))
    }
}
