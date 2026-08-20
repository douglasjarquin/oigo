import Foundation

public enum OigoProcessingMode: String, Codable, CaseIterable, Sendable {
    case instant
    case clean

    public var displayName: String {
        rawValue.capitalized
    }

    public var supportsDictationWithoutFoundationModels: Bool {
        self == .instant
    }
}

public enum OigoAudioRetention: String, Codable, CaseIterable, Sendable {
    case oneDay
    case oneWeek
    case oneMonth
    case threeMonths

    public var displayName: String {
        switch self {
        case .oneDay:
            "1 day"
        case .oneWeek:
            "1 week"
        case .oneMonth:
            "1 month"
        case .threeMonths:
            "3 months"
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .oneDay:
            24 * 60 * 60
        case .oneWeek:
            7 * 24 * 60 * 60
        case .oneMonth:
            30 * 24 * 60 * 60
        case .threeMonths:
            90 * 24 * 60 * 60
        }
    }
}

public struct OigoInputDevice: Codable, Equatable, Hashable, Sendable {
    public let uid: String
    public let displayName: String
    public let deviceID: UInt32
    public let inputChannelCount: Int
    public let nominalSampleRate: Double
    public let isAlive: Bool
    public let isDefault: Bool

    public init(
        uid: String,
        displayName: String,
        deviceID: UInt32,
        inputChannelCount: Int,
        nominalSampleRate: Double,
        isAlive: Bool,
        isDefault: Bool
    ) {
        self.uid = uid
        self.displayName = displayName
        self.deviceID = deviceID
        self.inputChannelCount = inputChannelCount
        self.nominalSampleRate = nominalSampleRate
        self.isAlive = isAlive
        self.isDefault = isDefault
    }
}

public enum OigoInputSelection: Codable, Equatable, Hashable, Sendable {
    case systemDefault
    case pinned(uid: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case uid
    }

    private enum Kind: String, Codable {
        case systemDefault
        case pinned
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .systemDefault:
            self = .systemDefault
        case .pinned:
            self = .pinned(uid: try container.decode(String.self, forKey: .uid))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .systemDefault:
            try container.encode(Kind.systemDefault, forKey: .kind)
        case .pinned(let uid):
            try container.encode(Kind.pinned, forKey: .kind)
            try container.encode(uid, forKey: .uid)
        }
    }
}

public enum OigoInputDeviceResolutionError: Error, Equatable, CustomStringConvertible, Sendable {
    case noAvailableInput
    case pinnedInputUnavailable

    public var description: String {
        switch self {
        case .noAvailableInput:
            "no available microphone input was found; connect an input or choose another source in Oigo Settings"
        case .pinnedInputUnavailable:
            "the selected microphone is unavailable; reconnect it or choose another source in Oigo Settings"
        }
    }
}

public enum OigoInputDeviceCatalog {
    public static func visibleDevices(from devices: [OigoInputDevice]) -> [OigoInputDevice] {
        devices
            .filter { $0.isAlive && $0.inputChannelCount > 0 }
            .sorted {
                let nameOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return $0.uid < $1.uid
            }
    }

    public static func resolve(
        _ selection: OigoInputSelection,
        from devices: [OigoInputDevice]
    ) throws -> OigoInputDevice {
        let visibleDevices = visibleDevices(from: devices)
        switch selection {
        case .systemDefault:
            guard let device = visibleDevices.first(where: \.isDefault) else {
                throw OigoInputDeviceResolutionError.noAvailableInput
            }
            return device
        case .pinned(let uid):
            guard let device = visibleDevices.first(where: { $0.uid == uid }) else {
                throw OigoInputDeviceResolutionError.pinnedInputUnavailable
            }
            return device
        }
    }

    public static func resolveAndRoute(
        _ selection: OigoInputSelection,
        from devices: [OigoInputDevice],
        route: (OigoInputDevice) throws -> Void
    ) throws -> OigoInputDevice {
        let device = try resolve(selection, from: devices)
        try route(device)
        return device
    }

    public static func resolveAndRouteBeforeInspection(
        _ selection: OigoInputSelection,
        from devices: [OigoInputDevice],
        route: (OigoInputDevice) throws -> Void,
        inspect: (OigoInputDevice) throws -> Void
    ) throws -> OigoInputDevice {
        let device = try resolveAndRoute(selection, from: devices, route: route)
        try inspect(device)
        return device
    }
}

