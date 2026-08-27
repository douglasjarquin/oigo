import Foundation

public enum OigoOnboardingStageStatus: Equatable, Sendable {
    case notStarted
    case succeeded
    case failed
}

public enum OigoOnboardingChecklistStatus: Equatable, Sendable {
    case pending
    case active
    case succeeded
    case failed
}

public enum OigoOnboardingChecklistItem: String, CaseIterable, Sendable {
    case shortcutAndAdmission
    case targetCaptured
    case durableSession
    case microphoneCapture
    case speechAnalysis
    case recordingFinalized
    case rawTranscript
    case cleanup
    case insertionAndVerification

    public var title: String {
        switch self {
        case .shortcutAndAdmission:
            "Shortcut received and operation admitted"
        case .targetCaptured:
            "Destination captured"
        case .durableSession:
            "Durable session created"
        case .microphoneCapture:
            "Microphone capture started"
        case .speechAnalysis:
            "Speech analysis active or truthfully degraded"
        case .recordingFinalized:
            "Recording finalized and audio preserved"
        case .rawTranscript:
            "Raw transcript persisted"
        case .cleanup:
            "Normalization and optional cleanup resolved"
        case .insertionAndVerification:
            "Insertion attempted and destination verified or fallback named"
        }
    }
}

public struct OigoOnboardingChecklistRow: Equatable, Sendable {
    public let item: OigoOnboardingChecklistItem
    public let status: OigoOnboardingChecklistStatus

    public init(item: OigoOnboardingChecklistItem, status: OigoOnboardingChecklistStatus) {
        self.item = item
        self.status = status
    }
}

public enum OigoOnboardingFailedStage: String, Equatable, Sendable {
    case storage
    case selectedSource
    case canonicalBuffer
    case shortcut
    case durableCAF
    case speech
    case cleanup
    case clipboard
    case targetValidation
    case pasteDispatch
    case destinationVerification
    case destinationTimeout
    case destinationMismatch
    case destinationEventFailure
    case destinationTargetChanged
    case destinationNotEditable
}

public enum OigoOnboardingDestinationFailure: Equatable, Sendable {
    case timeout
    case mismatch
    case eventFailure
    case targetChanged
}

public enum OigoOnboardingDestinationFocus {
    public static func isStillSelected(
        firstResponder: ObjectIdentifier?,
        field: ObjectIdentifier,
        fieldEditor: ObjectIdentifier?
    ) -> Bool {
        guard let firstResponder else {
            return false
        }
        if firstResponder == field {
            return true
        }
        if let fieldEditor, firstResponder == fieldEditor {
            return true
        }
        return false
    }
}

public enum OigoOnboardingSignalHealth: Equatable, Sendable {
    case silent
    case clipped
    case usable

    public static let silenceThreshold: Float = 0.001
    public static let clipThreshold: Float = 0.98

    public static func classify(peakAbsolute: Float) -> OigoOnboardingSignalHealth {
        let peak = abs(peakAbsolute)
        if peak >= clipThreshold {
            return .clipped
        }
        if peak <= silenceThreshold {
            return .silent
        }
        return .usable
    }
}

public enum OigoOnboardingInsertionPath: Equatable, Sendable {
    case none
    case production
    case programmaticFieldAssignment
}

public enum OigoOnboardingRecoveryAction: Equatable, Sendable {
    case retry
    case retryStorage
    case openDataLocation
    case openMicrophoneSettings
    case openAccessibilitySettings
    case openHistory
}

