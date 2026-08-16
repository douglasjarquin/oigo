import Foundation

public enum PerformanceMeasurement: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case idleCPUPercent = "idle_cpu_percent"
    case idlePhysicalFootprintBytes = "idle_physical_footprint_bytes"
    case shortcutToRecordingP95Milliseconds = "shortcut_to_recording_p95_ms"
    case firstVolatileTranscriptP95Milliseconds = "first_volatile_transcript_p95_ms"
    case stopToRawFinalTranscriptP95Milliseconds = "stop_to_raw_final_transcript_p95_ms"
    case stopToCleanInsertionP95Milliseconds = "stop_to_clean_insertion_p95_ms"
    case memoryAfterProcessingDeltaBytes = "memory_after_processing_delta_bytes"
    case memoryDriftAfter100DictationsBytes = "memory_drift_after_100_dictations_bytes"
    case oigoInitiatedNetworkRequests = "oigo_initiated_network_requests"
    case lostRecoverableRecordings = "lost_recoverable_recordings"
    case appleModelServiceCPUPercent = "apple_model_service_cpu_percent"
    case appleModelServicePhysicalFootprintBytes = "apple_model_service_physical_footprint_bytes"
    case wholeSystemMemoryPressure = "whole_system_memory_pressure"
}

public enum PerformanceBudgetComparison: String, Codable, Equatable, Sendable {
    case lessThanOrEqual = "less_than_or_equal"
    case equal = "equal"

    fileprivate func accepts(_ value: Double, hardLimit: Double) -> Bool {
        switch self {
        case .lessThanOrEqual:
            return value <= hardLimit
        case .equal:
            return value == hardLimit
        }
    }
}

public struct PerformanceBudget: Codable, Equatable, Sendable {
    public let measurement: PerformanceMeasurement
    public let target: Double
    public let hardLimit: Double
    public let comparison: PerformanceBudgetComparison

    public init(
        measurement: PerformanceMeasurement,
        target: Double,
        hardLimit: Double,
        comparison: PerformanceBudgetComparison = .lessThanOrEqual
    ) {
        self.measurement = measurement
        self.target = target
        self.hardLimit = hardLimit
        self.comparison = comparison
    }
}

public enum PerformanceBudgetCatalog {
    public static let idleCPUHardLimit = 0.5
    public static let idlePhysicalFootprintHardLimitBytes: UInt64 = 90 * 1024 * 1024

    public static let hardGates: [PerformanceBudget] = [
        PerformanceBudget(
            measurement: .idleCPUPercent,
            target: 0.2,
            hardLimit: idleCPUHardLimit
        ),
        PerformanceBudget(
            measurement: .idlePhysicalFootprintBytes,
            target: 65 * 1024 * 1024,
            hardLimit: Double(idlePhysicalFootprintHardLimitBytes)
        ),
        PerformanceBudget(
            measurement: .shortcutToRecordingP95Milliseconds,
            target: 100,
            hardLimit: 150
        ),
        PerformanceBudget(
            measurement: .firstVolatileTranscriptP95Milliseconds,
            target: 700,
            hardLimit: 1_200
        ),
        PerformanceBudget(
            measurement: .stopToRawFinalTranscriptP95Milliseconds,
            target: 750,
            hardLimit: 1_500
        ),
        PerformanceBudget(
            measurement: .stopToCleanInsertionP95Milliseconds,
            target: 2_500,
            hardLimit: 4_000
        ),
        PerformanceBudget(
            measurement: .memoryAfterProcessingDeltaBytes,
            target: 10 * 1024 * 1024,
            hardLimit: 15 * 1024 * 1024
        ),
        PerformanceBudget(
            measurement: .memoryDriftAfter100DictationsBytes,
            target: 10 * 1024 * 1024,
            hardLimit: 20 * 1024 * 1024
        ),
        PerformanceBudget(
            measurement: .oigoInitiatedNetworkRequests,
            target: 0,
            hardLimit: 0,
            comparison: .equal
        ),
        PerformanceBudget(
            measurement: .lostRecoverableRecordings,
            target: 0,
            hardLimit: 0,
            comparison: .equal
        )
    ]

    public static let requiredEvidence: [PerformanceMeasurement] = [
        .appleModelServiceCPUPercent,
        .appleModelServicePhysicalFootprintBytes,
        .wholeSystemMemoryPressure
    ]

    public static let allMeasurements: [PerformanceMeasurement] =
        hardGates.map(\.measurement) + requiredEvidence
}

public enum PerformanceMeasurementStatus: String, Codable, Equatable, Sendable {
    case available
    case inconclusive
}

