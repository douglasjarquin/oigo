import Darwin
import Foundation

public enum OigoDiagnosticsShortcutRegistration: String, Codable, Equatable, Sendable {
    case present
    case inactive
}

public struct OigoDiagnosticsMaintenanceCounts: Codable, Equatable, Sendable {
    public var inspectedDirectoryCount: Int
    public var skippedDirectoryCount: Int
    public var removedSessionCount: Int
    public var removedAudioCount: Int
    public var moreWorkRemains: Bool

    public init(
        inspectedDirectoryCount: Int,
        skippedDirectoryCount: Int,
        removedSessionCount: Int,
        removedAudioCount: Int,
        moreWorkRemains: Bool
    ) {
        self.inspectedDirectoryCount = inspectedDirectoryCount
        self.skippedDirectoryCount = skippedDirectoryCount
        self.removedSessionCount = removedSessionCount
        self.removedAudioCount = removedAudioCount
        self.moreWorkRemains = moreWorkRemains
    }

    public init(_ summary: SessionMaintenanceSummary) {
        self.init(
            inspectedDirectoryCount: summary.inspectedDirectoryCount,
            skippedDirectoryCount: summary.skippedDirectoryCount,
            removedSessionCount: summary.removedSessionCount,
            removedAudioCount: summary.removedAudioCount,
            moreWorkRemains: summary.moreWorkRemains
        )
    }
}

public struct OigoDiagnosticsSnapshot: Equatable, Sendable {
    public var appVersion: String
    public var build: String
    public var bundleIdentifier: String
    public var macOSVersion: String
    public var architecture: String
    public var storageHealth: DurableSessionHealth
    public var dictationState: DictationState
    public var lastFailureCode: String?
    public var settings: OigoSettings
    public var shortcutRegistration: OigoDiagnosticsShortcutRegistration
    public var shortcutDisplayName: String?
    public var dictionaryEntryCount: Int
    public var sessionCount: Int
    public var lastMaintenance: SessionMaintenanceSummary?

    public init(
        appVersion: String,
        build: String,
        bundleIdentifier: String,
        macOSVersion: String,
        architecture: String,
        storageHealth: DurableSessionHealth,
        dictationState: DictationState,
        lastFailureCode: String?,
        settings: OigoSettings,
        shortcutRegistration: OigoDiagnosticsShortcutRegistration,
        shortcutDisplayName: String?,
        dictionaryEntryCount: Int,
        sessionCount: Int,
        lastMaintenance: SessionMaintenanceSummary?
    ) {
        self.appVersion = appVersion
        self.build = build
        self.bundleIdentifier = bundleIdentifier
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.storageHealth = storageHealth
        self.dictationState = dictationState
        self.lastFailureCode = lastFailureCode
        self.settings = settings
        self.shortcutRegistration = shortcutRegistration
        self.shortcutDisplayName = shortcutDisplayName
        self.dictionaryEntryCount = dictionaryEntryCount
        self.sessionCount = sessionCount
        self.lastMaintenance = lastMaintenance
    }
}

public struct OigoDiagnosticsExport: Codable, Equatable, Sendable {
    public var appVersion: String
    public var build: String
    public var bundleIdentifier: String
    public var macOSVersion: String
    public var architecture: String
    public var storageHealth: String
    public var dictationState: String
    public var lastFailureCode: String?
    public var defaultMode: String
    public var previewEnabled: Bool
    public var retention: String
    public var keepAudioIndefinitely: Bool
    public var launchAtLoginLastRequested: Bool
    public var localeIdentifier: String
    public var selectedInput: String
    public var shortcutRegistration: String
    public var shortcutDisplayName: String?
    public var dictionaryEntryCount: Int
    public var sessionCount: Int
    public var lastMaintenance: OigoDiagnosticsMaintenanceCounts?

    private enum CodingKeys: String, CodingKey {
        case appVersion
        case build
        case bundleIdentifier
        case macOSVersion
        case architecture
        case storageHealth
        case dictationState
        case lastFailureCode
        case defaultMode
        case previewEnabled
        case retention
        case keepAudioIndefinitely
        case launchAtLoginLastRequested
        case localeIdentifier
        case selectedInput
        case shortcutRegistration
        case shortcutDisplayName
        case dictionaryEntryCount
        case sessionCount
        case lastMaintenance
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(build, forKey: .build)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(macOSVersion, forKey: .macOSVersion)
        try container.encode(architecture, forKey: .architecture)
        try container.encode(storageHealth, forKey: .storageHealth)
        try container.encode(dictationState, forKey: .dictationState)
        try container.encode(lastFailureCode, forKey: .lastFailureCode)
        try container.encode(defaultMode, forKey: .defaultMode)
        try container.encode(previewEnabled, forKey: .previewEnabled)
        try container.encode(retention, forKey: .retention)
        try container.encode(keepAudioIndefinitely, forKey: .keepAudioIndefinitely)
        try container.encode(launchAtLoginLastRequested, forKey: .launchAtLoginLastRequested)
        try container.encode(localeIdentifier, forKey: .localeIdentifier)
        try container.encode(selectedInput, forKey: .selectedInput)
        try container.encode(shortcutRegistration, forKey: .shortcutRegistration)
        try container.encode(shortcutDisplayName, forKey: .shortcutDisplayName)
        try container.encode(dictionaryEntryCount, forKey: .dictionaryEntryCount)
        try container.encode(sessionCount, forKey: .sessionCount)
        try container.encode(lastMaintenance, forKey: .lastMaintenance)
    }