public struct OigoOnboardingEvidence: Equatable, Sendable {
    public var operationAdmitted: OigoOnboardingStageStatus = .notStarted
    public var targetCaptured: OigoOnboardingStageStatus = .notStarted
    public var sessionCreated: OigoOnboardingStageStatus = .notStarted
    public var captureStarted: OigoOnboardingStageStatus = .notStarted
    public var speechAnalysis: OigoOnboardingStageStatus = .notStarted
    public var recordingFinalized: OigoOnboardingStageStatus = .notStarted
    public var rawTranscript: OigoOnboardingStageStatus = .notStarted
    public var storage: OigoOnboardingStageStatus = .notStarted
    public var selectedSource: OigoOnboardingStageStatus = .notStarted
    public var canonicalBuffer: OigoOnboardingStageStatus = .notStarted
    public var shortcut: OigoOnboardingStageStatus = .notStarted
    public var durableCAF: OigoOnboardingStageStatus = .notStarted
    public var speech: OigoOnboardingStageStatus = .notStarted
    public var cleanup: OigoOnboardingStageStatus = .notStarted
    public var clipboard: OigoOnboardingStageStatus = .notStarted
    public var targetValidation: OigoOnboardingStageStatus = .notStarted
    public var pasteDispatch: OigoOnboardingStageStatus = .notStarted
    public var destinationVerification: OigoOnboardingStageStatus = .notStarted

    public init() {}

    public var failedStage: OigoOnboardingFailedStage? {
        if storage == .failed { return .storage }
        if selectedSource == .failed { return .selectedSource }
        if canonicalBuffer == .failed { return .canonicalBuffer }
        if shortcut == .failed { return .shortcut }
        if durableCAF == .failed { return .durableCAF }
        if speech == .failed { return .speech }
        if cleanup == .failed { return .cleanup }
        if clipboard == .failed { return .clipboard }
        if targetValidation == .failed { return .targetValidation }
        if pasteDispatch == .failed { return .pasteDispatch }
        if destinationVerification == .failed { return .destinationVerification }
        return nil
    }
}

public struct OigoOnboardingSourceProbeUpdate: Equatable, Sendable {
    public let generation: UInt64
    public let usedInput: OigoInputSelection
    public let usedChannel: Int
    public let acceptedCanonicalBuffer: Bool
    public let signalHealth: OigoOnboardingSignalHealth
    public let meterLevel: Float

    public init(
        generation: UInt64,
        usedInput: OigoInputSelection,
        usedChannel: Int,
        acceptedCanonicalBuffer: Bool,
        signalHealth: OigoOnboardingSignalHealth,
        meterLevel: Float
    ) {
        self.generation = generation
        self.usedInput = usedInput
        self.usedChannel = usedChannel
        self.acceptedCanonicalBuffer = acceptedCanonicalBuffer
        self.signalHealth = signalHealth
        self.meterLevel = meterLevel
    }
}

public struct OigoOnboardingProductionReport: Equatable, Sendable {
    public var usedInput: OigoInputSelection
    public var usedChannel: Int
    public var sessionCreated: Bool
    public var captureStarted: Bool
    public var recordingFinalized: Bool
    public var rawTranscriptPersisted: Bool
    public var cafInitialized: Bool
    public var speechFinalized: Bool
    public var transcriptNonempty: Bool
    public var cleanupSucceeded: Bool?
    public var clipboardWritten: Bool
    public var targetValidationSucceeded: Bool
    public var insertionOutcome: InsertionOutcome?
    public var insertionPath: OigoOnboardingInsertionPath
    public var insertionInvoked: Bool
    public var recoverableArtifactsRetained: Bool
    public var sessionID: UUID?

    public init(
        usedInput: OigoInputSelection,
        usedChannel: Int,
        sessionCreated: Bool,
        captureStarted: Bool? = nil,
        recordingFinalized: Bool? = nil,
        rawTranscriptPersisted: Bool? = nil,
        cafInitialized: Bool,
        speechFinalized: Bool,
        transcriptNonempty: Bool,
        cleanupSucceeded: Bool? = nil,
        clipboardWritten: Bool,
        targetValidationSucceeded: Bool,
        insertionOutcome: InsertionOutcome?,
        insertionPath: OigoOnboardingInsertionPath,
        insertionInvoked: Bool,
        recoverableArtifactsRetained: Bool,
        sessionID: UUID? = nil
    ) {
        self.usedInput = usedInput
        self.usedChannel = usedChannel
        self.sessionCreated = sessionCreated
        self.captureStarted = captureStarted ?? sessionCreated
        self.recordingFinalized = recordingFinalized ?? cafInitialized
        self.rawTranscriptPersisted = rawTranscriptPersisted ?? transcriptNonempty
        self.cafInitialized = cafInitialized
        self.speechFinalized = speechFinalized
        self.transcriptNonempty = transcriptNonempty
        self.cleanupSucceeded = cleanupSucceeded
        self.clipboardWritten = clipboardWritten
        self.targetValidationSucceeded = targetValidationSucceeded
        self.insertionOutcome = insertionOutcome
        self.insertionPath = insertionPath
        self.insertionInvoked = insertionInvoked
        self.recoverableArtifactsRetained = recoverableArtifactsRetained
        self.sessionID = sessionID
    }
}