public struct OigoInputMenuItem: Equatable, Sendable {
    public let title: String
    public let selection: OigoInputSelection
    public let isUnavailable: Bool

    public init(
        title: String,
        selection: OigoInputSelection,
        isUnavailable: Bool = false
    ) {
        self.title = title
        self.selection = selection
        self.isUnavailable = isUnavailable
    }
}

public enum OigoInputMenu {
    public static func items(
        devices: [OigoInputDevice],
        selected: OigoInputSelection
    ) -> [OigoInputMenuItem] {
        let visibleDevices = OigoInputDeviceCatalog.visibleDevices(from: devices)
        var items = [
            OigoInputMenuItem(
                title: "System Default",
                selection: .systemDefault
            )
        ]
        items.append(contentsOf: visibleDevices.map { device in
            OigoInputMenuItem(
                title: device.displayName,
                selection: .pinned(uid: device.uid)
            )
        })

        if case .pinned(let uid) = selected,
           !visibleDevices.contains(where: { $0.uid == uid }) {
            items.append(OigoInputMenuItem(
                title: "Unavailable input - reconnect or choose another source",
                selection: .pinned(uid: uid),
                isUnavailable: true
            ))
        }
        return items
    }
}

public struct OigoSettings: Codable, Equatable, Sendable {
    public static let `default` = OigoSettings()

    public var globalShortcut: ToggleShortcut
    public var localeIdentifier: String
    public var defaultMode: OigoProcessingMode
    public var showVolatilePreview: Bool
    public var audioRetention: OigoAudioRetention
    public var keepSuccessfulAudioIndefinitely: Bool
    public var launchAtLogin: Bool
    public var selectedInput: OigoInputSelection

    private enum CodingKeys: String, CodingKey {
        case globalShortcut
        case localeIdentifier
        case defaultMode
        case showVolatilePreview
        case audioRetention
        case keepSuccessfulAudioIndefinitely
        case launchAtLogin
        case selectedInput
    }

    public init(
        globalShortcut: ToggleShortcut = .default,
        localeIdentifier: String = Locale.current.identifier,
        defaultMode: OigoProcessingMode = .instant,
        showVolatilePreview: Bool = true,
        audioRetention: OigoAudioRetention = .oneDay,
        keepSuccessfulAudioIndefinitely: Bool = false,
        launchAtLogin: Bool = false,
        selectedInput: OigoInputSelection = .systemDefault
    ) {
        self.globalShortcut = globalShortcut
        self.localeIdentifier = localeIdentifier
        self.defaultMode = defaultMode
        self.showVolatilePreview = showVolatilePreview
        self.audioRetention = audioRetention
        self.keepSuccessfulAudioIndefinitely = keepSuccessfulAudioIndefinitely
        self.launchAtLogin = launchAtLogin
        self.selectedInput = selectedInput
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            globalShortcut: try container.decode(ToggleShortcut.self, forKey: .globalShortcut),
            localeIdentifier: try container.decode(String.self, forKey: .localeIdentifier),
            defaultMode: try container.decode(OigoProcessingMode.self, forKey: .defaultMode),
            showVolatilePreview: try container.decode(Bool.self, forKey: .showVolatilePreview),
            audioRetention: try container.decode(OigoAudioRetention.self, forKey: .audioRetention),
            keepSuccessfulAudioIndefinitely: try container.decode(Bool.self, forKey: .keepSuccessfulAudioIndefinitely),
            launchAtLogin: try container.decode(Bool.self, forKey: .launchAtLogin),
            selectedInput: try container.decodeIfPresent(OigoInputSelection.self, forKey: .selectedInput) ?? .systemDefault
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(globalShortcut, forKey: .globalShortcut)
        try container.encode(localeIdentifier, forKey: .localeIdentifier)
        try container.encode(defaultMode, forKey: .defaultMode)
        try container.encode(showVolatilePreview, forKey: .showVolatilePreview)
        try container.encode(audioRetention, forKey: .audioRetention)
        try container.encode(keepSuccessfulAudioIndefinitely, forKey: .keepSuccessfulAudioIndefinitely)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(selectedInput, forKey: .selectedInput)
    }