public struct PerformanceMeasurementRecord: Codable, Equatable, Sendable {
    public let measurement: PerformanceMeasurement
    public let value: Double?
    public let status: PerformanceMeasurementStatus
    public let note: String?

    public init(
        measurement: PerformanceMeasurement,
        value: Double?,
        status: PerformanceMeasurementStatus = .available,
        note: String? = nil
    ) {
        self.measurement = measurement
        self.value = value
        self.status = status
        self.note = note
    }
}

public enum PerformanceReleaseStatus: String, Codable, Equatable, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case inconclusive = "INCONCLUSIVE"
}

public struct PerformanceGateResult: Codable, Equatable, Sendable {
    public let measurement: PerformanceMeasurement
    public let status: PerformanceReleaseStatus
    public let value: Double?
    public let note: String?

    public init(
        measurement: PerformanceMeasurement,
        status: PerformanceReleaseStatus,
        value: Double?,
        note: String?
    ) {
        self.measurement = measurement
        self.status = status
        self.value = value
        self.note = note
    }
}

public struct PerformanceReleaseReport: Codable, Equatable, Sendable {
    public let status: PerformanceReleaseStatus
    public let results: [PerformanceGateResult]

    public init(status: PerformanceReleaseStatus, results: [PerformanceGateResult]) {
        self.status = status
        self.results = results
    }
}

public enum PerformanceReleaseCheck {
    public static func evaluate(
        _ records: [PerformanceMeasurementRecord]
    ) -> PerformanceReleaseReport {
        let byMeasurement = Dictionary(grouping: records, by: \.measurement)
        let budgets = Dictionary(
            PerformanceBudgetCatalog.hardGates.map { ($0.measurement, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var results: [PerformanceGateResult] = []

        for measurement in PerformanceBudgetCatalog.allMeasurements {
            guard let matchingRecords = byMeasurement[measurement] else {
                results.append(
                    PerformanceGateResult(
                        measurement: measurement,
                        status: .inconclusive,
                        value: nil,
                        note: "measurement was not supplied"
                    )
                )
                continue
            }
            guard matchingRecords.count == 1, let record = matchingRecords.first else {
                results.append(
                    PerformanceGateResult(
                        measurement: measurement,
                        status: .fail,
                        value: nil,
                        note: "duplicate measurement records are invalid"
                    )
                )
                continue
            }
            guard record.status == .available else {
                results.append(
                    PerformanceGateResult(
                        measurement: measurement,
                        status: .inconclusive,
                        value: record.value,
                        note: record.note ?? "host measurement is unavailable"
                    )
                )
                continue
            }
            guard let value = record.value else {
                results.append(
                    PerformanceGateResult(
                        measurement: measurement,
                        status: .fail,
                        value: nil,
                        note: "available measurement must include a value"
                    )
                )
                continue
            }
            guard Self.isValid(measurement: measurement, value: value) else {
                results.append(
                    PerformanceGateResult(
                        measurement: measurement,
                        status: .fail,
                        value: value,
                        note: "measurement value must be finite, nonnegative, and integral for count gates"
                    )
                )
                continue
            }
            if let budget = budgets[measurement] {
                let status: PerformanceReleaseStatus = budget.comparison.accepts(
                    value,
                    hardLimit: budget.hardLimit
                ) ? .pass : .fail
                results.append(
                    PerformanceGateResult(
                        measurement: measurement,
                        status: status,
                        value: value,
                        note: record.note
                    )
                )
            } else {
                results.append(
                    PerformanceGateResult(
                        measurement: measurement,
                        status: .pass,
                        value: value,
                        note: record.note
                    )
                )
            }
        }

        let status: PerformanceReleaseStatus
        if results.contains(where: { $0.status == .fail }) {
            status = .fail
        } else if results.contains(where: { $0.status == .inconclusive }) {
            status = .inconclusive
        } else {
            status = .pass
        }
        return PerformanceReleaseReport(status: status, results: results)
    }

    private static func isValid(measurement: PerformanceMeasurement, value: Double) -> Bool {
        guard value.isFinite, value >= 0 else {
            return false
        }
        switch measurement {
        case .oigoInitiatedNetworkRequests, .lostRecoverableRecordings:
            return value.rounded() == value
        default:
            return true
        }
    }

    public static func load(from url: URL) throws -> PerformanceReleaseReport {
        let data = try Data(contentsOf: url)
        let input = try JSONDecoder().decode(Input.self, from: data)
        return evaluate(input.measurements)
    }

    private struct Input: Codable {
        let measurements: [PerformanceMeasurementRecord]
    }
}
