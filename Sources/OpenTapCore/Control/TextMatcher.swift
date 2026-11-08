import Foundation

/// Owner: control. Finds the OCR result an agent means by `tap_text`.
public enum TextMatcher {
    public enum Kind: Int, Comparable, Sendable {
        case exact = 0, prefix = 1, contains = 2
        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// Lowercased, diacritics folded, whitespace collapsed, curly quotes straightened.
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Reading order: top-to-bottom by line (centres within ~half a line height are the same line), then left-to-right.
    public static func readingOrder(_ items: [RecognizedText]) -> [RecognizedText] {
        items.sorted { a, b in
            let tol = max(6, min(a.height, b.height) / 2)
            if abs(a.y - b.y) > tol { return a.y < b.y }
            return a.x < b.x
        }
    }

    /// All matches ranked exact > prefix > contains, each tier in reading order.
    public static func matches(_ query: String, in items: [RecognizedText]) -> [(item: RecognizedText, kind: Kind)] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }
        var out: [(RecognizedText, Kind)] = []
        for item in readingOrder(items) {
            let t = normalize(item.text)
            if t == q { out.append((item, .exact)) }
            else if t.hasPrefix(q) { out.append((item, .prefix)) }
            else if t.contains(q) { out.append((item, .contains)) }
        }
        // Stable sort by tier keeps reading order inside a tier.
        return out.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map { ($0.element.0, $0.element.1) }
    }

    /// The `occurrence`-th (1-based) best match, or nil.
    public static func find(_ query: String, in items: [RecognizedText], occurrence: Int = 1) -> RecognizedText? {
        guard occurrence >= 1 else { return nil }
        let m = matches(query, in: items)
        return occurrence <= m.count ? m[occurrence - 1].item : nil
    }

    /// The error for a miss, listing what *is* on screen so the agent can pick a real label.
    public static func notFoundError(_ query: String, occurrence: Int, in items: [RecognizedText]) -> OpenTapError {
        let total = matches(query, in: items).count
        let visible = readingOrder(items).map(\.text).filter { !$0.isEmpty }
        let sample = visible.prefix(25).map { "\"\($0)\"" }.joined(separator: ", ")
        if total > 0 {
            return OpenTapError(.textNotFound, what: "No occurrence \(occurrence) of \"\(query)\" on screen",
                                why: "Only \(total) match\(total == 1 ? "" : "es") of \"\(query)\" \(total == 1 ? "is" : "are") visible",
                                fix: "Use occurrence 1...\(total), or scroll to reveal more")
        }
        return OpenTapError(.textNotFound, what: "\"\(query)\" is not on screen",
                            why: visible.isEmpty ? "No text was recognized on the current screen"
                                                 : "Visible text: \(sample)\(visible.count > 25 ? ", ..." : "")",
                            fix: "Use one of the visible labels, scroll to reveal it, or tap by coordinates from the screenshot")
    }
}
