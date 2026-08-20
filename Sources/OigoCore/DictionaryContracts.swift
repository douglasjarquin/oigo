import Foundation

public struct DictionaryEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var canonical: String
    public var aliases: [String]
    public var localeIdentifier: String?
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        canonical: String,
        aliases: [String],
        localeIdentifier: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.canonical = canonical
        self.aliases = aliases
        self.localeIdentifier = localeIdentifier
        self.isEnabled = isEnabled
    }
}

public struct DictionaryDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let empty = DictionaryDocument(
        schemaVersion: currentSchemaVersion,
        entries: []
    )

    public var schemaVersion: Int
    public var entries: [DictionaryEntry]

    public init(schemaVersion: Int = DictionaryDocument.currentSchemaVersion, entries: [DictionaryEntry]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
}

public struct CompiledPhrase: Equatable, Sendable {
    public let alias: String
    public let canonical: String

    public init(alias: String, canonical: String) {
        self.alias = alias
        self.canonical = canonical
    }
}

public struct CompiledDictionarySnapshot: Equatable, Sendable {
    public static let empty = CompiledDictionarySnapshot(
        revision: "empty",
        localeIdentifier: nil,
        canonicalTerms: [],
        phrases: []
    )

    public let revision: String
    public let localeIdentifier: String?
    public let canonicalTerms: [String]
    public let phrases: [CompiledPhrase]

    public init(
        revision: String,
        localeIdentifier: String?,
        canonicalTerms: [String],
        phrases: [CompiledPhrase]
    ) {
        self.revision = revision
        self.localeIdentifier = localeIdentifier
        self.canonicalTerms = canonicalTerms
        self.phrases = phrases
    }
}

public struct DictionaryLoadResult: Equatable, Sendable {
    public let document: DictionaryDocument
    public let snapshot: CompiledDictionarySnapshot
    public let error: DictionaryStoreError?

    public init(
        document: DictionaryDocument,
        snapshot: CompiledDictionarySnapshot,
        error: DictionaryStoreError? = nil
    ) {
        self.document = document
        self.snapshot = snapshot
        self.error = error
    }
}

public enum DictionaryStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyCanonical
    case emptyAlias
    case duplicateAliasInEntry
    case conflictingAlias(String)
    case unsupportedVersion
    case malformed
    case tooLarge
    case notRegularFile
    case symlinkRejected
    case writeFailed

    public var description: String {
        userMessage
    }

    public var userMessage: String {
        switch self {
        case .emptyCanonical:
            "Canonical spelling cannot be empty."
        case .emptyAlias:
            "Aliases cannot be empty."
        case .duplicateAliasInEntry:
            "An entry cannot list the same alias more than once."
        case .conflictingAlias(let alias):
            "The alias “" + alias + "” maps to more than one enabled canonical spelling for the same locale."
        case .unsupportedVersion:
            "The custom dictionary file uses an unsupported schema version. Oigo is using an empty dictionary and left the original file unchanged."
        case .malformed:
            "The custom dictionary file is unreadable. Oigo is using an empty dictionary and left the original file unchanged."
        case .tooLarge:
            "The custom dictionary file is too large to load safely. Oigo is using an empty dictionary and left the original file unchanged."
        case .notRegularFile:
            "The custom dictionary path is not a regular file. Oigo is using an empty dictionary and left the original file unchanged."
        case .symlinkRejected:
            "The custom dictionary path is a symbolic link. Oigo will not follow it."
        case .writeFailed:
            "The custom dictionary could not be saved."
        }
    }
}

public enum DictionaryStarterTerms {
    public static let technology: [DictionaryEntry] = [
        DictionaryEntry(
            canonical: "ChatGPT",
            aliases: ["chat gpt", "chat G P T", "chagpt", "Chad GPT"]
        ),
        DictionaryEntry(
            canonical: "Claude Code",
            aliases: ["clawed code", "cloud code"]
        ),
        DictionaryEntry(
            canonical: "n8n",
            aliases: ["n eight n", "n 8 n", "nate n"]
        )
    ]
}

public enum DictionaryCompiler {
    public static func validate(_ entries: [DictionaryEntry]) throws {
        for entry in entries {
            try validate(entry: entry)
        }
        try validateConflicts(entries)
    }

    public static func compile(
        _ entries: [DictionaryEntry],
        localeIdentifier: String?
    ) throws -> CompiledDictionarySnapshot {
        try validate(entries)
        let applicable = entries.filter { applies($0, localeIdentifier: localeIdentifier) }
        var phrases: [CompiledPhrase] = []
        var canonicalTerms: [String] = []
        var seenCanonical: Set<String> = []
        for entry in applicable {
            if seenCanonical.insert(entry.canonical).inserted {
                canonicalTerms.append(entry.canonical)
            }
            phrases.append(CompiledPhrase(alias: entry.canonical, canonical: entry.canonical))
            for alias in entry.aliases {
                phrases.append(CompiledPhrase(alias: alias, canonical: entry.canonical))
            }
        }
        phrases.sort { lhs, rhs in
            if lhs.alias.count != rhs.alias.count {
                return lhs.alias.count > rhs.alias.count
            }
            if lhs.alias != rhs.alias {
                return lhs.alias < rhs.alias
            }
            return lhs.canonical < rhs.canonical
        }
        return CompiledDictionarySnapshot(
            revision: revision(for: phrases, localeIdentifier: localeIdentifier),
            localeIdentifier: localeIdentifier,
            canonicalTerms: canonicalTerms,
            phrases: phrases
        )
    }

    public static func applies(_ entry: DictionaryEntry, localeIdentifier: String?) -> Bool {
        guard entry.isEnabled else {
            return false
        }
        guard let entryLocale = entry.localeIdentifier, !entryLocale.isEmpty else {
            return true
        }
        return entryLocale == localeIdentifier
    }

    private static func validate(entry: DictionaryEntry) throws {
        let canonical = entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else {
            throw DictionaryStoreError.emptyCanonical
        }
        var folded: Set<String> = [fold(canonical)]
        for alias in entry.aliases {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DictionaryStoreError.emptyAlias
            }
            let key = fold(trimmed)
            if folded.contains(key) {
                throw DictionaryStoreError.duplicateAliasInEntry
            }
            folded.insert(key)
        }
    }

    private static func validateConflicts(_ entries: [DictionaryEntry]) throws {
        let enabled = entries.filter(\.isEnabled)
        let locales = Set(enabled.compactMap(\.localeIdentifier).filter { !$0.isEmpty })
        try validateConflictSet(enabled.filter { $0.localeIdentifier == nil || $0.localeIdentifier?.isEmpty == true })
        for locale in locales {
            try validateConflictSet(enabled.filter { applies($0, localeIdentifier: locale) })
        }
    }

    private static func validateConflictSet(_ entries: [DictionaryEntry]) throws {
        var owner: [String: String] = [:]
        for entry in entries {
            var aliases = entry.aliases
            aliases.append(entry.canonical)
            for alias in aliases {
                let key = fold(alias.trimmingCharacters(in: .whitespacesAndNewlines))
                if let existing = owner[key], existing != entry.canonical {
                    throw DictionaryStoreError.conflictingAlias(alias.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                owner[key] = entry.canonical
            }
        }
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    private static func revision(for phrases: [CompiledPhrase], localeIdentifier: String?) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
        }
        mix(localeIdentifier ?? "")
        mix("\n")
        for phrase in phrases {
            mix(phrase.canonical)
            mix("\t")
            mix(phrase.alias)
            mix("\n")
        }
        return String(hash, radix: 16)
    }
}