    public func with(
        globalShortcut: ToggleShortcut? = nil,
        localeIdentifier: String? = nil,
        defaultMode: OigoProcessingMode? = nil,
        showVolatilePreview: Bool? = nil,
        audioRetention: OigoAudioRetention? = nil,
        keepSuccessfulAudioIndefinitely: Bool? = nil,
        launchAtLogin: Bool? = nil,
        selectedInput: OigoInputSelection? = nil
    ) -> OigoSettings {
        OigoSettings(
            globalShortcut: globalShortcut ?? self.globalShortcut,
            localeIdentifier: localeIdentifier ?? self.localeIdentifier,
            defaultMode: defaultMode ?? self.defaultMode,
            showVolatilePreview: showVolatilePreview ?? self.showVolatilePreview,
            audioRetention: audioRetention ?? self.audioRetention,
            keepSuccessfulAudioIndefinitely: keepSuccessfulAudioIndefinitely
                ?? self.keepSuccessfulAudioIndefinitely,
            launchAtLogin: launchAtLogin ?? self.launchAtLogin,
            selectedInput: selectedInput ?? self.selectedInput
        )
    }
}

public enum OigoSettingsStoreError: Error, Equatable, LocalizedError, Sendable {
    case encodingFailed(String)
    case writeFailed(String)
    case writeRejected
    case storeUnavailable

    public var errorDescription: String? {
        switch self {
        case .encodingFailed(let reason):
            "Settings could not be encoded: \(reason)"
        case .writeFailed(let reason):
            "Settings could not be persisted: \(reason)"
        case .writeRejected:
            "Settings storage rejected the new value"
        case .storeUnavailable:
            "Settings storage is no longer available"
        }
    }
}

public final class OigoSettingsStore {
    private static let key = "oigo.settings.v1"
    private static let legacyShortcutDefault = ToggleShortcut(keyCode: 49, modifiers: 0x900)
    private let defaults: UserDefaults
    private let writeData: (Data) throws -> Void

    public init(
        defaults: UserDefaults = .standard,
        writeData: ((Data) throws -> Void)? = nil
    ) {
        self.defaults = defaults
        self.writeData = writeData ?? { [defaults] data in
            defaults.set(data, forKey: Self.key)
            guard defaults.data(forKey: Self.key) == data else {
                throw OigoSettingsStoreError.writeRejected
            }
        }
    }

    public func load() -> OigoSettings {
        if let data = defaults.data(forKey: Self.key),
           let settings = try? JSONDecoder().decode(OigoSettings.self, from: data) {
            let migrated = migrate(settings)
            if migrated != settings {
                try? save(migrated)
            }
            return migrated
        }

        var settings = OigoSettings.default
        var loadedLegacyShortcut = false
        if let data = defaults.data(forKey: "globalToggleShortcut"),
           let shortcut = try? JSONDecoder().decode(ToggleShortcut.self, from: data) {
            settings.globalShortcut = migrate(shortcut)
            loadedLegacyShortcut = true
        }
        if let rawMode = defaults.string(forKey: "transcriptCleanupMode"),
           let mode = OigoProcessingMode(rawValue: rawMode) {
            settings.defaultMode = mode
        }
        if loadedLegacyShortcut {
            try? save(settings)
        }
        return settings
    }

    private func migrate(_ settings: OigoSettings) -> OigoSettings {
        settings.with(globalShortcut: migrate(settings.globalShortcut))
    }

    private func migrate(_ shortcut: ToggleShortcut) -> ToggleShortcut {
        shortcut == Self.legacyShortcutDefault ? .default : shortcut
    }

    public func save(_ settings: OigoSettings) throws {
        let data: Data
        let previousData = defaults.data(forKey: Self.key)
        do {
            data = try JSONEncoder().encode(settings)
        } catch {
            throw OigoSettingsStoreError.encodingFailed(String(describing: error))
        }
        do {
            try writeData(data)
        } catch let error as OigoSettingsStoreError {
            do {
                try restore(previousData)
            } catch let restoreError {
                throw OigoSettingsStoreError.writeFailed(
                    "\(error.localizedDescription); settings rollback failed: \(restoreError.localizedDescription)"
                )
            }
            throw error
        } catch {
            do {
                try restore(previousData)
            } catch let restoreError {
                throw OigoSettingsStoreError.writeFailed(
                    "\(error); settings rollback failed: \(restoreError.localizedDescription)"
                )
            }
            throw OigoSettingsStoreError.writeFailed(String(describing: error))
        }
    }