public struct OigoOnboardingEvidenceMachine: Equatable, Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var probeGeneration: UInt64 = 0
    public private(set) var outcome: OigoOnboardingTestOutcome = .pending
    public private(set) var evidence = OigoOnboardingEvidence()
    public private(set) var selectedInput: OigoInputSelection = .systemDefault
    public private(set) var selectedChannel: Int = OigoInputChannelPolicy.defaultIndex
    public private(set) var usedInput: OigoInputSelection?
    public private(set) var usedChannel: Int?
    public private(set) var storageReady = false
    public private(set) var destinationEditable = false
    public private(set) var destinationCleared = false
    public private(set) var targetCaptured = false
    public private(set) var probeActive = false
    public private(set) var testRunning = false
    public private(set) var acceptedCanonicalBuffer = false
    public private(set) var signalHealth: OigoOnboardingSignalHealth?
    public private(set) var quietOverrideAccepted = false
    public private(set) var insertionPath: OigoOnboardingInsertionPath = .none
    public private(set) var insertionInvoked = false
    public private(set) var insertionOutcome: InsertionOutcome?
    public private(set) var programmaticAssignmentAttempted = false
    public private(set) var eventBoundaryCompleted = false
    public private(set) var fieldMatchesDurableSelectedText = false
    public private(set) var recoverableArtifactsRetained = false
    public private(set) var transcriptNonempty = false
    public private(set) var clipboardWritten = false
    public private(set) var sourceUnavailable = false
    public private(set) var boundSessionID: UUID?
    public private(set) var destinationFailure: OigoOnboardingDestinationFailure?

    public init() {}

    public var canFinishReady: Bool {
        storageReady && outcome.allowsContinue
    }

    public var microphoneCanAdvance: Bool {
        !sourceUnavailable
            && acceptedCanonicalBuffer
            && (signalHealth == .usable || quietOverrideAccepted)
    }

    public var canAcceptCopyOnly: Bool {
        outcome == .failed
            && transcriptNonempty
            && clipboardWritten
            && (insertionOutcome == .copied || insertionOutcome == .secureRejected)
    }

    public var checklist: [OigoOnboardingChecklistRow] {
        let testStatus: OigoOnboardingChecklistStatus = testRunning ? .active : .pending
        return [
            OigoOnboardingChecklistRow(
                item: .shortcutAndAdmission,
                status: checklistStatus(evidence.operationAdmitted)
            ),
            OigoOnboardingChecklistRow(
                item: .targetCaptured,
                status: checklistStatus(evidence.targetCaptured, active: testRunning && !targetCaptured)
            ),
            OigoOnboardingChecklistRow(
                item: .durableSession,
                status: checklistStatus(evidence.sessionCreated, active: testRunning && boundSessionID == nil)
            ),
            OigoOnboardingChecklistRow(
                item: .microphoneCapture,
                status: checklistStatus(evidence.captureStarted, active: testRunning)
            ),
            OigoOnboardingChecklistRow(
                item: .speechAnalysis,
                status: checklistStatus(evidence.speechAnalysis, active: testRunning)
            ),
            OigoOnboardingChecklistRow(
                item: .recordingFinalized,
                status: checklistStatus(evidence.recordingFinalized)
            ),
            OigoOnboardingChecklistRow(
                item: .rawTranscript,
                status: checklistStatus(evidence.rawTranscript)
            ),
            OigoOnboardingChecklistRow(
                item: .cleanup,
                status: checklistStatus(evidence.cleanup)
            ),
            OigoOnboardingChecklistRow(
                item: .insertionAndVerification,
                status: insertionChecklistStatus(testStatus)
            )
        ]
    }

    public var failedStage: OigoOnboardingFailedStage? {
        if !destinationEditable, testRunning || outcome == .failed {
            return .destinationNotEditable
        }
        if evidence.destinationVerification == .failed {
            switch destinationFailure {
            case .timeout:
                return .destinationTimeout
            case .mismatch:
                return .destinationMismatch
            case .eventFailure:
                return .destinationEventFailure
            case .targetChanged:
                return .destinationTargetChanged
            case .none:
                return .destinationVerification
            }
        }
        return evidence.failedStage
    }

    public var recoveryActions: [OigoOnboardingRecoveryAction] {
        switch failedStage {
        case .storage:
            [.retryStorage, .openDataLocation]
        case .selectedSource, .canonicalBuffer:
            [.retry, .openMicrophoneSettings]
        case .targetValidation:
            [.retry, .openAccessibilitySettings]
        case .durableCAF, .speech, .cleanup, .clipboard, .pasteDispatch,
             .destinationVerification, .destinationTimeout, .destinationMismatch,
             .destinationEventFailure, .destinationTargetChanged:
            [.retry, .openHistory]
        case .shortcut, .destinationNotEditable, .none:
            [.retry]
        }
    }

    public var statusMessage: String {
        if let failedStage {
            return Self.statusMessage(for: failedStage)
        }
        switch outcome {
        case .passed:
            return "Automatic paste succeeded."
        case .copyOnlyAccepted:
            return "Copy-only setup accepted. Automatic paste did not succeed."
        case .skipped:
            return "Test skipped. You can run it later from Settings."
        case .failed:
            return "The test did not prove the selected-source-to-paste path."
        case .pending where testRunning:
            return "Recording the selected source."
        case .pending:
            return ""
        }
    }

    public mutating func resetForRerun() {
        generation += 1
        probeGeneration += 1
        outcome = .pending
        evidence = OigoOnboardingEvidence()
        usedInput = nil
        usedChannel = nil
        destinationCleared = false
        targetCaptured = false
        probeActive = false
        testRunning = false
        acceptedCanonicalBuffer = false
        signalHealth = nil
        quietOverrideAccepted = false
        insertionPath = .none
        insertionInvoked = false
        insertionOutcome = nil
        programmaticAssignmentAttempted = false
        eventBoundaryCompleted = false
        fieldMatchesDurableSelectedText = false
        recoverableArtifactsRetained = false
        transcriptNonempty = false
        clipboardWritten = false
        boundSessionID = nil
        destinationFailure = nil
        applyStorageStatus()
        applySelectedSourceAvailability()
    }

    public mutating func setStorageHealth(_ health: DurableSessionHealth) {
        storageReady = health.isReady
        applyStorageStatus()
        if !storageReady, outcome == .passed {
            outcome = .failed
        }
    }

    public mutating func setSelectedSource(
        input: OigoInputSelection,
        channel: Int,
        unavailable: Bool = false
    ) {
        selectedInput = input
        selectedChannel = OigoInputChannelPolicy.sanitized(channel)
        sourceUnavailable = unavailable
        quietOverrideAccepted = false
        acceptedCanonicalBuffer = false
        signalHealth = nil
        applySelectedSourceAvailability()
        evidence.canonicalBuffer = .notStarted
        if probeActive {
            probeGeneration += 1
        }
    }

    public mutating func beginSourceProbe() -> UInt64 {
        probeGeneration += 1
        probeActive = true
        acceptedCanonicalBuffer = false
        signalHealth = nil
        quietOverrideAccepted = false
        evidence.canonicalBuffer = .notStarted
        applySelectedSourceAvailability()
        return probeGeneration
    }

    public mutating func leaveMicrophoneStep() {
        probeGeneration += 1
        probeActive = false
    }

    @discardableResult
    public mutating func recordSourceProbe(_ update: OigoOnboardingSourceProbeUpdate) -> Bool {
        guard probeActive, update.generation == probeGeneration else {
            return false
        }
        usedInput = update.usedInput
        usedChannel = update.usedChannel
        if update.usedInput != selectedInput || update.usedChannel != selectedChannel {
            sourceUnavailable = true
            evidence.selectedSource = .failed
            return true
        }
        evidence.selectedSource = .succeeded
        if update.acceptedCanonicalBuffer {
            acceptedCanonicalBuffer = true
            if signalHealth != .usable {
                signalHealth = update.signalHealth
            }
            if signalHealth == .usable {
                quietOverrideAccepted = false
                evidence.canonicalBuffer = .succeeded
            } else if signalHealth == .clipped {
                evidence.canonicalBuffer = .failed
            } else {
                evidence.canonicalBuffer = .notStarted
            }
        }
        return true
    }

    @discardableResult
    public mutating func acceptQuietOverride() -> Bool {
        guard acceptedCanonicalBuffer, signalHealth == .silent else {
            return false
        }
        quietOverrideAccepted = true
        evidence.canonicalBuffer = .succeeded
        return true
    }

    @discardableResult
    public mutating func beginTest(destinationEditable: Bool) -> UInt64? {
        leaveMicrophoneStep()
        generation += 1
        testRunning = false
        destinationCleared = false
        targetCaptured = false
        insertionPath = .none
        insertionInvoked = false
        insertionOutcome = nil
        programmaticAssignmentAttempted = false
        eventBoundaryCompleted = false
        fieldMatchesDurableSelectedText = false
        recoverableArtifactsRetained = false
        transcriptNonempty = false
        clipboardWritten = false
        boundSessionID = nil
        destinationFailure = nil
        evidence.shortcut = .notStarted
        evidence.operationAdmitted = .succeeded
        evidence.targetCaptured = .notStarted
        evidence.sessionCreated = .notStarted
        evidence.captureStarted = .notStarted
        evidence.speechAnalysis = .notStarted
        evidence.recordingFinalized = .notStarted
        evidence.rawTranscript = .notStarted
        evidence.durableCAF = .notStarted
        evidence.speech = .notStarted
        evidence.cleanup = .notStarted
        evidence.clipboard = .notStarted
        evidence.targetValidation = .notStarted
        evidence.pasteDispatch = .notStarted
        evidence.destinationVerification = .notStarted
        outcome = .pending
        self.destinationEditable = destinationEditable
        applyStorageStatus()
        applySelectedSourceAvailability()
        guard storageReady else {
            evidence.storage = .failed
            outcome = .failed
            return nil
        }
        guard destinationEditable else {
            evidence.destinationVerification = .failed
            outcome = .failed
            return nil
        }
        testRunning = true
        return generation
    }

    @discardableResult
    public mutating func bindSession(generation: UInt64, sessionID: UUID) -> Bool {
        guard generation == self.generation, testRunning || outcome == .pending else {
            return false
        }
        boundSessionID = sessionID
        evidence.sessionCreated = .succeeded
        return true
    }

    @discardableResult
    public mutating func markDestinationCleared(generation: UInt64) -> Bool {
        guard generation == self.generation, testRunning || outcome == .pending else {
            return false
        }
        destinationCleared = true
        targetCaptured = true
        evidence.targetCaptured = .succeeded
        return true
    }

    @discardableResult
    public mutating func recordProductionPath(
        generation: UInt64,
        report: OigoOnboardingProductionReport
    ) -> Bool {
        guard generation == self.generation else {
            return false
        }
        if let boundSessionID, let reported = report.sessionID, boundSessionID != reported {
            return false
        }
        testRunning = false
        if boundSessionID == nil {
            boundSessionID = report.sessionID
        }
        usedInput = report.usedInput
        usedChannel = report.usedChannel
        insertionPath = report.insertionPath
        insertionInvoked = report.insertionInvoked
        insertionOutcome = report.insertionOutcome
        transcriptNonempty = report.transcriptNonempty
        clipboardWritten = report.clipboardWritten
        programmaticAssignmentAttempted = report.insertionPath == .programmaticFieldAssignment

        let sessionCreated = report.sessionCreated && (report.sessionID == nil || report.sessionID == boundSessionID)
        recoverableArtifactsRetained = sessionCreated && report.recoverableArtifactsRetained

        if report.usedInput != selectedInput || report.usedChannel != selectedChannel {
            evidence.selectedSource = .failed
        } else {
            evidence.selectedSource = .succeeded
        }
        if sessionCreated {
            evidence.sessionCreated = .succeeded
            evidence.captureStarted = report.captureStarted ? .succeeded : .failed
            evidence.speechAnalysis = report.speechFinalized ? .succeeded : .failed
            evidence.recordingFinalized = report.recordingFinalized ? .succeeded : .failed
            evidence.rawTranscript = report.rawTranscriptPersisted ? .succeeded : .failed
            evidence.durableCAF = report.cafInitialized ? .succeeded : .failed
            evidence.speech = report.speechFinalized ? .succeeded : .failed
        } else {
            evidence.sessionCreated = .failed
            evidence.captureStarted = .failed
            evidence.speechAnalysis = .notStarted
            evidence.recordingFinalized = .failed
            evidence.rawTranscript = .failed
            evidence.durableCAF = .failed
            evidence.speech = .notStarted
            evidence.cleanup = .notStarted
        }
        if sessionCreated, let cleanupSucceeded = report.cleanupSucceeded {
            evidence.cleanup = cleanupSucceeded ? .succeeded : .failed
        }
        evidence.clipboard = report.clipboardWritten ? .succeeded : .failed
        evidence.targetValidation = report.targetValidationSucceeded ? .succeeded : .failed
        switch report.insertionOutcome {
        case .pasted, .dispatched:
            evidence.pasteDispatch = report.insertionInvoked && report.insertionPath == .production
                ? .succeeded
                : .failed
        case .copied, .secureRejected:
            evidence.pasteDispatch = .failed
        case .failed, .none:
            evidence.pasteDispatch = .failed
        }
        if programmaticAssignmentAttempted {
            evidence.destinationVerification = .failed
            outcome = .failed
            return true
        }
        if evidence.failedStage != nil {
            outcome = .failed
        }
        return true
    }

    @discardableResult
    public mutating func applyProgrammaticFieldAssignment(
        generation: UInt64,
        nonemptyTranscript: Bool
    ) -> Bool {
        guard generation == self.generation else {
            return false
        }
        testRunning = false
        programmaticAssignmentAttempted = true
        insertionPath = .programmaticFieldAssignment
        insertionInvoked = false
        transcriptNonempty = nonemptyTranscript
        fieldMatchesDurableSelectedText = nonemptyTranscript
        evidence.destinationVerification = .failed
        evidence.pasteDispatch = .failed
        outcome = .failed
        return true
    }

    @discardableResult
    public mutating func completeDestinationVerification(
        generation: UInt64,
        fieldMatchesDurableSelectedText: Bool,
        eventBoundaryCompleted: Bool,
        failure: OigoOnboardingDestinationFailure? = nil
    ) -> Bool {
        guard generation == self.generation else {
            return false
        }
        testRunning = false
        self.fieldMatchesDurableSelectedText = fieldMatchesDurableSelectedText
        self.eventBoundaryCompleted = eventBoundaryCompleted
        if outcome == .failed, evidence.failedStage != nil, evidence.failedStage != .destinationVerification {
            return true
        }
        if programmaticAssignmentAttempted || insertionPath != .production || !insertionInvoked {
            failDestinationVerification(.eventFailure)
            return true
        }
        if !destinationEditable {
            evidence.destinationVerification = .failed
            outcome = .failed
            return true
        }
        if let failure {
            failDestinationVerification(failure)
            return true
        }
        if !eventBoundaryCompleted {
            failDestinationVerification(.timeout)
            return true
        }
        if !destinationCleared || !fieldMatchesDurableSelectedText {
            failDestinationVerification(.mismatch)
            return true
        }
        switch insertionOutcome {
        case .pasted, .dispatched:
            evidence.destinationVerification = .succeeded
            destinationFailure = nil
        default:
            failDestinationVerification(.eventFailure)
            return true
        }
        finalizeOutcome()
        return true
    }

    public mutating func skip() {
        leaveMicrophoneStep()
        generation += 1
        testRunning = false
        outcome = .skipped
    }

    @discardableResult
    public mutating func acceptCopyOnly() -> Bool {
        guard canAcceptCopyOnly else {
            return false
        }
        generation += 1
        testRunning = false
        outcome = .copyOnlyAccepted
        return true
    }

    public static func statusMessage(for stage: OigoOnboardingFailedStage) -> String {
        switch stage {
        case .storage:
            "Storage unavailable. Retry storage before finishing setup."
        case .selectedSource:
            "The selected microphone or channel is unavailable."
        case .canonicalBuffer:
            "The selected source did not produce a usable audio buffer."
        case .shortcut:
            "Global shortcut is not active."
        case .durableCAF:
            "Durable recording did not initialize."
        case .speech:
            "Transcription did not finish."
        case .cleanup:
            "Cleanup did not finish."
        case .clipboard:
            "Clipboard write failed."
        case .targetValidation:
            "The destination is not a valid paste target."
        case .pasteDispatch:
            "Automatic paste did not succeed."
        case .destinationVerification:
            "The destination did not match the inserted transcript."
        case .destinationTimeout:
            "The destination did not update before the paste wait ended."
        case .destinationMismatch:
            "The destination did not match the inserted transcript."
        case .destinationEventFailure:
            "Paste dispatch did not reach the destination."
        case .destinationTargetChanged:
            "The destination changed before paste could be verified."
        case .destinationNotEditable:
            "The test destination is not editable."
        }
    }

    public static func isUsableCanonicalBuffer(_ buffer: AudioCaptureBuffer) -> Bool {
        buffer.channelCount == 1
            && buffer.sampleRate > 0
            && buffer.frameCount > 0
            && buffer.pcmData.count >= buffer.frameCount * MemoryLayout<Float>.size
    }

    private func checklistStatus(
        _ status: OigoOnboardingStageStatus,
        active: Bool = false
    ) -> OigoOnboardingChecklistStatus {
        switch status {
        case .notStarted:
            active ? .active : .pending
        case .succeeded:
            .succeeded
        case .failed:
            .failed
        }
    }

    private func insertionChecklistStatus(
        _ activeStatus: OigoOnboardingChecklistStatus
    ) -> OigoOnboardingChecklistStatus {
        switch outcome {
        case .passed, .copyOnlyAccepted:
            .succeeded
        case .skipped:
            .pending
        case .failed:
            .failed
        case .pending:
            activeStatus
        }
    }

    private mutating func applyStorageStatus() {
        evidence.storage = storageReady ? .succeeded : .failed
    }

    private mutating func applySelectedSourceAvailability() {
        evidence.selectedSource = sourceUnavailable ? .failed : .succeeded
    }

    private mutating func failDestinationVerification(_ failure: OigoOnboardingDestinationFailure) {
        destinationFailure = failure
        evidence.destinationVerification = .failed
        outcome = .failed
    }

    private mutating func finalizeOutcome() {
        if outcome == .failed {
            return
        }
        guard storageReady,
              evidence.selectedSource == .succeeded,
              evidence.durableCAF == .succeeded,
              evidence.speech == .succeeded,
              evidence.cleanup != .failed,
              evidence.clipboard == .succeeded,
              evidence.targetValidation == .succeeded,
              evidence.pasteDispatch == .succeeded,
              evidence.destinationVerification == .succeeded,
              destinationEditable,
              destinationCleared,
              eventBoundaryCompleted,
              fieldMatchesDurableSelectedText,
              insertionPath == .production,
              insertionInvoked,
              !programmaticAssignmentAttempted,
              transcriptNonempty
        else {
            outcome = .failed
            return
        }
        switch insertionOutcome {
        case .pasted, .dispatched:
            outcome = .passed
        case .copied, .secureRejected, .failed, .none:
            outcome = .failed
        }
    }
}
