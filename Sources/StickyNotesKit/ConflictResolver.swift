import Foundation

/// Merges the versions iCloud Drive produces when the same note is edited on
/// two Macs before they sync.
///
/// The rule is simple and deliberately dumb: never discard text. The newest
/// version wins the metadata and the top of the file, and every losing
/// version's body is appended below a divider. A merge that guesses wrong
/// leaves the user with a tidy note missing a paragraph they wrote; this
/// leaves them with a messy note they can fix in ten seconds.
enum ConflictResolver {

    /// Merge `versions` (the current file plus its conflict copies) into one
    /// note. Returns nil when there's nothing to merge. When the text is the
    /// same, the newest version is returned as it is, title included; when a
    /// merge does change the note, any title it loses is kept as an "Also titled"
    /// line at the end.
    ///
    /// Versions are compared by line, not as one string. An older copy of the
    /// user's own text stops being a substring of the newer one after a single
    /// backspace, yet it still adds nothing: a version whose lines the winner
    /// already has is dropped, and a version that holds every line of the
    /// winner and more replaces it as the base, as does a version with text when
    /// the winner is blank. Only versions with lines on both sides that the other
    /// lacks are appended.
    static func merge(_ versions: [Note], now: Date = Date()) -> Note? {
        guard let winner = versions.max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        guard versions.count > 1 else { return winner }

        let winningBody = normalize(winner.content)
        // Oldest first, so the appended sections read chronologically.
        var candidates: [(body: String, date: Date)] = []
        var seen: Set<String> = [winningBody]
        for version in versions.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            let body = normalize(version.content)
            guard !body.isEmpty, !seen.contains(body) else { continue }
            seen.insert(body)
            candidates.append((body, version.updatedAt))
        }

        var base = winner.content
        for candidate in candidates
        where !isCovered(candidate.body, by: base) && (isSuperset(candidate.body, of: base) || isBlank(base)) {
            base = candidate.body
        }

        let appended = candidates
            .filter { !isCovered($0.body, by: base) }
            .map { "\(divider(for: $0.date, now: now))\n\n\($0.body)" }