    private func restore(_ data: Data?) throws {
        if let data {
            defaults.set(data, forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
        guard defaults.data(forKey: Self.key) == data else {
            throw OigoSettingsStoreError.writeRejected
        }
    }
}

public enum OigoOnboardingStep: String, Codable, CaseIterable, Sendable {
    case system
    case language
    case microphone
    case shortcut
    case insertion
    case testDictation
    case recovery
    case complete

    public var title: String {
        switch self {
        case .system:
            "System support"
        case .language:
            "Dictation language"
        case .microphone:
            "Microphone"
        case .shortcut:
            "Global shortcut"
        case .insertion:
            "Text insertion"
        case .testDictation:
            "Test dictation"
        case .recovery:
            "Recovery"
        case .complete:
            "Ready"
        }
    }

    public var ordinal: Int {
        switch self {
        case .system:
            1
        case .language:
            2
        case .microphone:
            3
        case .shortcut:
            4
        case .insertion:
            5
        case .testDictation:
            6
        case .recovery:
            7
        case .complete:
            8
        }
    }
}

public enum OigoOnboardingTestOutcome: String, Equatable, Sendable {
    case pending
    case passed
    case skipped

    public var allowsContinue: Bool {
        self != .pending
    }
}

public struct OigoOnboardingState: Codable, Equatable, Sendable {
    public var step: OigoOnboardingStep

    public init(step: OigoOnboardingStep = .system) {
        self.step = step
    }

    public var isComplete: Bool {
        step == .complete
    }
}

public final class OigoOnboardingStore {
    private static let key = "oigo.onboarding.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> OigoOnboardingState {
        guard let data = defaults.data(forKey: Self.key),
              let state = try? JSONDecoder().decode(OigoOnboardingState.self, from: data) else {
            return OigoOnboardingState()
        }
        return state
    }

    public func save(_ state: OigoOnboardingState) {
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }
        defaults.set(data, forKey: Self.key)
    }

    public func markCompleted() {
        save(OigoOnboardingState(step: .complete))
    }

    public func rerun() {
        save(OigoOnboardingState())
    }
}

public enum OigoSystemArchitecture: String, Sendable {
    case appleSilicon
    case intel
}

public struct OigoSystemSupportResult: Equatable, Sendable {
    public let isSupported: Bool
    public let reason: String

    public init(isSupported: Bool, reason: String) {
        self.isSupported = isSupported
        self.reason = reason
    }
}

public enum OigoSystemSupportEvaluator {
    public static func evaluate(
        osVersion: OperatingSystemVersion,
        architecture: OigoSystemArchitecture
    ) -> OigoSystemSupportResult {
        var reasons: [String] = []
        let isOlderThanRequired = osVersion.majorVersion < 26
            || (osVersion.majorVersion == 26 && osVersion.minorVersion < 0)
            || (osVersion.majorVersion == 26
                && osVersion.minorVersion == 0
                && osVersion.patchVersion < 0)
        if isOlderThanRequired {
            reasons.append("Oigo requires macOS 26 or later")
        }
        if architecture != .appleSilicon {
            reasons.append("Oigo requires an Apple silicon Mac")
        }
        if reasons.isEmpty {
            return OigoSystemSupportResult(isSupported: true, reason: "This Mac is supported")
        }
        return OigoSystemSupportResult(isSupported: false, reason: reasons.joined(separator: ". "))
    }

    public static func current() -> OigoSystemSupportResult {
        #if arch(arm64)
        let architecture: OigoSystemArchitecture = .appleSilicon
        #else
        let architecture: OigoSystemArchitecture = .intel
        #endif
        return evaluate(
            osVersion: ProcessInfo.processInfo.operatingSystemVersion,
            architecture: architecture
        )
    }
}

public enum OigoSupportedLocaleResolver {
    public static func closest(to requestedIdentifier: String, among identifiers: [String]) -> String? {
        guard !identifiers.isEmpty else {
            return nil
        }
        let requested = Locale(identifier: requestedIdentifier)
        let requestedLanguage = requested.language.languageCode?.identifier.lowercased()
        let requestedScript = requested.language.script?.identifier.lowercased()
        let requestedRegion = requested.region?.identifier.lowercased()

        return identifiers
            .map { identifier in
                let locale = Locale(identifier: identifier)
                let exact = locale.identifier.caseInsensitiveCompare(requested.identifier) == .orderedSame
                let language = locale.language.languageCode?.identifier.lowercased()
                let script = locale.language.script?.identifier.lowercased()
                let region = locale.region?.identifier.lowercased()
                var score = exact ? 1_000 : 0
                if language == requestedLanguage {
                    score += 100
                }
                if script != nil, script == requestedScript {
                    score += 25
                }
                if region != nil, region == requestedRegion {
                    score += 10
                }
                return (identifier, score)
            }
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                return lhs.0 < rhs.0
            }
            .first?.0
    }
}

