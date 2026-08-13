import XCTest
@testable import StickyNotesKit

final class NoteSearchTests: XCTestCase {

    private func note(
        title: String = "",
        content: String = "",
        labels: [String] = [],
        updated: TimeInterval = 0
    ) -> Note {
        Note(
            id: UUID(), title: title, content: content,
            positionX: 0, positionY: 0, width: 240, height: 200,
            collapsed: false, color: .yellow, labels: labels,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + updated)
        )
    }

    // MARK: - Fuzzy scoring

    func testSubsequenceMatchesScore() {
        XCTAssertNotNil(NoteSearch.fuzzyScore(query: "grc", in: "groceries"))
        XCTAssertNotNil(NoteSearch.fuzzyScore(query: "groceries", in: "groceries"))
    }

    func testNonSubsequenceDoesNotMatch() {
        XCTAssertNil(NoteSearch.fuzzyScore(query: "xyz", in: "groceries"))
        XCTAssertNil(NoteSearch.fuzzyScore(query: "seirecorg", in: "groceries"),
                     "order matters — a reversed string is not a subsequence")
    }

    func testQueryLongerThanCandidateDoesNotMatch() {
        XCTAssertNil(NoteSearch.fuzzyScore(query: "groceries list", in: "groceries"))
    }

    func testEmptyQueryScoresZeroRatherThanFailing() {
        XCTAssertEqual(NoteSearch.fuzzyScore(query: "", in: "anything"), 0)
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertNotNil(NoteSearch.fuzzyScore(query: "GROC", in: "groceries"))
        XCTAssertNotNil(NoteSearch.fuzzyScore(query: "groc", in: "GROCERIES"))
    }

    func testMatchingIgnoresDiacritics() {
        XCTAssertNotNil(NoteSearch.fuzzyScore(query: "cafe", in: "café au lait"))
        XCTAssertNotNil(NoteSearch.fuzzyScore(query: "café", in: "cafe au lait"))
    }

    func testContiguousMatchBeatsScattered() throws {
        let contiguous = try XCTUnwrap(NoteSearch.fuzzyScore(query: "note", in: "note taking"))
        let scattered = try XCTUnwrap(NoteSearch.fuzzyScore(query: "note", in: "nice open trees everywhere"))
        XCTAssertGreaterThan(contiguous, scattered)
    }

    func testPrefixMatchBeatsMidStringMatch() throws {
        let prefix = try XCTUnwrap(NoteSearch.fuzzyScore(query: "work", in: "work log"))
        let middle = try XCTUnwrap(NoteSearch.fuzzyScore(query: "work", in: "the work log"))
        XCTAssertGreaterThan(prefix, middle)
    }

    func testWordStartMatchBeatsMidWordMatch() throws {
        let wordStart = try XCTUnwrap(NoteSearch.fuzzyScore(query: "log", in: "work log"))
        let midWord = try XCTUnwrap(NoteSearch.fuzzyScore(query: "log", in: "prologue"))
        XCTAssertGreaterThan(wordStart, midWord)
    }

    func testShorterCandidateWinsWhenOtherwiseEqual() throws {
        let short = try XCTUnwrap(NoteSearch.fuzzyScore(query: "plan", in: "plan"))
        let long = try XCTUnwrap(NoteSearch.fuzzyScore(query: "plan", in: "plan for the entire fiscal year"))
        XCTAssertGreaterThan(short, long)
    }

    // MARK: - Field tiers

    func testTitleHitOutranksBodyHit() throws {
        let titled = note(title: "Groceries", content: "unrelated text", updated: 0)
        let bodied = note(title: "", content: "groceries somewhere in here", updated: 500)

        let ranked = NoteSearch.rank([bodied, titled], query: "groceries")
        XCTAssertEqual(ranked.first?.note.id, titled.id,
                       "a title hit should win even though the body hit is more recent")
    }

    func testLabelHitOutranksBodyHit() throws {
        let labelled = note(content: "nothing relevant", labels: ["urgent"], updated: 0)
        let bodied = note(content: "this is urgent business", updated: 500)

        let ranked = NoteSearch.rank([bodied, labelled], query: "urgent")
        XCTAssertEqual(ranked.first?.note.id, labelled.id)
    }

    func testTitleHitOutranksLabelHit() throws {
        let titled = note(title: "urgent", updated: 0)
        let labelled = note(content: "x", labels: ["urgent"], updated: 500)

        let ranked = NoteSearch.rank([labelled, titled], query: "urgent")
        XCTAssertEqual(ranked.first?.note.id, titled.id)
    }

    func testRecencyBreaksTiesBetweenEquivalentHits() throws {
        let older = note(title: "Plan", updated: 0)
        let newer = note(title: "Plan", updated: 1000)

        let ranked = NoteSearch.rank([older, newer], query: "plan")
        XCTAssertEqual(ranked.first?.note.id, newer.id)
    }

    // MARK: - Body matching

    func testBodyMatchesBySubstring() {
        let n = note(content: "remember to buy milk")
        XCTAssertNotNil(NoteSearch.match(n, query: "buy milk"))
    }

    /// Fuzzy matching over long prose would match nearly any query, so body
    /// text is deliberately substring-only.
    func testBodyDoesNotMatchAScatteredSubsequence() {
        let n = note(content: "the quick brown fox jumps over the lazy dog")
        XCTAssertNil(NoteSearch.match(n, query: "tqbf"),
                     "scattered letters should not match prose")
    }

    func testBodyMatchIsCaseAndDiacriticInsensitive() {
        XCTAssertNotNil(NoteSearch.match(note(content: "Visit the CAFÉ"), query: "café"))
        XCTAssertNotNil(NoteSearch.match(note(content: "Visit the café"), query: "CAFE"))
    }

    func testExcerptShowsTheMatchingLineNotTheFirstLine() throws {
        let n = note(content: "shopping list\nmilk and eggs\nsomething else")
        let hit = try XCTUnwrap(NoteSearch.match(n, query: "eggs"))
        XCTAssertEqual(hit.excerpt, "milk and eggs")
    }

    func testExcerptForATitleHitIsTheTitle() throws {
        let n = note(title: "Quarterly plan", content: "body")
        let hit = try XCTUnwrap(NoteSearch.match(n, query: "quarterly"))
        XCTAssertEqual(hit.excerpt, "Quarterly plan")
    }

    func testExcerptForALabelHitNamesTheLabel() throws {
        let n = note(content: "body", labels: ["deep-work"])
        let hit = try XCTUnwrap(NoteSearch.match(n, query: "deep"))
        XCTAssertEqual(hit.excerpt, "#deep-work")
    }

    // MARK: - Label-scoped queries

    func testHashPrefixSearchesLabelsOnly() {
        let labelled = note(content: "nothing", labels: ["work"])
        let bodyOnly = note(content: "work work work")

        XCTAssertNotNil(NoteSearch.match(labelled, query: "#work"))
        XCTAssertNil(NoteSearch.match(bodyOnly, query: "#work"),
                     "#work should not match prose containing 'work'")
    }

    func testHashPrefixStillMatchesLabelsFuzzily() {
        let n = note(labels: ["deep-work"])
        XCTAssertNotNil(NoteSearch.match(n, query: "#dw"))
    }

    func testBareHashMatchesEverything() {
        XCTAssertNotNil(NoteSearch.match(note(content: "anything"), query: "#"))
    }

    // MARK: - Ranking behavior

    func testNonMatchingNotesAreDropped() {
        let notes = [note(content: "alpha"), note(content: "beta"), note(content: "gamma")]
        let ranked = NoteSearch.rank(notes, query: "beta")
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.note.content, "beta")
    }

    func testEmptyQueryReturnsEverythingNewestFirst() {
        let old = note(content: "old", updated: 0)
        let mid = note(content: "mid", updated: 100)
        let new = note(content: "new", updated: 200)

        let ranked = NoteSearch.rank([old, new, mid], query: "")
        XCTAssertEqual(ranked.map(\.note.content), ["new", "mid", "old"])
    }

    func testWhitespaceOnlyQueryIsTreatedAsEmpty() {
        let ranked = NoteSearch.rank([note(content: "a"), note(content: "b")], query: "   ")
        XCTAssertEqual(ranked.count, 2)
    }

    func testQueryIsTrimmedBeforeMatching() {
        XCTAssertNotNil(NoteSearch.match(note(title: "Groceries"), query: "  groceries  "))
    }

    func testEmptyNoteListReturnsNoResults() {
        XCTAssertTrue(NoteSearch.rank([], query: "anything").isEmpty)
    }

    func testEmptyNotesDoNotMatchANonEmptyQuery() {
        XCTAssertNil(NoteSearch.match(note(), query: "something"))
    }

    func testRankingIsStableAcrossRepeatedCalls() {
        let notes = (0..<20).map { note(title: "Plan \($0)", content: "planning body", updated: Double($0)) }
        let first = NoteSearch.rank(notes, query: "plan").map(\.note.id)
        let second = NoteSearch.rank(notes, query: "plan").map(\.note.id)
        XCTAssertEqual(first, second)
    }

    // MARK: - Realistic scenario

    func testTypingProgressivelyNarrowsToTheIntendedNote() throws {
        let groceries = note(title: "Groceries", content: "- milk\n- eggs", labels: ["home"], updated: 100)
        let standup = note(title: "Standup notes", content: "discussed grocery integration", updated: 300)
        let random = note(content: "gross overestimate of the budget", updated: 500)
        let all = [groceries, standup, random]

        // A single letter is ambiguous; by "groc" the intended note leads.
        XCTAssertEqual(NoteSearch.rank(all, query: "groc").first?.note.id, groceries.id)
        XCTAssertEqual(NoteSearch.rank(all, query: "groceries").first?.note.id, groceries.id)

        // Label scoping picks it out even with no textual overlap.
        XCTAssertEqual(NoteSearch.rank(all, query: "#home").map(\.note.id), [groceries.id])
    }

    /// Worst case for the ranker: no title or label matches, so every note's
    /// full body has to be scanned.
    func testBodyOnlySearchOverALargeLibraryIsFast() {
        let notes = (0..<2000).map { _ in
            note(title: "", content: String(repeating: "some body text with words ", count: 40))
        }

        let start = CFAbsoluteTimeGetCurrent()
        for query in ["zqx", "zqxj", "zqxjv"] { _ = NoteSearch.rank(notes, query: query) }
        let perKeystroke = (CFAbsoluteTimeGetCurrent() - start) / 3

        XCTAssertLessThan(perKeystroke, 0.1,
                          "\(perKeystroke)s to scan 2000 note bodies would feel laggy")
    }

    func testBodyScanIsSkippedWhenTheTitleAlreadyMatches() throws {
        // Tier floors guarantee a title hit outranks any body hit, so the body
        // never needs looking at. Pinned because it is what keeps typing fast.
        let n = note(title: "Groceries", content: "groceries groceries groceries")
        let hit = try XCTUnwrap(NoteSearch.match(n, query: "groceries"))
        XCTAssertEqual(hit.excerpt, "Groceries", "a title hit should report the title, not a body line")
    }

    func testSearchOverALargeLibraryIsFast() {
        let notes = (0..<2000).map {
            note(title: "Note \($0)",
                 content: String(repeating: "some body text with words ", count: 40),
                 labels: ["label\($0 % 20)"],
                 updated: Double($0))
        }

        let start = CFAbsoluteTimeGetCurrent()
        for query in ["n", "no", "not", "note", "note 1", "note 12"] {
            _ = NoteSearch.rank(notes, query: query)
        }
        let perKeystroke = (CFAbsoluteTimeGetCurrent() - start) / 6

        XCTAssertLessThan(perKeystroke, 0.05,
                          "\(perKeystroke)s per keystroke over 2000 notes would feel laggy")
    }
}
