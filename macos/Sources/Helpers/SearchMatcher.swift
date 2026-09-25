import Foundation

/// The single search/filter used across every filterable list — host search
/// palette, hosts dashboard, saved sessions, snippets, port forwards, SFTP.
///
/// Normalization lives in ONE place so a forgotten `.lowercased()` can't make
/// one list case-sensitive while another isn't. The query is split on
/// whitespace and EVERY token must appear (case-insensitively) in at least one
/// field, so multi-word queries like "loc 2222" match "Local SSH 2222".
enum SearchMatcher {
    /// Returns a relevance score for a fuzzy match. Every whitespace-separated
    /// query token must match at least one field; a token may match by exact
    /// text, prefix, substring, or ordered character subsequence. Larger
    /// `weight` values make a field more important to the result order.
    static func rank(_ query: String, in fields: [(value: String, weight: Int)]) -> Int? {
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { compact(String($0)) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return 0 }

        var total = 0
        for token in tokens {
            var best: Int?
            for field in fields where !field.value.isEmpty {
                guard let fieldScore = score(token, against: field.value) else { continue }
                let weighted = fieldScore * field.weight
                best = max(best ?? weighted, weighted)
            }
            guard let best else { return nil }
            total += best
        }
        return total
    }

    /// True when `query` matches the given fields. An empty/whitespace query
    /// matches everything (no filtering).
    static func matches(_ query: String, in fields: [String]) -> Bool {
        let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return true }
        let haystacks = fields.map { $0.lowercased() }
        return tokens.allSatisfy { token in
            haystacks.contains { $0.contains(token) }
        }
    }

    /// Convenience for the common `items.filter { … }` shape.
    static func filter<T>(_ items: [T], query: String, fields: (T) -> [String]) -> [T] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.filter { matches(trimmed, in: fields($0)) }
    }

    // MARK: - Fuzzy scoring

    /// Scores one compact query token against one field. The broad score bands
    /// preserve the intended ordering: exact > prefix > substring > fuzzy.
    private static func score(_ query: String, against field: String) -> Int? {
        let candidate = compact(field)
        guard !candidate.isEmpty else { return nil }
        if candidate == query { return 10_000 }
        if candidate.hasPrefix(query) { return 8_000 + min(query.count, 50) }
        if candidate.contains(query) { return 6_000 + min(query.count, 50) }

        let queryChars = Array(query)
        let candidateChars = Array(candidate)
        var positions: [Int] = []
        var cursor = 0
        for character in queryChars {
            guard let offset = candidateChars[cursor...].firstIndex(of: character) else { return nil }
            positions.append(offset)
            cursor = offset + 1
        }

        guard let first = positions.first, let last = positions.last else { return nil }
        let span = last - first + 1
        let gaps = max(0, span - queryChars.count)
        // A compact match with fewer skipped characters ranks higher. The
        // length term makes short, focused matches beat very spread-out ones.
        return 3_000 + max(0, 1_000 - gaps * 120) + min(queryChars.count, 50)
    }

    /// Case/diacritic-insensitive text with separators removed. Removing
    /// separators makes `hpa` match `hc-prod-api` and `jh` match `JumpHost`.
    private static func compact(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