public enum OigoPermissionState: String, Codable, Sendable {
    case unknown
    case granted
    case denied
}

public struct OigoPermissionPresentation: Equatable, Sendable {
    public let title: String
    public let explanation: String
    public let settingsURL: URL
    public let allowsCopyOnly: Bool

    public static func microphone(_ state: OigoPermissionState) -> OigoPermissionPresentation {
        OigoPermissionPresentation(
            title: "Microphone access",
            explanation: state == .denied
                ? "Oigo cannot record until microphone access is allowed. Open Privacy & Security to recover."
                : "Oigo needs microphone access to record and save your dictation audio.",
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!,
            allowsCopyOnly: false
        )
    }

    public static func accessibility(_ state: OigoPermissionState) -> OigoPermissionPresentation {
        OigoPermissionPresentation(
            title: "Accessibility access",
            explanation: state == .denied
                ? "Automatic paste is unavailable, but Oigo will keep the transcript on the clipboard and in History."
                : "Oigo uses Accessibility only to paste a completed transcript back into the field you were using.",
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!,
            allowsCopyOnly: true
        )
    }

    public init(
        title: String,
        explanation: String,
        settingsURL: URL,
        allowsCopyOnly: Bool
    ) {
        self.title = title
        self.explanation = explanation
        self.settingsURL = settingsURL
        self.allowsCopyOnly = allowsCopyOnly
    }
}

public enum OigoShortcutValidation: Equatable, Sendable {
    case available
    case conflict(String)
    case invalid(String)

    public var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    public var isConflict: Bool {
        if case .conflict = self {
            return true
        }
        return false
    }
}

public enum ToggleShortcutModifiers {
    public static let command: UInt32 = 0x100
    public static let shift: UInt32 = 0x200
    public static let option: UInt32 = 0x800
    public static let control: UInt32 = 0x1000
    public static let supportedMask: UInt32 = command | shift | option | control
}

public enum OigoShortcutValidator {
    public static func validate(
        _ shortcut: ToggleShortcut,
        occupied: [ToggleShortcut]
    ) -> OigoShortcutValidation {
        guard shortcut.modifiers & ToggleShortcutModifiers.supportedMask != 0 else {
            return .invalid("Choose at least one supported modifier for the global shortcut")
        }
        guard shortcut.modifiers & ~ToggleShortcutModifiers.supportedMask == 0 else {
            return .invalid("Choose only supported modifiers for the global shortcut")
        }
        guard !occupied.contains(shortcut) else {
            return .conflict("That shortcut is already registered by another application")
        }
        return .available
    }
}

public enum OigoLaunchAtLoginImplementation: String, Sendable {
    case publicMainAppService = "SMAppService.mainApp"

    public var usesHelperProcess: Bool {
        false
    }
}

public enum OigoLaunchAtLoginStatus: String, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case notFound
    case unknown
}

@MainActor
public protocol OigoLaunchAtLoginClient: AnyObject {
    var status: OigoLaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor
public final class OigoLaunchAtLoginController {
    private let client: OigoLaunchAtLoginClient

    public init(client: OigoLaunchAtLoginClient) {
        self.client = client
    }

    public var isEnabled: Bool {
        client.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try client.register()
        } else {
            try client.unregister()
        }
    }
}

public enum OigoHUDProcessingState: String, CaseIterable, Sendable {
    case finalizing = "Finalizing"
    case cleaning = "Cleaning"
    case pasting = "Pasting"
    case pasteAttempted = "Paste attempted"
    case pasted = "Pasted"
    case copied = "Copied"
    case completedPasteFailed = "Dictation completed; paste failed"
    case failed = "Failed"
}

public struct DictationHistoryCapabilities: Equatable, Sendable {
    public let copyAvailable: Bool
    public let pasteAgainAvailable: Bool
    public let savedAudioRetryAvailable: Bool

