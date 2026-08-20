import Foundation

public struct DictationConfigurationSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let canonicalAudioFormatRevision = "canonical-mono-v1"
    public static let cleanupPolicyRevision = "cleanup-4s-v1"
    public static let deadlinePolicyRevision = "transcription-timeout-v1"
    public static let defaultCleanupDeadlineNanoseconds: UInt64 = 4_000_000_000

    public let version: Int
    public let processingMode: OigoProcessingMode
    public let requestedLocaleIdentifier: String
    public let resolvedLocaleIdentifier: String
    public let inputSelection: OigoInputSelection
    public let resolvedDeviceUID: String?
    public let inputChannelIndex: Int
    public let audioFormatRevision: String
    public let sampleRate: Double
    public let cleanupPolicyRevision: String
    public let cleanupDeadlineNanoseconds: UInt64
    public let deadlinePolicyRevision: String
    public let previewEnabled: Bool
    public let dictionaryRevision: String?

    public init(
        version: Int = DictationConfigurationSnapshot.currentVersion,
        processingMode: OigoProcessingMode,
        requestedLocaleIdentifier: String,
        resolvedLocaleIdentifier: String,
        inputSelection: OigoInputSelection,
        resolvedDeviceUID: String?,
        inputChannelIndex: Int,
        audioFormatRevision: String = DictationConfigurationSnapshot.canonicalAudioFormatRevision,
        sampleRate: Double,
        cleanupPolicyRevision: String = DictationConfigurationSnapshot.cleanupPolicyRevision,
        cleanupDeadlineNanoseconds: UInt64 = DictationConfigurationSnapshot.defaultCleanupDeadlineNanoseconds,
        deadlinePolicyRevision: String = DictationConfigurationSnapshot.deadlinePolicyRevision,
        previewEnabled: Bool,
        dictionaryRevision: String? = nil
    ) {
        self.version = version
        self.processingMode = processingMode
        self.requestedLocaleIdentifier = requestedLocaleIdentifier
        self.resolvedLocaleIdentifier = resolvedLocaleIdentifier
        self.inputSelection = inputSelection
        self.resolvedDeviceUID = resolvedDeviceUID
        self.inputChannelIndex = OigoInputChannelPolicy.sanitized(inputChannelIndex)
        self.audioFormatRevision = audioFormatRevision
        self.sampleRate = sampleRate
        self.cleanupPolicyRevision = cleanupPolicyRevision
        self.cleanupDeadlineNanoseconds = cleanupDeadlineNanoseconds
        self.deadlinePolicyRevision = deadlinePolicyRevision
        self.previewEnabled = previewEnabled
        self.dictionaryRevision = dictionaryRevision
    }

    public var historyLabel: String {
        processingMode.displayName + " · " + resolvedLocaleIdentifier
    }

    public var requiresCleanup: Bool {
        processingMode == .clean
    }

    public static func resolve(
        settings: OigoSettings,
        resolvedLocaleIdentifier: String,
        resolvedDeviceUID: String?,
        format: AudioCaptureFormat
    ) -> DictationConfigurationSnapshot {
        let requestedLocale = settings.localeIdentifier.isEmpty
            ? Locale.current.identifier
            : settings.localeIdentifier
        return DictationConfigurationSnapshot(
            processingMode: settings.defaultMode,
            requestedLocaleIdentifier: requestedLocale,
            resolvedLocaleIdentifier: resolvedLocaleIdentifier,
            inputSelection: settings.selectedInput,
            resolvedDeviceUID: resolvedDeviceUID,
            inputChannelIndex: settings.selectedInputChannel,
            sampleRate: format.sampleRate,
            previewEnabled: settings.showVolatilePreview
        )
    }

    @_spi(Testing)
    public static func testing(
        mode: OigoProcessingMode = .instant,
        locale: String = "en-US",
        requestedLocale: String? = nil,
        deviceUID: String? = "test-input",
        channel: Int = 0,
        sampleRate: Double = 16_000,
        previewEnabled: Bool = true
    ) -> DictationConfigurationSnapshot {
        DictationConfigurationSnapshot(
            processingMode: mode,
            requestedLocaleIdentifier: requestedLocale ?? locale,
            resolvedLocaleIdentifier: locale,
            inputSelection: deviceUID.map { .pinned(uid: $0) } ?? .systemDefault,
            resolvedDeviceUID: deviceUID,
            inputChannelIndex: channel,
            sampleRate: sampleRate,
            previewEnabled: previewEnabled
        )
    }
}

public enum DictationConfigurationIdentity: Equatable, Sendable {
    case known(DictationConfigurationSnapshot)
    case unknown

    public var historyLabel: String {
        switch self {
        case .known(let snapshot):
            snapshot.historyLabel
        case .unknown:
            "Configuration unknown"
        }
    }

    public var snapshot: DictationConfigurationSnapshot? {
        switch self {
        case .known(let snapshot):
            snapshot
        case .unknown:
            nil
        }
    }
}

public enum DictationRetryConfiguration {
    public static func resolve(
        session: SessionMetadata,
        explicitOverride: DictationConfigurationSnapshot?,
        currentSettingsSnapshot: DictationConfigurationSnapshot
    ) -> (snapshot: DictationConfigurationSnapshot, overrideRecorded: Bool) {
        if let explicitOverride {
            return (explicitOverride, true)
        }
        if let original = session.configurationSnapshot {
            return (original, false)
        }
        return (currentSettingsSnapshot, true)
    }
}

public enum NextDictationSettingsPolicy {
    public static func appliesToNextDictation(isOperationActive: Bool) -> Bool {
        isOperationActive
    }

    public static func mayReplaceOwnedCapture(isOperationActive: Bool) -> Bool {
        !isOperationActive
    }

    public static func mayReplaceOwnedTranscription(isOperationActive: Bool) -> Bool {
        !isOperationActive
    }

    public static let nextDictationCopy =
        "Applies to the next dictation. The current recording keeps its original language, mode, microphone, and cleanup settings."
}
