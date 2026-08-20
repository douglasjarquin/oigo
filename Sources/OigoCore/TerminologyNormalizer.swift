import Foundation

public struct TerminologyNormalizer: Sendable {
    private let phrasesByFirstCharacter: [Character: [CompiledPhrase]]
    private let shortestAliasCount: Int

    public init(snapshot: CompiledDictionarySnapshot) {
        var grouped: [Character: [CompiledPhrase]] = [:]
        var shortest = Int.max
        for phrase in snapshot.phrases where !phrase.alias.isEmpty {
            let first = phrase.alias.lowercased().first ?? phrase.alias.first!
            grouped[first, default: []].append(phrase)
            shortest = min(shortest, phrase.alias.count)
        }
        for key in grouped.keys {
            grouped[key]?.sort { lhs, rhs in
                if lhs.alias.count != rhs.alias.count {
                    return lhs.alias.count > rhs.alias.count
                }
                return lhs.alias < rhs.alias
            }
        }
        phrasesByFirstCharacter = grouped
        shortestAliasCount = shortest == Int.max ? 0 : shortest
    }

    public func normalize(_ text: String) -> String {
        guard shortestAliasCount > 0, !text.isEmpty else {
            return text
        }
        let protected = Self.protectedSpans(in: text)
        var output = String()
        output.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            if let span = protected.first(where: { $0.contains(index) }) {
                output.append(contentsOf: text[index..<span.upperBound])
                index = span.upperBound
                continue
            }
            if Self.isTokenStart(index, in: text),
               let replacement = match(in: text, at: index, protected: protected) {
                output.append(contentsOf: replacement.canonical)
                index = replacement.end
                continue
            }
            output.append(text[index])
            index = text.index(after: index)
        }
        return output
    }

    public static func protectedSpans(in text: String) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = []
        spans.append(contentsOf: fencedCodeSpans(in: text))
        spans.append(contentsOf: inlineCodeSpans(in: text, excluding: spans))
        spans.append(contentsOf: linkSpans(in: text))
        spans.append(contentsOf: pathSpans(in: text, excluding: spans))
        return merge(spans)
    }

    private func match(
        in text: String,
        at start: String.Index,
        protected: [Range<String.Index>]
    ) -> (canonical: String, end: String.Index)? {
        let first = text[start].lowercased().first ?? text[start]
        guard let phrases = phrasesByFirstCharacter[first] else {
            return nil
        }
        for phrase in phrases {
            guard let end = text.index(start, offsetBy: phrase.alias.count, limitedBy: text.endIndex) else {
                continue
            }
            let range = start..<end
            if protected.contains(where: { overlaps($0, range) }) {
                continue
            }
            guard text[range].compare(phrase.alias, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame,
                  Self.isTokenEnd(end, in: text) else {
                continue
            }
            return (phrase.canonical, end)
        }
        return nil
    }

    private static func isTokenStart(_ index: String.Index, in text: String) -> Bool {
        if index == text.startIndex {
            return true
        }
        return !isIdentifier(text[text.index(before: index)])
    }

    private static func isTokenEnd(_ index: String.Index, in text: String) -> Bool {
        if index == text.endIndex {
            return true
        }
        let character = text[index]
        if isApostrophe(character) {
            return true
        }
        return !isIdentifier(character)
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "\u{2019}"
    }

    private static func fencedCodeSpans(in text: String) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = []
        var search = text.startIndex
        while let open = text.range(of: "```", range: search..<text.endIndex) {
            if let close = text.range(of: "```", range: open.upperBound..<text.endIndex) {
                spans.append(open.lowerBound..<close.upperBound)
                search = close.upperBound
            } else {
                break
            }
        }
        return spans
    }

    private static func inlineCodeSpans(
        in text: String,
        excluding protected: [Range<String.Index>]
    ) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = []
        var search = text.startIndex
        while search < text.endIndex, let open = text.range(of: "`", range: search..<text.endIndex) {
            if protected.contains(where: { $0.contains(open.lowerBound) }) {
                search = open.upperBound
                continue
            }
            if let close = text.range(of: "`", range: open.upperBound..<text.endIndex),
               !protected.contains(where: { $0.contains(close.lowerBound) }) {
                spans.append(open.lowerBound..<close.upperBound)
                search = close.upperBound
            } else {
                break
            }
        }
        return spans
    }

    private static func linkSpans(in text: String) -> [Range<String.Index>] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: nsRange).compactMap { match in
            Range(match.range, in: text)
        }
    }

    private static func pathSpans(
        in text: String,
        excluding protected: [Range<String.Index>]
    ) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            if protected.contains(where: { $0.contains(index) }) {
                index = text.index(after: index)
                continue
            }
            if isTokenStart(index, in: text), isPathPrefix(at: index, in: text) {
                let end = consumePath(from: index, in: text)
                if end > index {
                    spans.append(index..<end)
                    index = end
                    continue
                }
            }
            index = text.index(after: index)
        }
        return spans
    }

    private static func isPathPrefix(at index: String.Index, in text: String) -> Bool {
        if text[index] == "/" {
            return true
        }
        let remainder = text[index...]
        return remainder.hasPrefix("~/")
            || remainder.hasPrefix("./")
            || remainder.hasPrefix("../")
    }

    private static func consumePath(from start: String.Index, in text: String) -> String.Index {
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace
                || character == "\""
                || character == "'"
                || character == "<"
                || character == ">"
                || character == ","
                || character == ";"
                || character == ")"
                || character == "]" {
                break
            }
            index = text.index(after: index)
        }
        return index
    }

    private static func merge(_ spans: [Range<String.Index>]) -> [Range<String.Index>] {
        let ordered = spans.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for span in ordered {
            if let last = merged.last, last.upperBound >= span.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private func overlaps(_ lhs: Range<String.Index>, _ rhs: Range<String.Index>) -> Bool {
        lhs.overlaps(rhs)
    }
}