    public init(
        copyAvailable: Bool,
        pasteAgainAvailable: Bool,
        savedAudioRetryAvailable: Bool
    ) {
        self.copyAvailable = copyAvailable
        self.pasteAgainAvailable = pasteAgainAvailable
        self.savedAudioRetryAvailable = savedAudioRetryAvailable
    }
}

public enum DictationHistoryActions {
    public static func capabilities(
        sessionState: DictationSessionState,
        hasValidRaw: Bool,
        hasAudio: Bool
    ) -> DictationHistoryCapabilities {
        let transcriptActions = !sessionState.isUnfinished && hasValidRaw
        return DictationHistoryCapabilities(
            copyAvailable: transcriptActions,
            pasteAgainAvailable: transcriptActions,
            savedAudioRetryAvailable: [.failed, .interrupted].contains(sessionState) && hasAudio
        )
    }
}

public enum DictationTerminalKind: String, CaseIterable, Equatable, Sendable {
    case captureFailed
    case speechFailed
    case speechTimedOut
    case cleanupFallback
    case insertionPasted
    case insertionDispatched
    case insertionCopied
    case insertionSecureRejected
    case insertionFailed
    case cancelledBeforeRaw
    /// Cancellation or shutdown after durable raw text exists, including quit during cleaning or inserting.
    case cancelledAfterRaw
    case interrupted
    /// Application shutdown during capture or Speech, before durable raw text exists.
    case applicationShutdown
}

public struct DictationTerminalPath: Equatable, Sendable {
    public let kind: DictationTerminalKind
    public let coordinatorState: DictationState
    public let sessionState: DictationSessionState
    public let insertionOutcome: InsertionOutcome?
    public let hasValidRaw: Bool
    public let hasAudio: Bool
    public let statusCopy: String
    public let history: DictationHistoryCapabilities

    public init(
        kind: DictationTerminalKind,
        coordinatorState: DictationState,
        sessionState: DictationSessionState,
        insertionOutcome: InsertionOutcome?,
        hasValidRaw: Bool,
        hasAudio: Bool,
        statusCopy: String
    ) {
        self.kind = kind
        self.coordinatorState = coordinatorState
        self.sessionState = sessionState
        self.insertionOutcome = insertionOutcome
        self.hasValidRaw = hasValidRaw
        self.hasAudio = hasAudio
        self.statusCopy = statusCopy
        self.history = DictationHistoryActions.capabilities(
            sessionState: sessionState,
            hasValidRaw: hasValidRaw,
            hasAudio: hasAudio
        )
    }
}

public enum DictationTerminalContract {
    public static func statusCopy(
        sessionState: DictationSessionState,
        insertionOutcome: InsertionOutcome?
    ) -> String {
        if sessionState == .completed, insertionOutcome == .failed {
            return "Dictation completed; paste failed"
        }
        switch sessionState {
        case .completed:
            return "Complete"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        case .interrupted:
            return "Interrupted"
        case .preparing, .recording, .stopping:
            return "Active"
        case .retrying:
            return "Retrying"
        }
    }

    public static func coordinatorState(
        sessionState: DictationSessionState
    ) -> DictationState {
        switch sessionState {
        case .completed:
            .complete
        case .failed:
            .failed
        case .cancelled:
            .cancelled
        case .interrupted:
            .interrupted
        case .preparing:
            .preparing
        case .recording:
            .recording
        case .stopping:
            .finalizing
        case .retrying:
            .failed
        }
    }

