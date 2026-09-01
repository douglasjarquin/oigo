import Foundation

struct Task16KeyboardReleaseRow: Codable {
    let caseName: String
    let checkpoints: [String]
    let terminalState: String
    let durableState: String?
    let durableRawBytes: Int64
    let terminalizationCount: Int
    let captureStopCount: Int
    let captureCancelCount: Int
    let transcriptionFinishCount: Int
    let transcriptionCancelCount: Int
    let insertionCount: Int
    let appResourceCount: Int
    let coordinatorResourceCount: Int
    let hudResourceCount: Int
    let timerResourceCount: Int
}

struct Task16KeyboardReleaseReceipt: Codable {
    let ownerIdentity: String
    let rows: [Task16KeyboardReleaseRow]
    let defaultsCleaned: Bool
}
