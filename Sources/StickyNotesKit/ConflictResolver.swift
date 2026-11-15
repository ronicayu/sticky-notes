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
    /// note. Returns nil when there's nothing to merge.
    ///
    /// Versions are compared by line, not as one string. An older copy of the
    /// user's own text stops being a substring of the newer one after a single
    /// backspace, yet it still adds nothing: a version whose lines the winner
    /// already has is dropped, and a version that holds every line of the
    /// winner and more replaces it as the base. Only versions with lines on
    /// both sides that the other lacks are appended.
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
        where !isCovered(candidate.body, by: base) && isSuperset(candidate.body, of: base) {
            base = candidate.body
        }

        let appended = candidates
            .filter { !isCovered($0.body, by: base) }
            .map { "\(divider(for: $0.date, now: now))\n\n\($0.body)" }

        guard base != winner.content || !appended.isEmpty else { return winner }
        var merged = winner
        merged.content = ([base] + appended).joined(separator: "\n\n")
        merged.updatedAt = now
        // Labels are additive: losing a tag in a merge is silent data loss too.
        merged.labels = mergedLabels(versions)
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
        if isCovered(externalBody, by: localBody) { return local }
        if isSuperset(externalBody, of: localBody) { return external }
        return "\(local)\n\n\(divider(for: externalDate, now: now))\n\n\(external)"
    }

    /// One version of a note's file that iCloud kept as a conflict, with what
    /// `NSFileVersion` says about who saved it and when.
    struct ConflictCandidate {
        let note: Note
        let savingComputer: String?
        let modificationDate: Date?
    }

    /// The notes worth merging: the current file plus every conflict version
    /// except this computer's own older saves. iCloud can keep an earlier save
    /// from the same Mac as a "conflict"; it holds nothing the current file
    /// lacks, so appending it only produces a "Conflicted copy" of the user's
    /// own words.
    static func versionsToMerge(
        current: Note?,
        candidates: [ConflictCandidate],
        thisComputer: String?,
        currentModified: Date?
    ) -> [Note] {
        var versions: [Note] = []
        if let current { versions.append(current) }
        for candidate in candidates {
            if let thisComputer, candidate.savingComputer == thisComputer,
               let saved = candidate.modificationDate, let currentModified,
               saved <= currentModified {
                continue
            }
            versions.append(candidate.note)
        }
        return versions
    }

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

    /// True when `body` adds nothing to `base`: every line already occurs in
    /// it. The last line may also be a prefix of a base line, because an older
    /// save is often cut mid-word.
    private static func isCovered(_ body: String, by base: String) -> Bool {
        let baseLines = lines(of: base)
        let known = Set(baseLines)
        let bodyLines = lines(of: body)
        for (index, line) in bodyLines.enumerated() where !known.contains(line) {
            let isLast = index == bodyLines.count - 1
            guard isLast, baseLines.contains(where: { $0.hasPrefix(line) }) else { return false }
        }
        return true
    }

    /// True when `body` has every line of `base`.
    private static func isSuperset(_ body: String, of base: String) -> Bool {
        let known = Set(lines(of: body))
        return lines(of: base).allSatisfy(known.contains)
    }

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