    public static let legalPaths: [DictationTerminalPath] = [
        DictationTerminalPath(
            kind: .captureFailed,
            coordinatorState: .failed,
            sessionState: .failed,
            insertionOutcome: nil,
            hasValidRaw: false,
            hasAudio: true,
            statusCopy: "Failed"
        ),
        DictationTerminalPath(
            kind: .speechFailed,
            coordinatorState: .failed,
            sessionState: .failed,
            insertionOutcome: nil,
            hasValidRaw: false,
            hasAudio: true,
            statusCopy: "Failed"
        ),
        DictationTerminalPath(
            kind: .speechTimedOut,
            coordinatorState: .failed,
            sessionState: .failed,
            insertionOutcome: nil,
            hasValidRaw: false,
            hasAudio: true,
            statusCopy: "Failed"
        ),
        DictationTerminalPath(
            kind: .cleanupFallback,
            coordinatorState: .complete,
            sessionState: .completed,
            insertionOutcome: .pasted,
            hasValidRaw: true,
            hasAudio: true,
            statusCopy: "Complete"
        ),
        DictationTerminalPath(
            kind: .insertionPasted,
            coordinatorState: .complete,
            sessionState: .completed,
            insertionOutcome: .pasted,
            hasValidRaw: true,
            hasAudio: true,
            statusCopy: "Complete"
        ),
        DictationTerminalPath(
            kind: .insertionDispatched,
            coordinatorState: .complete,
            sessionState: .completed,
            insertionOutcome: .dispatched,
            hasValidRaw: true,
            hasAudio: true,
            statusCopy: "Complete"
        ),
        DictationTerminalPath(
            kind: .insertionCopied,
            coordinatorState: .complete,
            sessionState: .completed,
            insertionOutcome: .copied,
            hasValidRaw: true,
            hasAudio: true,
            statusCopy: "Complete"
        ),
        DictationTerminalPath(
            kind: .insertionSecureRejected,
            coordinatorState: .complete,
            sessionState: .completed,
            insertionOutcome: .secureRejected,
            hasValidRaw: true,
            hasAudio: true,
            statusCopy: "Complete"
        ),
        DictationTerminalPath(
            kind: .insertionFailed,
            coordinatorState: .complete,
            sessionState: .completed,
            insertionOutcome: .failed,
            hasValidRaw: true,
            hasAudio: true,
            statusCopy: "Dictation completed; paste failed"
        ),
        DictationTerminalPath(
            kind: .cancelledBeforeRaw,
            coordinatorState: .cancelled,
            sessionState: .cancelled,
            insertionOutcome: nil,
            hasValidRaw: false,
            hasAudio: true,
            statusCopy: "Cancelled"
        ),
        DictationTerminalPath(
            kind: .cancelledAfterRaw,
            coordinatorState: .complete,
            sessionState: .completed,
            insertionOutcome: .failed,
            hasValidRaw: true,
            hasAudio: true,
            statusCopy: "Dictation completed; paste failed"
        ),
        DictationTerminalPath(
            kind: .interrupted,
            coordinatorState: .interrupted,
            sessionState: .interrupted,
            insertionOutcome: nil,
            hasValidRaw: false,
            hasAudio: true,
            statusCopy: "Interrupted"
        ),
        // Capture-time shutdown only. Shutdown after raw maps to cancelledAfterRaw.
        DictationTerminalPath(
            kind: .applicationShutdown,
            coordinatorState: .interrupted,
            sessionState: .interrupted,
            insertionOutcome: nil,
            hasValidRaw: false,
            hasAudio: true,
            statusCopy: "Interrupted"
        )
    ]
}

public enum OigoHUDPreviewPolicy {
    public static let maxCharacters = 200
    public static let maxLines = 2
    public static let maxUpdatesPerSecond = 5

    public static func bounded(_ text: String) -> String {
        let lines = text
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty }
        return String(lines.suffix(maxLines).joined(separator: "\n").prefix(maxCharacters))
    }
}

public struct OigoHUDPreviewThrottle: Sendable {
    public private(set) var lastPublication: TimeInterval?
    private let interval: TimeInterval

    public init(interval: TimeInterval = 1.0 / Double(OigoHUDPreviewPolicy.maxUpdatesPerSecond)) {
        lastPublication = nil
        self.interval = interval
    }

    public mutating func shouldPublish(at time: TimeInterval) -> Bool {
        guard let lastPublication else {
            self.lastPublication = time
            return true
        }
        guard time - lastPublication >= interval else {
            return false
        }
        self.lastPublication = time
        return true
    }
}

public struct OigoHUDResourceLedger: Equatable, Sendable {
    public private(set) var recordingTimerActive = false
    public private(set) var observationCount = 0

    public init() {}

    public var activeResourceCount: Int {
        (recordingTimerActive ? 1 : 0) + observationCount
    }

    public mutating func beginRecording() {
        recordingTimerActive = true
    }

    public mutating func endRecording() {
        recordingTimerActive = false
    }

    public mutating func beginObservation() {
        observationCount += 1
    }

    public mutating func endObservation() {
        observationCount = max(0, observationCount - 1)
    }

    public mutating func close() {
        recordingTimerActive = false
        observationCount = 0
    }
}
