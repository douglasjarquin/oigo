import AVFAudio
import Darwin
import Foundation
import OigoSpike

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
private struct OigoSpikeContractTests {
    static func main() async {
        let cases: [(String, () async throws -> Void)] = [
            ("durable capture and retry", { try testDurableCaptureAndRetry() }),
            ("volatile final replacement and raw cleanup fallback", { try testTranscriptAndCleanup() }),
            ("cleanup unavailable and raw fallback", testCleanupFallback),
            ("state memory bound across twenty runs", { try testResourceMeasurement() }),
            ("feasibility record validator", { try testFeasibilityRecord() })
        ]
        var failures = 0
        for (name, test) in cases {
            do {
                try await test()
                print("GREEN: " + name)
            } catch {
                failures += 1
                print("FAIL: " + name + ": " + String(describing: error))
            }
        }
        if failures == 0 {
            print("GREEN: all contract scenarios")
            exit(0)
        }
        print("FAILURES=" + String(failures))
        exit(1)
    }

    private static func testDurableCaptureAndRetry() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("capture.caf")
        try createSilentCAF(at: url)
        let frames = try CAFRecorder.playableFrameLength(at: url)
        let retriedFrames = try SavedAudioRetry.retryAfterFailure(
            url: url,
            liveFailure: ForcedRecognitionFailure()
        ) { savedURL in
            try CAFRecorder.playableFrameLength(at: savedURL)
        }
        guard frames > 0, retriedFrames == frames else {
            throw ContractFailure(message: "saved CAF was not playable after forced recognition failure")
        }
    }

    private static func testTranscriptAndCleanup() throws {
        var accumulator = TranscriptAccumulator()
        _ = accumulator.ingest(
            range: TranscriptRange(startMilliseconds: 0, endMilliseconds: 1_000),
            text: "hello wor",
            isFinal: false
        )
        let snapshot = accumulator.ingest(
            range: TranscriptRange(startMilliseconds: 0, endMilliseconds: 1_000),
            text: "hello world",
            isFinal: true
        )
        let cleanup = CleanupFallback.failed(
            rawText: snapshot.finalizedText,
            error: ForcedRecognitionFailure()
        )
        guard snapshot.displayedText == "hello world" else {
            throw ContractFailure(message: "volatile text was not replaced by one finalized segment")
        }
        guard cleanup.displayedText == cleanup.rawText else {
            throw ContractFailure(message: "raw transcript was not retained on cleanup failure")
        }
    }

    private static func testCleanupFallback() async throws {
        let actual = await FoundationModelsCleaner().clean(rawText: "raw transcript")
        guard actual.rawText == "raw transcript" else {
            throw ContractFailure(message: "Foundation Models cleaner did not retain raw transcript")
        }
        if actual.cleanedText == nil, actual.displayedText != actual.rawText {
            throw ContractFailure(message: "Foundation Models unavailable path did not retain raw transcript")
        }
        let failed = await CleanupFallback.run(
            rawText: "raw transcript",
            timeoutNanoseconds: 1_000_000
        ) {
            throw ForcedRecognitionFailure()
        }
        guard failed.cleanedText == nil, failed.displayedText == failed.rawText else {
            throw ContractFailure(message: "cleanup failure did not retain raw transcript")
        }
        guard case .failed = failed.status else {
            throw ContractFailure(message: "cleanup failure did not report failed status")
        }

        let timedOut = await CleanupFallback.run(
            rawText: "raw transcript",
            timeoutNanoseconds: 1_000_000
        ) {
            try await Task.sleep(nanoseconds: 100_000_000)
            return "cleaned transcript"
        }
        guard timedOut.cleanedText == nil, timedOut.displayedText == timedOut.rawText else {
            throw ContractFailure(message: "cleanup timeout fallback did not retain raw transcript")
        }
        guard timedOut.status == .timedOut else {
            throw ContractFailure(message: "cleanup timeout fallback did not report timedOut status")
        }
    }

    private static func testResourceMeasurement() throws {
        let measurement = ResourceMeasurementRunner.measure(runs: 20) {
            var accumulator = TranscriptAccumulator()
            for index in 0..<50 {
                let start = Int64(index * 100)
                _ = accumulator.ingest(
                    range: TranscriptRange(startMilliseconds: start, endMilliseconds: start + 100),
                    text: "sample",
                    isFinal: index.isMultiple(of: 2)
                )
            }
        }
        guard measurement.runs == 20, measurement.bounded else {
            throw ContractFailure(message: "twenty-run resource harness exceeded its bound")
        }
    }

    private static func testFeasibilityRecord() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("record.md")
        let contents = FeasibilityRecordValidator.requiredSections.joined(separator: "\n")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FeasibilityRecordValidator().validate(url: url)
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-contract-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func createSilentCAF(at url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            throw ContractFailure(message: "could not create 16 kHz mono format")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600) else {
            throw ContractFailure(message: "could not create silent audio buffer")
        }
        buffer.frameLength = 1_600
        if let samples = buffer.floatChannelData?.pointee {
            for index in 0..<Int(buffer.frameLength) {
                samples[index] = 0
            }
        }
        let recorder = try CAFRecorder(url: url, format: format)
        try recorder.append(buffer)
        try recorder.finish()
    }
}
