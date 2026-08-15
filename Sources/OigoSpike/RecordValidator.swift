import Foundation

public enum FeasibilityRecordError: Error, Equatable, CustomStringConvertible {
    case missingFile(URL)
    case missingSections([String])

    public var description: String {
        switch self {
        case .missingFile(let url):
            return "feasibility record is missing at \(url.path)"
        case .missingSections(let sections):
            return "feasibility record is missing sections: \(sections.joined(separator: ", "))"
        }
    }
}

public struct FeasibilityRecordValidator: Sendable {
    public static let requiredSections = [
        "## Tested environment",
        "## APIs evaluated and selected",
        "## Permission and asset-installation behavior",
        "## Accuracy observations",
        "## Latency and resource measurements",
        "## Failure and retry results",
        "## Offline result",
        "## Recommendation"
    ]

    public init() {}

    public func validate(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FeasibilityRecordError.missingFile(url)
        }
        let contents = try String(contentsOf: url, encoding: .utf8)
        let missing = Self.requiredSections.filter { !contents.contains($0) }
        guard missing.isEmpty else {
            throw FeasibilityRecordError.missingSections(missing)
        }
    }
}
