import Foundation

public enum OigoLocaleSelectionRole: Equatable, Sendable {
    case onboarding
    case settings
}

public enum OigoLocaleAssetStatus: Equatable, Sendable {
    case idle
    case checking
    case installing
    case ready
    case failed(String)
    case unavailable(String)
    case unsupported

    public var isReady: Bool {
        self == .ready
    }
}

public struct OigoLocaleAssetReadiness: Equatable, Sendable {
    public let localeIdentifier: String
    public let generation: UInt64
    public let status: OigoLocaleAssetStatus

    public init(
        localeIdentifier: String,
        generation: UInt64,
        status: OigoLocaleAssetStatus
    ) {
        self.localeIdentifier = localeIdentifier
        self.generation = generation
        self.status = status
    }

    public var isReady: Bool {
        status.isReady
    }
}

public struct OigoLocaleMenuItem: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let isUnavailable: Bool

    public init(
        identifier: String,
        title: String,
        isUnavailable: Bool = false
    ) {
        self.identifier = identifier
        self.title = title
        self.isUnavailable = isUnavailable
    }
}

public enum OigoLocalePresentation {
    public static func displayName(
        for identifier: String,
        displayLocale: Locale = .current
    ) -> String {
        let locale = Locale(identifier: identifier)
        let languageCode = locale.language.languageCode?.identifier
        let languageName = languageCode.flatMap { displayLocale.localizedString(forLanguageCode: $0) }
        let regionCode = locale.region?.identifier
        let regionName = regionCode.flatMap { displayLocale.localizedString(forRegionCode: $0) }
        switch (languageName, regionName) {
        case let (language?, region?) where !region.isEmpty:
            return language + " (" + region + ")"
        case let (language?, _):
            return language
        default:
            return identifier
        }
    }
}

public enum OigoLocaleMenu {
    public static func items(
        supportedIdentifiers: [String],
        committedIdentifier: String,
        role: OigoLocaleSelectionRole,
        displayLocale: Locale = .current
    ) -> [OigoLocaleMenuItem] {
        var items = supportedIdentifiers.map { identifier in
            OigoLocaleMenuItem(
                identifier: identifier,
                title: OigoLocalePresentation.displayName(
                    for: identifier,
                    displayLocale: displayLocale
                )
            )
        }
        let committedIsSupported = supportedIdentifiers.contains {
            $0.caseInsensitiveCompare(committedIdentifier) == .orderedSame
        }
        if role == .settings,
           !committedIdentifier.isEmpty,
           !committedIsSupported {
            let name = OigoLocalePresentation.displayName(
                for: committedIdentifier,
                displayLocale: displayLocale
            )
            items.insert(
                OigoLocaleMenuItem(
                    identifier: committedIdentifier,
                    title: name + " - unavailable",
                    isUnavailable: true
                ),
                at: 0
            )
        }
        return items
    }
}

public struct OigoLocaleSelectionState: Equatable, Sendable {
    public let role: OigoLocaleSelectionRole
    public private(set) var committedIdentifier: String
    public private(set) var selectedIdentifier: String?
    public private(set) var generation: UInt64
    public private(set) var readiness: OigoLocaleAssetReadiness
    public private(set) var menuItems: [OigoLocaleMenuItem]
    public private(set) var supportedIdentifiers: [String]
    public private(set) var hasLoadedSupported: Bool

    private var displayLocale: Locale
    private var preferredIdentifier: String

    public init(
        committedIdentifier: String,
        role: OigoLocaleSelectionRole,
        preferredIdentifier: String? = nil,
        displayLocale: Locale = .current
    ) {
        self.role = role
        self.committedIdentifier = committedIdentifier
        self.preferredIdentifier = preferredIdentifier ?? committedIdentifier
        self.displayLocale = displayLocale
        selectedIdentifier = committedIdentifier.isEmpty ? nil : committedIdentifier
        generation = 0
        readiness = OigoLocaleAssetReadiness(
            localeIdentifier: committedIdentifier,
            generation: 0,
            status: .idle
        )
        menuItems = []
        supportedIdentifiers = []
        hasLoadedSupported = false
    }

    public var canConfirm: Bool {
        guard let selectedIdentifier else {
            return false
        }
        return readiness.localeIdentifier == selectedIdentifier
            && readiness.generation == generation
            && readiness.status.isReady
    }

