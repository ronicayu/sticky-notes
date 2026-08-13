import Foundation

/// One note that matched a query, with the score that ordered it and a short
/// excerpt explaining the hit.
struct NoteMatch: Equatable {
    let note: Note
    let score: Int
    /// What to show in the result row: the matching body line for a content
    /// hit, otherwise the title or the label that matched.
    let excerpt: String

    static func == (lhs: NoteMatch, rhs: NoteMatch) -> Bool {
        lhs.note.id == rhs.note.id && lhs.score == rhs.score && lhs.excerpt == rhs.excerpt
    }
}

/// Ranking for the quick switcher and the notes panel.
///
/// Titles and labels are matched fuzzily — they're short and deliberately
/// chosen, so a subsequence match is meaningful. Body text is matched by
/// substring only: a fuzzy subsequence search over a few kilobytes of prose
/// matches essentially any query, which buries the real hits.
enum NoteSearch {

    /// Score floors, so a title hit always outranks a label hit and a label hit
    /// always outranks a body hit regardless of how well each one scored.
    private enum Tier {
        static let title = 3000
        static let label = 2000
        static let body  = 1000
    }

    /// Rank `notes` against `query`, best first. An empty query returns
    /// everything ordered by recency. Notes that don't match are dropped.
    ///
    /// A query starting with `#` searches labels only, so `#work` narrows to
    /// tagged notes instead of also matching prose containing "work".
    static func rank(_ notes: [Note], query: String) -> [NoteMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return notes
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { NoteMatch(note: $0, score: 0, excerpt: summary(of: $0)) }
        }

        let matches = notes.compactMap { match($0, query: trimmed) }
        return matches.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.note.updatedAt > b.note.updatedAt
        }
    }

    /// Score a single note, or nil when it doesn't match at all.
    static func match(_ note: Note, query: String) -> NoteMatch? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return NoteMatch(note: note, score: 0, excerpt: summary(of: note)) }

        if trimmed.hasPrefix("#") {
            let bare = String(trimmed.dropFirst())
            guard !bare.isEmpty else { return NoteMatch(note: note, score: 0, excerpt: summary(of: note)) }
            return labelMatch(note, query: bare)
        }

        // Tiers are ordered by floor, so the first hit found is the best one —
        // no title match can lose to a label match, and no label match can
        // lose to a body match. Returning early also skips scanning the body,
        // which is by far the most expensive field.
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, let score = fuzzyScore(query: trimmed, in: title) {
            return NoteMatch(note: note, score: Tier.title + score, excerpt: title)
        }
        if let labelHit = labelMatch(note, query: trimmed) { return labelHit }
        return bodyMatch(note, query: trimmed)
    }

    // MARK: - Per-field matching

    private static func labelMatch(_ note: Note, query: String) -> NoteMatch? {
        var best: NoteMatch?
        for label in note.labels {
            guard let score = fuzzyScore(query: query, in: label) else { continue }
            if best == nil || Tier.label + score > best!.score {
                best = NoteMatch(note: note, score: Tier.label + score, excerpt: "#\(label)")
            }
        }
        return best
    }

    /// Search the body for `query` as a substring.
    ///
    /// Folding both sides and then doing an option-free search is ~6x faster
    /// than asking `range(of:options:)` to be case- and diacritic-insensitive,
    /// which drops into a much slower comparison path for the whole string.
    /// Folding never adds or removes newlines, so the line index of the hit
    /// carries back to the original text even if folding changed a character's
    /// width — which is all the excerpt needs.
    private static func bodyMatch(_ note: Note, query: String) -> NoteMatch? {
        let body = note.content
        guard !body.isEmpty else { return nil }
        let foldedBody = fold(body)
        guard let hit = foldedBody.range(of: fold(query)) else { return nil }

        var score = Tier.body
        // An earlier hit is a better hit, but only mildly — cap the influence
        // so a long note isn't punished for burying the match.
        let offset = foldedBody.distance(from: foldedBody.startIndex, to: hit.lowerBound)
        score += max(0, 60 - min(offset, 600) / 10)
        if startsWord(foldedBody, at: hit.lowerBound) { score += 40 }
        if hit.lowerBound == foldedBody.startIndex { score += 20 }

        let lineIndex = foldedBody[..<hit.lowerBound].reduce(into: 0) { count, c in
            if c == "\n" { count += 1 }
        }
        return NoteMatch(note: note, score: score, excerpt: line(at: lineIndex, in: body))
    }

    // MARK: - Fuzzy scoring

    /// Case- and diacritic-insensitive subsequence match with positional
    /// bonuses. Returns nil when `query` isn't a subsequence of `candidate`.
    ///
    /// Greedy left-to-right: not always the highest-scoring alignment, but
    /// it's linear and it never misses a match that exists.
    static func fuzzyScore(query: String, in candidate: String) -> Int? {
        let foldedQuery = fold(query)
        let foldedCandidate = fold(candidate)
        let needle = Array(foldedQuery)
        let hay = Array(foldedCandidate)
        guard !needle.isEmpty else { return 0 }
        guard needle.count <= hay.count else { return nil }

        var score = 0
        var hayIndex = 0
        var previousMatchIndex: Int?

        for character in needle {
            var found: Int?
            while hayIndex < hay.count {
                if hay[hayIndex] == character { found = hayIndex; break }
                hayIndex += 1
            }
            guard let matchIndex = found else { return nil }

            score += 10
            if matchIndex == 0 {
                score += 25
            } else if isSeparator(hay[matchIndex - 1]) {
                score += 20
            }
            if let previous = previousMatchIndex, matchIndex == previous + 1 {
                score += 15
            }
            previousMatchIndex = matchIndex
            hayIndex += 1
        }

        // A contiguous run is what the user usually means; reward it outright
        // so "note" beats a scattered n-o-t-e across a longer string.
        if foldedCandidate.contains(foldedQuery) {
            score += 60
            if foldedCandidate.hasPrefix(foldedQuery) { score += 40 }
        }

        // Prefer the shorter of two otherwise equal candidates.
        score -= min(hay.count / 4, 40)
        return score
    }

    // MARK: - Excerpts

    /// First non-empty line of a note, for rows with no query to highlight.
    static func summary(of note: Note) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let body = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "" }
        let first = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
        return String(first.prefix(200))
    }

    private static func line(at index: Int, in text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard index >= 0, index < lines.count else { return summaryLine(of: text) }
        let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return String(line.prefix(200))
    }

    private static func summaryLine(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return String(first.prefix(200))
    }

    // MARK: - Character helpers

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isSeparator(_ c: Character) -> Bool {
        c == " " || c == "-" || c == "_" || c == "/" || c == "." || c == "#" || c == "\n" || c == "\t"
    }

    private static func startsWord(_ text: String, at index: String.Index) -> Bool {
        guard index != text.startIndex else { return true }
        let before = text[text.index(before: index)]
        return !before.isLetter && !before.isNumber
    }
}
