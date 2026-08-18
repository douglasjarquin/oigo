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

public final class OigoSettingsStore {
    private static let key = "oigo.settings.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> OigoSettings {
        if let data = defaults.data(forKey: Self.key),
           let settings = try? JSONDecoder().decode(OigoSettings.self, from: data) {
            return settings
        }

        var settings = OigoSettings.default
        if let data = defaults.data(forKey: "globalToggleShortcut"),
           let shortcut = try? JSONDecoder().decode(ToggleShortcut.self, from: data) {
            settings.globalShortcut = shortcut
        }
        if let rawMode = defaults.string(forKey: "transcriptCleanupMode"),
           let mode = OigoProcessingMode(rawValue: rawMode) {
            settings.defaultMode = mode
        }
        return settings
    }

    public func save(_ settings: OigoSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }
        defaults.set(data, forKey: Self.key)
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

public enum OigoShortcutValidator {
    public static func validate(
        _ shortcut: ToggleShortcut,
        occupied: [ToggleShortcut]
    ) -> OigoShortcutValidation {
        guard shortcut.keyCode > 0 else {
            return .invalid("Choose a keyboard key for the global shortcut")
        }
        guard shortcut.modifiers != 0 else {
            return .invalid("Choose at least one modifier for the global shortcut")
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
    case pasted = "Pasted"
    case copied = "Copied"
    case failed = "Failed"
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
