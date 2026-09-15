import Darwin
import Foundation

struct GalleryInputBoundaryProbe {
    let exitCode: Int32
    let output: String
    let timedOut: Bool

    static func run(executable: URL, options: [String], home: URL) throws -> GalleryInputBoundaryProbe {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = options
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = ProcessInfo.processInfo.environment.merging([
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path
        ], uniquingKeysWith: { _, replacement in replacement })
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw ContractInputError(category: "gallery-process-launch")
        }
        let completed = finished.wait(timeout: .now() + 2) == .success
        if !completed {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
            + stderr.fileHandleForReading.readDataToEndOfFile()
        return GalleryInputBoundaryProbe(
            exitCode: process.terminationStatus,
            output: String(decoding: output, as: UTF8.self),
            timedOut: !completed
        )
    }
}