        // Labels are additive: losing a tag in a merge is silent data loss too.
        let labels = mergedLabels(versions)
        guard base != winner.content || !appended.isEmpty || labels != winner.labels else { return winner }
        var merged = winner
        var sections = [base] + appended
        // A title is text the person typed. The winner keeps its own; one that
        // has none takes the first other title, and the rest stay in the note.
        var otherTitles: [String] = []
        for version in versions.sorted(by: { $0.updatedAt > $1.updatedAt })
        where !version.title.isEmpty && version.title != winner.title && !otherTitles.contains(version.title) {
            otherTitles.append(version.title)
        }
        if merged.title.isEmpty, !otherTitles.isEmpty { merged.title = otherTitles.removeFirst() }
        if !otherTitles.isEmpty { sections.append("Also titled: " + otherTitles.joined(separator: ", ")) }
        merged.content = sections.joined(separator: "\n\n")
        merged.updatedAt = now
        merged.labels = labels
        return merged
    }

    /// Merge two versions of one file's body: the buffer the user has been
    /// typing into, and an external write that landed while they typed. Same
    /// rule as `merge` — the local text keeps the top, and anything the
    /// external version adds is appended below a divider rather than lost.
    static func mergeBodies(
        local: String,
        external: String,
        externalDate: Date,
        now: Date = Date()
    ) -> String {
        let localBody = normalize(local)
        let externalBody = normalize(external)
        guard !externalBody.isEmpty, externalBody != localBody else { return local }
        if localBody.isEmpty { return external }
        if isCovered(externalBody, by: localBody) { return local }
        if isSuperset(externalBody, of: localBody) { return external }
        return "\(local)\n\n\(divider(for: externalDate, now: now))\n\n\(external)"
    }

    /// What this Mac knows of its own writes to one file, for `versionsToMerge`.
    struct OwnWrites {
        /// The note is exactly one of the writes (body, title and labels).
        var isOurs: (Note) -> Bool
        /// The note is exactly the newest write.
        var isNewest: (Note) -> Bool
        /// The text of the newest write, when it was kept.
        var newestBody: String?
    }

    /// When the file is an earlier write of ours that was put back (an older copy
    /// that Obsidian or a sync wrote over our newest save), our newest text is
    /// what the merge treats as the current file, so that our other earlier saves
    /// are dropped against it and it, not the stale copy, is written back. Every
    /// line of the stale copy is in the newest write or was taken out by the
    /// person, so nothing is lost. Otherwise `current` as it is.
    static func standingInForStaleFile(
        _ current: Note, newestBody: String?,
        isEarlierBody: (String) -> Bool, isNewestBody: (String) -> Bool
    ) -> Note {
        guard let newestBody, !isNewestBody(current.content), isEarlierBody(current.content) else { return current }
        var judged = current
        judged.content = newestBody
        return judged
    }

    /// The notes worth merging: the current file plus its conflict versions,
    /// minus the ones that are an earlier save of this Mac's own writing.
    ///
    /// A conflict version is dropped when it is one of our writes but not the
    /// newest, and the newest is still in the merge: the file covers its text
    /// (an outside append or a property rewrite after our last save does not stop
    /// that), or it is itself one of the versions. An earlier write holds only
    /// text that the newest has or that the person took out in between, so it
    /// adds nothing. When nothing shows that the newest survives, every version
    /// is kept, because an earlier write may then hold the only copy of a line.
    /// A version that is not one of our writes, and the newest write itself, are
    /// never dropped.
    static func versionsToMerge(current: Note, conflicts: [Note], ours: OwnWrites) -> [Note] {
        let newestSurvives = ours.isNewest(current)
            || ours.newestBody.map { isCovered($0, by: current.content) } == true
            || conflicts.contains(where: ours.isNewest)
        guard newestSurvives else { return [current] + conflicts }
        return [current] + conflicts.filter { ours.isNewest($0) || !ours.isOurs($0) }
    }

    static func normalizedBody(_ body: String) -> String { normalize(body) }

    /// True when these versions actually disagree about anything worth
    /// merging. Identical copies are common — iCloud produces a conflict from
    /// two saves that happened to write the same text.
    static func needsMerge(_ versions: [Note]) -> Bool {
        guard versions.count > 1 else { return false }
        let bodies = Set(versions.map { normalize($0.content) })
        if bodies.count > 1 { return true }
        return Set(versions.map { Set($0.labels) }).count > 1
    }

    private static func mergedLabels(_ versions: [Note]) -> [String] {
        var seen: [String] = []
        for version in versions {
            for label in version.labels where !seen.contains(label) {
                seen.append(label)
            }
        }
        return seen
    }

    private static func divider(for date: Date, now: Date) -> String {
        "\n---\n\n*Conflicted copy from \(dividerFormatter.string(from: date))*"
    }

    /// Non-empty lines with trailing whitespace removed.
    private static func lines(of body: String) -> [String] {
        body.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = Substring(raw)
            while let last = line.last, last.isWhitespace { line.removeLast() }
            return line.isEmpty ? nil : String(line)
        }
    }

    /// True when `body` adds nothing to `base`: each of its lines uses up one
    /// matching line of `base`, so a repeated line still counts. The last line
    /// may instead use up a base line it is a prefix of, because an older save
    /// is often cut mid-word.
    static func isCovered(_ body: String, by base: String) -> Bool {
        var available: [String: Int] = [:]
        for line in lines(of: base) { available[line, default: 0] += 1 }
        let bodyLines = lines(of: body)
        for (index, line) in bodyLines.enumerated() {
            if let count = available[line], count > 0 {
                available[line] = count - 1
                continue
            }
            let isLast = index == bodyLines.count - 1
            guard isLast,
                  let match = available.first(where: { $0.value > 0 && $0.key.hasPrefix(line) })
            else { return false }
            available[match.key] = match.value - 1
        }
        return true
    }

    /// True when `body` can replace `base` without undoing anything the user
    /// did: `base` has text, and its lines all appear in `body` in the same
    /// order, repeats counted. An outside append qualifies; a deletion, a
    /// reorder or a cleared note does not.
    private static func isSuperset(_ body: String, of base: String) -> Bool {
        let baseLines = lines(of: base)
        guard !baseLines.isEmpty else { return false }
        var next = baseLines.startIndex
        for line in lines(of: body) where next < baseLines.endIndex && line == baseLines[next] {
            next += 1
        }
        return next == baseLines.endIndex
    }

    private static func isBlank(_ body: String) -> Bool { lines(of: body).isEmpty }

    private static func normalize(_ body: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let dividerFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
