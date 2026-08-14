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
    static func merge(_ versions: [Note], now: Date = Date()) -> Note? {
        guard let winner = versions.max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        guard versions.count > 1 else { return winner }

        let winningBody = normalize(winner.content)
        var merged = winner
        var appended: [String] = []
        var seen: Set<String> = [winningBody]

        // Oldest first, so the appended sections read chronologically.
        for version in versions.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            let body = normalize(version.content)
            guard !body.isEmpty, !seen.contains(body) else { continue }
            // A version whose text the winner already contains added nothing.
            if winningBody.contains(body) { continue }
            seen.insert(body)
            appended.append("\(divider(for: version.updatedAt, now: now))\n\n\(body)")
        }

        guard !appended.isEmpty else { return winner }
        merged.content = ([winner.content] + appended).joined(separator: "\n\n")
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
        if localBody.contains(externalBody) { return local }
        if externalBody.contains(localBody) { return external }
        return "\(local)\n\n\(divider(for: externalDate, now: now))\n\n\(external)"
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