    public var selectedItemIsUnavailable: Bool {
        guard let selectedIdentifier else {
            return false
        }
        return menuItems.contains {
            $0.identifier == selectedIdentifier && $0.isUnavailable
        }
    }

    public var requiresVerificationToCommit: Bool {
        guard let selectedIdentifier else {
            return false
        }
        return selectedIdentifier != committedIdentifier && !selectedItemIsUnavailable
    }

    public var statusMessage: String {
        if !hasLoadedSupported {
            return ""
        }
        if supportedIdentifiers.isEmpty, menuItems.isEmpty {
            return "No supported speech locales were found. The previous language is unchanged."
        }
        if selectedItemIsUnavailable {
            return "The saved dictation language is unavailable. Choose another supported language to change it."
        }
        switch readiness.status {
        case .idle:
            return selectedIdentifier == nil
                ? "Choose a supported speech language first."
                : "Speech assets: not verified for the selected language."
        case .checking:
            return "Speech assets: checking…"
        case .installing:
            return "Speech assets: installing…"
        case .ready:
            return "Speech assets: ready"
        case .failed(let reason):
            return "Speech assets: failed: " + reason
        case .unavailable(let reason):
            return "Speech assets: unavailable: " + reason
        case .unsupported:
            return "Speech assets: unsupported for the selected language."
        }
    }

    public mutating func loadSupported(_ identifiers: [String]) {
        hasLoadedSupported = true
        supportedIdentifiers = identifiers
        menuItems = OigoLocaleMenu.items(
            supportedIdentifiers: identifiers,
            committedIdentifier: committedIdentifier,
            role: role,
            displayLocale: displayLocale
        )
        let nextSelection = preselectedIdentifier(from: identifiers)
        replaceSelection(nextSelection, incrementGeneration: selectedIdentifier != nextSelection || generation == 0)
    }

    public mutating func select(_ identifier: String) {
        guard identifier != selectedIdentifier else {
            return
        }
        replaceSelection(identifier, incrementGeneration: true)
    }

    public mutating func beginAssetRequest(
        status: OigoLocaleAssetStatus = .checking
    ) -> OigoLocaleAssetReadiness? {
        guard let selectedIdentifier, !selectedItemIsUnavailable else {
            return nil
        }
        generation += 1
        readiness = OigoLocaleAssetReadiness(
            localeIdentifier: selectedIdentifier,
            generation: generation,
            status: status
        )
        return readiness
    }

    @discardableResult
    public mutating func applyAssetResult(
        localeIdentifier: String,
        generation: UInt64,
        status: OigoLocaleAssetStatus
    ) -> Bool {
        guard selectedIdentifier == localeIdentifier,
              self.generation == generation else {
            return false
        }
        readiness = OigoLocaleAssetReadiness(
            localeIdentifier: localeIdentifier,
            generation: generation,
            status: status
        )
        return true
    }

    public mutating func confirm() -> String? {
        guard canConfirm, let selectedIdentifier else {
            return nil
        }
        committedIdentifier = selectedIdentifier
        return selectedIdentifier
    }

    public mutating func revalidate() {
        generation += 1
        readiness = OigoLocaleAssetReadiness(
            localeIdentifier: selectedIdentifier ?? committedIdentifier,
            generation: generation,
            status: .idle
        )
    }

    public mutating func abandonUncommitted() {
        replaceSelection(
            committedIdentifier.isEmpty ? nil : committedIdentifier,
            incrementGeneration: true
        )
    }

    private mutating func replaceSelection(
        _ identifier: String?,
        incrementGeneration: Bool
    ) {
        selectedIdentifier = identifier
        if incrementGeneration {
            generation += 1
        }
        readiness = OigoLocaleAssetReadiness(
            localeIdentifier: identifier ?? committedIdentifier,
            generation: generation,
            status: .idle
        )
    }

    private func preselectedIdentifier(from identifiers: [String]) -> String? {
        if let match = identifiers.first(where: {
            $0.caseInsensitiveCompare(committedIdentifier) == .orderedSame
        }) {
            return match
        }
        switch role {
        case .onboarding:
            return OigoSupportedLocaleResolver.closest(
                to: preferredIdentifier.isEmpty ? Locale.current.identifier : preferredIdentifier,
                among: identifiers
            ) ?? identifiers.first
        case .settings:
            if !committedIdentifier.isEmpty {
                return committedIdentifier
            }
            return identifiers.first
        }
    }
}
