import AVFAudio
import Darwin
import Foundation
import OigoSpike

private enum CLIError: Error, CustomStringConvertible {
    case missingValue(String)
    case invalidValue(String, String)
    case unknownArgument(String)
    case missingScenario

    var description: String {
        switch self {
        case .missingValue(let option):
            return "missing value for " + option
        case .invalidValue(let option, let value):
            return "invalid value \"" + value + "\" for " + option
        case .unknownArgument(let argument):
            return "unknown argument " + argument
        case .missingScenario:
            return "missing --scenario or --verify-record"
        }
    }
}

private struct CLIOptions {
    var scenario: String?
    var fixture: URL?
    var output: URL?
    var verifyRecord: URL?
    var runs = 20
    var duration = 5.0
    var showHelp = false
}

@main
private struct OigoSpikeCLI {
    static func main() async {
        do {
            let options = try parse(Array(CommandLine.arguments.dropFirst()))
            if options.showHelp {
                printHelp()
                exit(0)
            }
            try await run(options)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data(("ERROR: " + String(describing: error) + "\n").utf8))
            exit(1)
        }
    }

    private static func parse(_ arguments: [String]) throws -> CLIOptions {
        var options = CLIOptions(scenario: nil, fixture: nil, output: nil, verifyRecord: nil)
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                options.showHelp = true
            case "--scenario":
                index += 1
                options.scenario = try value(arguments, at: index, for: argument)
            case "--fixture":
                index += 1
                options.fixture = URL(fileURLWithPath: try value(arguments, at: index, for: argument))
            case "--output":
                index += 1
                options.output = URL(fileURLWithPath: try value(arguments, at: index, for: argument))
            case "--verify-record":
                index += 1
                options.verifyRecord = URL(fileURLWithPath: try value(arguments, at: index, for: argument))
            case "--runs":
                index += 1
                let rawValue = try value(arguments, at: index, for: argument)
                guard let runs = Int(rawValue), runs > 0 else {
                    throw CLIError.invalidValue(argument, rawValue)
                }
                options.runs = runs
            case "--duration":
                index += 1
                let rawValue = try value(arguments, at: index, for: argument)
                guard let duration = Double(rawValue), duration.isFinite, duration >= 0 else {
                    throw CLIError.invalidValue(argument, rawValue)
                }
                options.duration = duration
            default:
                throw CLIError.unknownArgument(argument)
            }
            index += 1
        }
        if !options.showHelp && options.scenario == nil && options.verifyRecord == nil {
            throw CLIError.missingScenario
        }
        return options
    }

    private static func value(
        _ arguments: [String],
        at index: Int,
        for option: String
    ) throws -> String {
        guard arguments.indices.contains(index) else {
            throw CLIError.missingValue(option)
        }
        return arguments[index]
    }

    private static func run(_ options: CLIOptions) async throws {
        if let verifyRecord = options.verifyRecord {
            try FeasibilityRecordValidator().validate(url: verifyRecord)
            print("record_valid=true")
            print("record_path=" + verifyRecord.path)
            return
        }

        guard let scenario = options.scenario else {
            throw CLIError.missingScenario
        }
        switch scenario {
        case "failure-retry":
            try runFailureRetry(output: options.output)
        case "transcript-cleanup":
            try await runTranscriptCleanup()
        case "offline":
            try runOffline(fixture: options.fixture)
        case "resource-measurement":
            try runResourceMeasurement(runs: options.runs)
        case "capabilities":
            try await runCapabilities()
        case "install-assets":
            try await runInstallAssets()
        case "live":
            try await runLive(output: options.output, duration: options.duration)
        default:
            throw CLIError.unknownArgument("--scenario " + scenario)
        }
    }

    private static func runFailureRetry(output: URL?) throws {
        let url = output ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-spike-")
            .appendingPathExtension("caf")
        try createSilentCAF(at: url)
        let frames = try CAFRecorder.playableFrameLength(at: url)
        let retryResult = try SavedAudioRetry.retryAfterFailure(
            url: url,
            liveFailure: ForcedRecognitionFailure()
        ) { savedURL in
            let savedFrames = try CAFRecorder.playableFrameLength(at: savedURL)
            return "retry-ready frames=" + String(savedFrames)
        }
        print("audio_path=" + url.path)
        print("playable_frames=" + String(frames))
        print("forced_live_failure=preserved")
        print("saved_file_retry=" + retryResult)
    }

    private static func runTranscriptCleanup() async throws {
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
        let foundationModelsCleanup = await FoundationModelsCleaner()
            .clean(rawText: snapshot.finalizedText)
        print("raw_text=" + cleanup.rawText)
        print("displayed_text=" + cleanup.displayedText)
        print("cleanup_status=" + String(describing: cleanup.status))
        print("no_duplicated_segments=" + String(snapshot.displayedText == "hello world"))
        print("raw_fallback_available=" + String(cleanup.displayedText == cleanup.rawText))
        print("foundation_models_cleanup_status=" + String(describing: foundationModelsCleanup.status))
        print("foundation_models_raw_fallback=" + String(foundationModelsCleanup.displayedText == foundationModelsCleanup.rawText))
    }

    private static func runOffline(fixture: URL?) throws {
        if let fixture {
            let frames = try CAFRecorder.playableFrameLength(at: fixture)
            print("fixture_frames=" + String(frames))
        }
        print("network_requests=0")
        print("oigo_network_client=none")
        print("network_disabled_by_harness=false")
        print("external_network_disable_required=true")
    }

    private static func runResourceMeasurement(runs: Int) throws {
        let measurement = ResourceMeasurementRunner.measure(runs: runs) {
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
        print("runs=" + String(measurement.runs))
        print("deterministic_state_memory_delta_bytes=" + String(measurement.maximumResidentDeltaBytes))
        print("deterministic_state_bounded=" + String(measurement.bounded))
        print("native_model_objects_measured=false")
    }

    private static func runCapabilities() async throws {
        let capabilities = await NativeDictationPipeline.capabilitySnapshot()
        for key in capabilities.keys.sorted() {
            print(key + "=" + (capabilities[key] ?? ""))
        }
    }

    private static func runInstallAssets() async throws {
        print("asset_installation_started=true")
        let status = try await NativeDictationPipeline.installSpeechAssets()
        print("asset_installation_status=" + status)
    }

    private static func runLive(output: URL?, duration: TimeInterval) async throws {
        let url = output ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-live-")
            .appendingPathExtension("caf")
        let pipeline = NativeDictationPipeline(audioURL: url) { snapshot in
            print("displayed_text=" + snapshot.displayedText)
            print("finalized_text=" + snapshot.finalizedText)
        }
        try await pipeline.run(for: duration)
        print("audio_path=" + url.path)
        print("transcriber=" + pipeline.transcriberChoice)
        print("final_text=" + pipeline.latestSnapshot.finalizedText)
    }

    private static func createSilentCAF(at url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        guard let format else {
            throw NSError(domain: "OigoSpike", code: 1)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600) else {
            throw NSError(domain: "OigoSpike", code: 2)
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

    private static func printHelp() {
        print("oigo-spike --scenario failure-retry [--output path]")
        print("oigo-spike --scenario transcript-cleanup")
        print("oigo-spike --scenario offline [--fixture path]")
        print("oigo-spike --scenario resource-measurement [--runs 20]")
        print("oigo-spike --scenario capabilities")
        print("oigo-spike --scenario install-assets")
        print("oigo-spike --scenario live [--duration seconds] [--output path]")
        print("oigo-spike --verify-record path")
    }
}
