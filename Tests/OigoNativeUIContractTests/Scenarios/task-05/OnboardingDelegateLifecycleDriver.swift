import Foundation

enum OnboardingDelegateLifecycleDriver {
    static func run(evidenceRoot: URL) throws {
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let root = evidenceRoot.appendingPathComponent("onboarding-lifecycle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let delegate = root.appendingPathComponent("OigoAppDelegate.swift")
        let controller = root.appendingPathComponent("OnboardingWindowController.swift")
        let main = root.appendingPathComponent("main.swift")
        let executable = root.appendingPathComponent("lifecycle-contract")
        var delegateSource = try String(contentsOf: repository.appendingPathComponent("Sources/Oigo/OigoAppDelegate.swift"), encoding: .utf8)
        let inspectionStart = delegateSource.range(of: "private func preflightSpeechAssetsIfNeeded()")!.lowerBound
        let inspectionEnd = delegateSource.range(of: "private static func localeAssetStatus", range: inspectionStart..<delegateSource.endIndex)!.lowerBound
        let serviceAcquisition = "let service = transcriptionService(for: identifier)"
        let inspectionSource = String(delegateSource[inspectionStart..<inspectionEnd])
        guard inspectionSource.components(separatedBy: serviceAcquisition).count - 1 == 2 else {
            throw ContractInputError(category: "asset-service-substitution-count")
        }
        let inspection = inspectionSource.replacingOccurrences(
            of: serviceAcquisition,
            with: "let service = LifecycleSpeech(identifier: identifier)"
        )
        delegateSource.replaceSubrange(inspectionStart..<inspectionEnd, with: inspection)
        try (delegateSource + delegateProbe).write(to: delegate, atomically: true, encoding: .utf8)
        try (String(contentsOf: repository.appendingPathComponent("Sources/Oigo/OnboardingWindowController.swift"), encoding: .utf8) + controllerProbe).write(to: controller, atomically: true, encoding: .utf8)
        try entryPoint.write(to: main, atomically: true, encoding: .utf8)
        let build = repository.appendingPathComponent(".build/arm64-apple-macosx/debug")
        let modules = ["OigoCore", "OigoCapture", "OigoTranscription", "OigoInsertion", "OigoHotKey", "OigoPresentation", "OigoIdentity", "MacUtilityUI"]
        let excluded = Set(["main.swift", "OigoAppDelegate.swift", "OnboardingWindowController.swift"])
        let sources = try String(contentsOf: build.appendingPathComponent("Oigo.build/sources"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
            .filter { !excluded.contains(URL(fileURLWithPath: $0).lastPathComponent) }
        let objects = try modules.flatMap { module in
            try FileManager.default.contentsOfDirectory(at: build.appendingPathComponent(module + ".build"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "o" }
                .map(\.path)
        }
        try runProcess("/usr/bin/xcrun", ["swiftc", "-swift-version", "6", "-I", build.appendingPathComponent("Modules").path, delegate.path, controller.path, main.path, "-o", executable.path] + sources + objects)
        try runProcess(executable.path, [root.path])
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ContractInputError(category: "onboarding-lifecycle-exit-\(process.terminationStatus)")
        }
    }

    private static let controllerProbe = #"""

    extension OnboardingWindowController {
        func lifecycleBeginTest() -> UInt64 {
            setStorageHealth(.ready(.init(recoveredSessionCount: 0, historyEntryCount: 0, malformedSessionCount: 0)))
            let generation = evidence.beginTest(destinationEditable: true)!
            activeTestGeneration = generation
            _ = evidence.markDestinationCleared(generation: generation)
            render()
            return generation
        }
        var lifecycleActionTitle: String { actionButton.title }
        func lifecycleFinish() { currentStep = .complete; goForward() }
    }
    """#

    private static let delegateProbe = #"""

    final class LifecycleCapture: AudioCapturing {
        var active = false
        private var descriptor: AudioFileDescriptor?
        func start(to descriptor: AudioFileDescriptor, onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void, onFinish: @escaping @Sendable () -> Void, onInterruption: @escaping @Sendable (String) -> Void, onFailure: @escaping @Sendable (String) -> Void) throws {
            self.descriptor = descriptor
            active = true
        }
        func stop() throws { cancel() }
        func cancel() { active = false; descriptor?.close(); descriptor = nil }
    }

    @MainActor
    enum LifecycleSpeechDelay {
        static var enabled = false
        static var pending: CheckedContinuation<Void, Never>?
    }

    @MainActor
    struct LifecycleSpeech {
        let identifier: String
        var currentAssetState: SpeechAssetState { .ready("en-US") }
        func installSpeechAssets() async throws -> SpeechAssetState {
            if LifecycleSpeechDelay.enabled {
                await withCheckedContinuation { LifecycleSpeechDelay.pending = $0 }
            }
            return .ready(identifier)
        }
        func checkSpeechAssets() async throws -> SpeechAssetState { try await installSpeechAssets() }
    }

    @MainActor
    final class LifecycleRegistrar: GlobalShortcutRegistrationClient {
        var status: GlobalShortcutRegistrationStatus = .inactive("Contract")
        var lastError: String? { nil }
        func register(shortcut: ToggleShortcut, onEvent: @escaping @MainActor (GlobalShortcutEvent) -> Void) throws { status = .active(shortcut, generation: 1) }
        func probe(shortcut: ToggleShortcut) throws {}
        func unregister() throws { status = .inactive("Contract") }
    }

    extension OigoAppDelegate {
        static func lifecycleContract(root: URL) async throws {
            let suite = "com.oigo.qa.lifecycle." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let onboarding = OigoOnboardingStore(defaults: defaults)
            onboarding.save(.init(step: .testDictation, copyOnlyAccepted: false))
            let owner = OigoAppDelegate(storageBootstrapper: DurableSessionBootstrapper(rootDirectory: root.appendingPathComponent(UUID().uuidString)), settingsStore: OigoSettingsStore(defaults: defaults), onboardingStore: onboarding, shortcutRegistrar: LifecycleRegistrar(), settingsPermissionStates: { (.granted, .granted) })
            owner.storageCapability.onChange = nil
            owner.storageCapability.start()
            for _ in 0..<200 where !owner.storageCapability.health.isReady {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard owner.storageCapability.health.isReady else { throw NSError(domain: "fixture-storage", code: 1) }
            owner.showOnboarding(.init(isSupported: true, reason: "Contract"))
            let original = owner.onboardingWindow!
            let generation = original.lifecycleBeginTest()
            owner.beginOnboardingProductionTest(generation: generation)
            let capture = LifecycleCapture()
            let store = try SessionStore(rootDirectory: root.appendingPathComponent(UUID().uuidString))
            let session = try owner.coordinator.startRecording(using: capture, store: store)
            owner.bindOnboardingTestSession(session.id)
            let before = original.lifecycleActionTitle
            _ = owner.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
            let reopenPreserved = owner.onboardingWindow === original
            for _ in 0..<3 { owner.handleMouseToggle() }
            owner.showOnboarding(.init(isSupported: true, reason: "Repeated presentation"))
            let menuPreserved = owner.onboardingWindow === original
            let after = owner.onboardingWindow!.lifecycleActionTitle
            let recording = owner.coordinator.state == .recording && capture.active
            let bound = owner.onboardingTestGeneration == generation && owner.onboardingTestSessionID == session.id
            print("LIFECYCLE pid=\(getpid()) reopenSame=\(reopenPreserved) menuSame=\(menuPreserved) before=\(before) after=\(after) recording=\(recording) bindingSame=\(bound)")
            await owner.coordinator.cancelActiveWork(reason: "contract cleanup")
            owner.onboardingWindow?.window?.orderOut(nil)
            original.window?.orderOut(nil)
            guard reopenPreserved && menuPreserved && recording && bound && before == after else {
                throw NSError(domain: "onboarding-controller-recreated-during-recording", code: 1)
            }
            owner.clearOnboardingTestBinding()
            owner.settings = owner.settings.with(localeIdentifier: "en_US")
            original.lifecycleFinish()
            let waiting = owner.shortcutRegistration.registrationStatus.message
            for _ in 0..<200 where owner.speechAssetCheckTask != nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            let finishReady = owner.isSetupReady && owner.shortcutRegistration.isOperationReady
            print("FINISH completed=\(onboarding.load().isComplete) readyWithoutRestart=\(finishReady)")
            owner.speechAssetReadiness = .checking
            owner.synchronizeShortcutRegistration()
            let ready = await owner.inspectSpeechAssets(for: "en-US")
            let registered = owner.shortcutRegistration.isOperationReady
            print("READINESS completed=\(onboarding.load().isComplete) before=\(waiting) assetsReady=\(ready.isReady) registered=\(registered)")
            guard finishReady && onboarding.load().isComplete && ready.isReady && registered else {
                throw NSError(domain: "registration-still-waiting-after-assets-ready", code: 1)
            }
            owner.settings = owner.settings.with(localeIdentifier: "en-US")
            LifecycleSpeechDelay.enabled = true
            let oldInspection = Task { @MainActor in await owner.inspectSpeechAssets(for: "en-US") }
            for _ in 0..<200 where LifecycleSpeechDelay.pending == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let pending = LifecycleSpeechDelay.pending else { throw NSError(domain: "asset-delay-not-entered", code: 1) }
            owner.settings = owner.settings.with(localeIdentifier: "es-MX")
            owner.speechAssetReadiness = .unavailable("Current language is not ready")
            owner.synchronizeShortcutRegistration()
            pending.resume()
            let oldResult = await oldInspection.value
            let staleIgnored = !owner.speechAssetReadiness.isReady && !owner.shortcutRegistration.isOperationReady
            print("LATE-LOCALE localReady=\(oldResult.isReady) current=es-MX staleIgnored=\(staleIgnored)")
            guard oldResult.isReady && staleIgnored else { throw NSError(domain: "stale-locale-enabled-registration", code: 1) }
            LifecycleSpeechDelay.pending = nil
            owner.settings = owner.settings.with(localeIdentifier: "en-US")
            owner.preflightSpeechAssetsIfNeeded()
            for _ in 0..<200 where LifecycleSpeechDelay.pending == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let preflight = LifecycleSpeechDelay.pending else { throw NSError(domain: "preflight-delay-not-entered", code: 1) }
            owner.settings = owner.settings.with(localeIdentifier: "es-MX")
            owner.speechAssetReadiness = .unavailable("Current language is not ready")
            preflight.resume()
            for _ in 0..<200 where owner.speechAssetCheckTask != nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            let stalePreflightIgnored = !owner.speechAssetReadiness.isReady && !owner.shortcutRegistration.isOperationReady
            print("LATE-PREFLIGHT current=es-MX staleIgnored=\(stalePreflightIgnored)")
            guard stalePreflightIgnored else { throw NSError(domain: "stale-preflight-enabled-registration", code: 1) }
            try owner.shortcutRegistration.shutdown()
            owner.storageCapability.shutdown()
            print("PASS onboarding-lifecycle")
        }
    }
    """#

    private static let entryPoint = #"""
    import AppKit
    import Foundation
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    Task { @MainActor in
        do {
            try await OigoAppDelegate.lifecycleContract(root: URL(fileURLWithPath: CommandLine.arguments[1]))
            exit(0)
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
    }
    application.run()
    """#
}