    public static let requiredKeys: [String] = [
        "appVersion",
        "architecture",
        "bundleIdentifier",
        "build",
        "defaultMode",
        "dictationState",
        "dictionaryEntryCount",
        "keepAudioIndefinitely",
        "lastFailureCode",
        "lastMaintenance",
        "launchAtLoginLastRequested",
        "localeIdentifier",
        "macOSVersion",
        "previewEnabled",
        "retention",
        "selectedInput",
        "sessionCount",
        "shortcutDisplayName",
        "shortcutRegistration",
        "storageHealth"
    ]

    public static func make(_ snapshot: OigoDiagnosticsSnapshot) -> OigoDiagnosticsExport {
        OigoDiagnosticsExport(
            appVersion: snapshot.appVersion,
            build: snapshot.build,
            bundleIdentifier: snapshot.bundleIdentifier,
            macOSVersion: snapshot.macOSVersion,
            architecture: snapshot.architecture,
            storageHealth: snapshot.storageHealth.diagnosticsCategory,
            dictationState: snapshot.dictationState.rawValue,
            lastFailureCode: snapshot.lastFailureCode,
            defaultMode: snapshot.settings.defaultMode.rawValue,
            previewEnabled: snapshot.settings.showVolatilePreview,
            retention: snapshot.settings.audioRetention.rawValue,
            keepAudioIndefinitely: snapshot.settings.keepSuccessfulAudioIndefinitely,
            launchAtLoginLastRequested: snapshot.settings.launchAtLogin,
            localeIdentifier: snapshot.settings.localeIdentifier,
            selectedInput: snapshot.settings.selectedInput.diagnosticsKind,
            shortcutRegistration: snapshot.shortcutRegistration.rawValue,
            shortcutDisplayName: snapshot.shortcutDisplayName,
            dictionaryEntryCount: snapshot.dictionaryEntryCount,
            sessionCount: snapshot.sessionCount,
            lastMaintenance: snapshot.lastMaintenance.map(OigoDiagnosticsMaintenanceCounts.init)
        )
    }

    public static func currentMacOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return String(version.majorVersion)
            + "."
            + String(version.minorVersion)
            + "."
            + String(version.patchVersion)
    }

    public static func currentArchitecture() -> String {
        var system = utsname()
        guard uname(&system) == 0 else {
#if arch(arm64)
            return "arm64"
#else
            return "unknown"
#endif
        }
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { machine in
                String(cString: machine)
            }
        }
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }
}

public enum OigoDiagnosticsFailureCode {
    public static func code(for error: Error) -> String {
        if let error = error as? DictationCoordinatorError {
            switch error {
            case .workAlreadyActive:
                return "dictation.workAlreadyActive"
            case .recordingNotActive:
                return "dictation.recordingNotActive"
            case .retryDidNotPersist:
                return "dictation.retryDidNotPersist"
            case .rawTranscriptNotPersisted:
                return "dictation.rawTranscriptNotPersisted"
            }
        }
        if let error = error as? DurableSessionAccessError {
            switch error {
            case .storageUnavailable(let category):
                return "storage.unavailable." + (category?.rawValue ?? "unknown")
            }
        }
        if let error = error as? DurableSessionBootstrapFailure {
            return "storage." + error.category.rawValue
        }
        if let error = error as? DictionaryStoreError {
            switch error {
            case .emptyCanonical:
                return "dictionary.emptyCanonical"
            case .emptyAlias:
                return "dictionary.emptyAlias"
            case .duplicateAliasInEntry:
                return "dictionary.duplicateAliasInEntry"
            case .conflictingAlias:
                return "dictionary.conflictingAlias"
            case .unsupportedVersion:
                return "dictionary.unsupportedVersion"
            case .malformed:
                return "dictionary.malformed"
            case .tooLarge:
                return "dictionary.tooLarge"
            case .notRegularFile:
                return "dictionary.notRegularFile"
            case .symlinkRejected:
                return "dictionary.symlinkRejected"
            case .writeFailed:
                return "dictionary.writeFailed"
            }
        }
        if let error = error as? SessionStoreError {
            switch error {
            case .applicationSupportUnavailable:
                return "session.applicationSupportUnavailable"
            case .missingSession:
                return "session.missingSession"
            case .stateChanged:
                return "session.stateChanged"
            case .invalidMetadata:
                return "session.invalidMetadata"
            case .invalidSessionDirectory:
                return "session.invalidSessionDirectory"
            case .transcriptTooLarge:
                return "session.transcriptTooLarge"
            case .insertionAlreadyAttempted:
                return "session.insertionAlreadyAttempted"
            case .activeSession:
                return "session.activeSession"
            case .rawTextChanged:
                return "session.rawTextChanged"
            case .normalizedTextChanged:
                return "session.normalizedTextChanged"
            case .deletionConfirmationRequired:
                return "session.deletionConfirmationRequired"
            }
        }
        return String(describing: Swift.type(of: error))
    }
}

public extension DurableSessionHealth {
    var diagnosticsCategory: String {
        switch self {
        case .checking:
            "checking"
        case .ready:
            "ready"
        case .recoverablyUnavailable(let category):
            "recoverablyUnavailable." + category.rawValue
        case .fatallyInvalid(let category):
            "fatallyInvalid." + category.rawValue
        }
    }
}

public extension OigoInputSelection {
    var diagnosticsKind: String {
        switch self {
        case .systemDefault:
            "systemDefault"
        case .pinned:
            "pinned"
        }
    }
}
