import Darwin
import XCTest
@testable import StickyNotesKit

/// Moving the notes between a local folder, iCloud Drive and a vault, and back.
final class StorageSwitchTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("StorageSwitch-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - Helpers

    private func folder(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    private func makeNote(_ content: String, id: UUID = UUID(), title: String = "") -> Note {
        Note(
            id: id, title: title, content: content,
            positionX: 120, positionY: 240, width: 300, height: 220,
            collapsed: false, color: .blue, labels: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
    }

    private func addAttachment(_ name: String, bytes: String, to store: NoteStore) throws {
        let url = store.rootURL.appendingPathComponent("attachments/\(name)")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: url)
    }

    private func imageLink(_ name: String) -> String {
        Attachments.markdown(for: Attachments.relativePath(fileName: name), isImage: true)
    }

    /// The `.md` files of one folder of a root, read straight from disk.
    private func markdownFiles(_ rootName: String, _ sub: String) throws -> [(url: URL, text: String)] {
        let dir = folder(rootName).appendingPathComponent(sub, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return [] }
        return try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .map { ($0, try String(contentsOf: $0, encoding: .utf8)) }
    }

    private func files(_ rootName: String, _ sub: String, holding id: UUID) throws -> Int {
        try markdownFiles(rootName, sub).filter { $0.text.contains(id.uuidString) }.count
    }

    /// Every `../attachments/…` link in every note of a root that does not lead to a file.
    private func danglingLinks(_ rootName: String) throws -> [String] {
        let pattern = try NSRegularExpression(pattern: #"\]\((\.\./attachments/[^)]+)\)"#)
        var dangling: [String] = []
        for sub in ["notes", "archive", ".trash"] {
            for (_, text) in try markdownFiles(rootName, sub) {
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    let link = (text as NSString).substring(with: match.range(at: 1))
                    let decoded = link.removingPercentEncoding ?? link
                    let target = URL(fileURLWithPath: decoded, relativeTo: folder(rootName).appendingPathComponent("notes"))
                    if !fm.fileExists(atPath: target.standardizedFileURL.path) { dangling.append(link) }
                }
            }
        }
        return dangling
    }

    private func bytes(of link: String, in rootName: String) throws -> String? {
        let decoded = link.removingPercentEncoding ?? link
        let target = URL(fileURLWithPath: decoded, relativeTo: folder(rootName).appendingPathComponent("notes"))
        return (try? Data(contentsOf: target.standardizedFileURL)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func tree(_ rootName: String) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let base = folder(rootName).resolvingSymlinksInPath().path
        guard let walker = fm.enumerator(at: folder(rootName), includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            result[String(url.resolvingSymlinksInPath().path.dropFirst(base.count))] = try Data(contentsOf: url)
        }
        return result
    }

    /// Give a file an old arrival date and modification date, as one trashed `daysAgo` days ago has.
    private func age(_ url: URL, days daysAgo: Double) throws {
        let date = Date().addingTimeInterval(-daysAgo * 86_400)
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)
        var value = timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)
        XCTAssertEqual(setattrlist(url.path, &list, &value, MemoryLayout<timespec>.size, 0), 0)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Archive and trash state

    func testANoteArchivedOnTheMiddleRootIsStillArchivedBackOnTheFirst() throws {
        let store = NoteStore(rootURL: folder("a"))
        try addAttachment("shot.png", bytes: "pixels", to: store)
        let note = makeNote("look: \(imageLink("shot.png"))")
        store.save(note)

        store.reconfigure(rootURL: folder("b"))
        store.archive(try XCTUnwrap(store.loadNote(id: note.id)))
        store.reconfigure(rootURL: folder("a"))

        XCTAssertEqual(store.loadActive().map(\.id), [], "the note came back to the desk")
        XCTAssertEqual(store.loadArchived().map(\.id), [note.id])
        XCTAssertEqual(try files("a", "notes", holding: note.id), 0)
        XCTAssertEqual(try files("a", "archive", holding: note.id), 1)
        XCTAssertEqual(try danglingLinks("a"), [])
        XCTAssertEqual(try danglingLinks("b"), [])
    }

    func testANoteArchivedOnTheFirstRootAfterComingBackIsArchivedOnTheMiddleOneToo() throws {
        let store = NoteStore(rootURL: folder("a"))
        let note = makeNote("moves around")
        store.save(note)

        store.reconfigure(rootURL: folder("b"))
        store.reconfigure(rootURL: folder("a"))
        store.archive(try XCTUnwrap(store.loadNote(id: note.id)))
        store.reconfigure(rootURL: folder("b"))

        XCTAssertEqual(store.loadActive().map(\.id), [])
        XCTAssertEqual(store.loadArchived().map(\.id), [note.id])
        XCTAssertEqual(try files("b", "notes", holding: note.id), 0)
    }

    func testANoteRestoredOnTheMiddleRootIsActiveBackOnTheFirst() throws {
        let store = NoteStore(rootURL: folder("a"))
        let note = makeNote("archived, then wanted again")
        store.save(note)
        store.archive(note)

        store.reconfigure(rootURL: folder("b"))
        store.restore(try XCTUnwrap(store.loadNote(id: note.id, archived: true)))
        store.reconfigure(rootURL: folder("a"))

        XCTAssertEqual(store.loadActive().map(\.id), [note.id])
        XCTAssertEqual(try files("a", "archive", holding: note.id), 0)
    }

    func testACopyThatTheNewRootPlacedLaterStaysWhereItIs() throws {
        let store = NoteStore(rootURL: folder("a"))
        let note = makeNote("active here")
        store.save(note)
        let other = NoteStore(rootURL: folder("b"))
        other.save(note)
        other.archive(note)
        let archived = try XCTUnwrap(markdownFiles("b", "archive").first).url
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(3_600)], ofItemAtPath: archived.path)

        store.reconfigure(rootURL: folder("b"))

        XCTAssertEqual(store.loadActive().map(\.id), [], "the archive made there was later")
        XCTAssertEqual(store.loadArchived().map(\.id), [note.id])
    }

    func testTheTrashComesAlongWithItsDeletionDate() throws {
        let store = NoteStore(rootURL: folder("a"))
        let note = makeNote("thrown away")
        store.save(note)
        store.archive(note)
        store.deleteForever(try XCTUnwrap(store.loadNote(id: note.id, archived: true)))
        let trashed = try XCTUnwrap(markdownFiles("a", ".trash").first).url
        try age(trashed, days: 20)

        store.reconfigure(rootURL: folder("b"))

        XCTAssertEqual(store.loadTrashed().map(\.id), [note.id])
        XCTAssertEqual(try files("a", ".trash", holding: note.id), 1, "the old root keeps its copy")
        let deleted = Date().addingTimeInterval(-20 * 86_400)
        XCTAssertEqual(store.purgeExpiredTrash(now: deleted.addingTimeInterval(29 * 86_400)), 0)
        XCTAssertEqual(store.purgeExpiredTrash(now: deleted.addingTimeInterval(31 * 86_400)), 1)
    }

    func testTrashPastItsRetentionIsNotCarriedOver() throws {
        let store = NoteStore(rootURL: folder("a"))
        let note = makeNote("long gone")
        store.save(note)
        store.archive(note)
        store.deleteForever(try XCTUnwrap(store.loadNote(id: note.id, archived: true)))
        try age(XCTUnwrap(markdownFiles("a", ".trash").first).url, days: 31)

        store.reconfigure(rootURL: folder("b"))

        XCTAssertEqual(store.loadTrashed().map(\.id), [])
    }

    func testANoteDeletedOnOneRootAndKeptOnTheOtherEndsUpInTheTrashWhenTheDeletionIsLater() throws {
        let store = NoteStore(rootURL: folder("a"))
        let note = makeNote("kept on b")
        let other = NoteStore(rootURL: folder("b"))
        other.save(note)
        other.archive(note)
        try age(XCTUnwrap(markdownFiles("b", "archive").first).url, days: 3)
        store.save(note)
        store.archive(note)
        store.deleteForever(try XCTUnwrap(store.loadNote(id: note.id, archived: true)))

        store.reconfigure(rootURL: folder("b"))

        XCTAssertEqual(store.loadTrashed().map(\.id), [note.id])
        XCTAssertEqual(store.loadArchived().map(\.id), [])
        XCTAssertEqual(try files("b", "archive", holding: note.id), 0)
    }

    // MARK: - Attachments

    func testAttachmentsComeAlongAndEveryLinkStillLeadsToTheFile() throws {
        let store = NoteStore(rootURL: folder("a"))
        try addAttachment("one.png", bytes: "first", to: store)
        try addAttachment("sub/two.png", bytes: "second", to: store)
        store.save(makeNote("\(imageLink("one.png")) and \(imageLink("sub/two.png"))"))
        let archived = makeNote("archived \(imageLink("one.png"))")
        store.save(archived)
        store.archive(archived)

        let report = store.reconfigure(rootURL: folder("b"))

        XCTAssertEqual(try danglingLinks("b"), [])
        XCTAssertEqual(try bytes(of: "../attachments/one.png", in: "b"), "first")
        XCTAssertEqual(try bytes(of: "../attachments/sub/two.png", in: "b"), "second")
        XCTAssertEqual(report.attachments, 2)
        XCTAssertEqual(report.notes, 1)
        XCTAssertEqual(report.archived, 1)
    }

    func testSameNamedAttachmentsWithOtherBytesAreBothKeptAndTheCopiedNoteLinksToItsOwn() throws {
        let store = NoteStore(rootURL: folder("a"))
        try addAttachment("shot.png", bytes: "from a", to: store)
        try addAttachment("my pic.png", bytes: "a picture from a", to: store)
        let mine = makeNote("mine \(imageLink("shot.png")) \(imageLink("my pic.png"))")
        store.save(mine)

        let there = NoteStore(rootURL: folder("b"))
        try addAttachment("shot.png", bytes: "from b", to: there)
        try addAttachment("my pic.png", bytes: "a picture from b", to: there)
        let theirs = makeNote("theirs \(imageLink("shot.png")) \(imageLink("my pic.png"))")
        there.save(theirs)

        let report = store.reconfigure(rootURL: folder("b"))

        XCTAssertEqual(report.attachmentsKeptBoth, 2)
        XCTAssertEqual(try danglingLinks("b"), [])
        let mineText = try XCTUnwrap(markdownFiles("b", "notes").first { $0.text.contains(mine.id.uuidString) }).text
        let theirText = try XCTUnwrap(markdownFiles("b", "notes").first { $0.text.contains(theirs.id.uuidString) }).text
        XCTAssertTrue(theirText.contains("../attachments/shot.png"), "their note is untouched")
        XCTAssertFalse(mineText.contains("../attachments/shot.png"))
        XCTAssertTrue(mineText.contains("../attachments/shot-2.png"), mineText)
        XCTAssertTrue(mineText.contains("../attachments/my%20pic-2.png"), mineText)
        XCTAssertEqual(try bytes(of: "../attachments/shot.png", in: "b"), "from b")
        XCTAssertEqual(try bytes(of: "../attachments/shot-2.png", in: "b"), "from a")
        XCTAssertEqual(try bytes(of: "../attachments/my%20pic-2.png", in: "b"), "a picture from a")
    }

    func testGoingBackAndForthDoesNotMultiplyAttachments() throws {
        let store = NoteStore(rootURL: folder("a"))
        try addAttachment("shot.png", bytes: "from a", to: store)
        let note = makeNote("see \(imageLink("shot.png"))")
        store.save(note)
        let there = NoteStore(rootURL: folder("b"))
        try addAttachment("shot.png", bytes: "from b", to: there)

        for destination in ["b", "a", "b", "a"] { store.reconfigure(rootURL: folder(destination)) }

        for name in ["a", "b"] {
            XCTAssertEqual(try danglingLinks(name), [])
            let attachments = try fm.contentsOfDirectory(atPath: folder(name).appendingPathComponent("attachments").path)
            XCTAssertEqual(attachments.count, 2, "\(name) holds \(attachments)")
        }
        XCTAssertEqual(store.loadActive().map(\.id), [note.id])
    }

    func testAnAttachmentTheNewRootHoldsUnderAnotherNameIsLinkedInsteadOfCopied() throws {
        let store = NoteStore(rootURL: folder("a"))
        try addAttachment("shot.png", bytes: "same pixels", to: store)
        store.save(makeNote("see \(imageLink("shot.png"))"))
        let there = NoteStore(rootURL: folder("b"))
        try addAttachment("renamed.png", bytes: "same pixels", to: there)

        let report = store.reconfigure(rootURL: folder("b"))

        XCTAssertEqual(report.attachments, 0)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder("b").appendingPathComponent("attachments").path), ["renamed.png"])
        XCTAssertEqual(try danglingLinks("b"), [])
        XCTAssertTrue(try XCTUnwrap(markdownFiles("b", "notes").first).text.contains("../attachments/renamed.png"))
    }

    func testRewritingLinksChangesOnlyTheLinksItIsToldAbout() {
        let text = """
        ![a](../attachments/x.png) ![b](../attachments/y%20z.png "title") ![c](../attachments/keep.png)
        [d](../attachments/sub/q.pdf) ![e](../attachments/a b.png) ![[x.png]] ../attachments/x.png
        """
        let links = ["x.png": "x-2.png", "y z.png": "y z-2.png", "sub/q.pdf": "sub/q-2.pdf", "a b.png": "a b-2.png"]

        let rewritten = NoteStore.rewritingAttachmentLinks(in: text, using: links)

        XCTAssertEqual(rewritten, """
        ![a](../attachments/x-2.png) ![b](../attachments/y%20z-2.png "title") ![c](../attachments/keep.png)
        [d](../attachments/sub/q-2.pdf) ![e](../attachments/a b-2.png) ![[x.png]] ../attachments/x-2.png
        """)
    }

    func testRewritingLinksTakesAllMovesAtOnceSoTwoFilesCanSwapNames() {
        let text = "![a](../attachments/x.png) ![b](../attachments/x-2.png)"

        let rewritten = NoteStore.rewritingAttachmentLinks(in: text, using: ["x.png": "x-2.png", "x-2.png": "x.png"])

        XCTAssertEqual(rewritten, "![a](../attachments/x-2.png) ![b](../attachments/x.png)")
    }

    // MARK: - Files of the new root that are not downloaded

    private func placeholder(for fileName: String, inRoot rootName: String, folder sub: String) throws {
        let dir = folder(rootName).appendingPathComponent(sub, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent(".\(fileName).icloud"))
    }

    func testANoteWhoseFileIsStillDownloadingInAnotherFolderIsNotWrittenAgain() throws {
        let store = NoteStore(rootURL: folder("a"))
        store.downloadWait = 0
        let note = makeNote("archived on the other Mac")
        store.save(note)
        let name = try XCTUnwrap(markdownFiles("a", "notes").first).url.lastPathComponent
        try placeholder(for: name, inRoot: "b", folder: "archive")

        let report = store.reconfigure(rootURL: folder("b"))

        XCTAssertEqual(try files("b", "notes", holding: note.id), 0, "the note would be active and archived once it arrives")
        XCTAssertEqual(report.notReadable, 1)
        XCTAssertEqual(report.notes, 0)
        XCTAssertEqual(try files("a", "notes", holding: note.id), 1, "the old root keeps it")
    }

    func testANoteWhoseFileIsStillDownloadingInTheSameFolderIsNotWrittenBesideIt() throws {
        let store = NoteStore(rootURL: folder("a"))
        store.downloadWait = 0
        let note = makeNote("here and there")
        store.save(note)
        let name = try XCTUnwrap(markdownFiles("a", "notes").first).url.lastPathComponent
        try placeholder(for: name, inRoot: "b", folder: "notes")

        let report = store.reconfigure(rootURL: folder("b"))

        XCTAssertEqual(try markdownFiles("b", "notes").count, 0)
        XCTAssertEqual(report.notReadable, 1)
    }

    func testAnIdInAGeneratedNameIsEnoughToHoldBackANote() throws {
        let store = NoteStore(rootURL: folder("a"))
        store.downloadWait = 0
        let note = makeNote("renamed elsewhere")
        store.save(note)
        let name = try XCTUnwrap(markdownFiles("a", "notes").first).url.lastPathComponent
        let suffix = String(name.dropFirst(name.count - 10))
        try placeholder(for: "2030-01-01 000000\(suffix)", inRoot: "b", folder: "archive")

        let report = store.reconfigure(rootURL: folder("b"))

        XCTAssertEqual(report.notReadable, 1)
        XCTAssertEqual(try markdownFiles("b", "notes").count, 0)
    }

    func testAnAttachmentNameThatIsStillDownloadingIsTakenSoTheIncomingFileIsRenamed() throws {
        let store = NoteStore(rootURL: folder("a"))
        store.downloadWait = 0
        try addAttachment("shot.png", bytes: "from a", to: store)
        let note = makeNote("see \(imageLink("shot.png"))")
        store.save(note)
        try placeholder(for: "shot.png", inRoot: "b", folder: "attachments")

        store.reconfigure(rootURL: folder("b"))

        XCTAssertEqual(try bytes(of: "../attachments/shot-2.png", in: "b"), "from a")
        XCTAssertFalse(fm.fileExists(atPath: folder("b").appendingPathComponent("attachments/shot.png").path))
        XCTAssertEqual(try danglingLinks("b"), [])
        XCTAssertTrue(try XCTUnwrap(markdownFiles("b", "notes").first).text.contains("../attachments/shot-2.png"))
    }

    // MARK: - Coming back to a root

    private func edit(_ store: NoteStore, _ id: UUID, archived: Bool = false, _ change: (inout Note) -> Void) throws {
        var note = try XCTUnwrap(store.loadNote(id: id, archived: archived))
        change(&note)
        note.updatedAt = Date()
        XCTAssertNotNil(store.save(note))
    }

    func testATextEditedOnTheMiddleRootComesBackWholeWithNoConflictedCopy() throws {
        let store = NoteStore(rootURL: folder("a"))
        let note = makeNote("P\nQ")
        store.save(note)

        store.reconfigure(rootURL: folder("b"))
        try edit(store, note.id) { $0.content = "P2\nQ" }
        store.reconfigure(rootURL: folder("a"))

        XCTAssertEqual(store.loadActive().map(\.content), ["P2\nQ"])
    }

    func testALabelRemovedOnTheMiddleRootIsStillGoneBackOnTheFirst() throws {
        let store = NoteStore(rootURL: folder("a"))
        var note = makeNote("text")
        note.labels = ["keep", "drop"]
        store.save(note)

        store.reconfigure(rootURL: folder("b"))
        try edit(store, note.id) { $0.labels = ["keep"] }
        store.reconfigure(rootURL: folder("a"))

        XCTAssertEqual(store.loadActive().map(\.labels), [["keep"]])
    }

    func testANoteArchivedOnTheMiddleRootIsArchivedBackWithNoDateInvolved() throws {
        let store = NoteStore(rootURL: folder("a"))
        let note = makeNote("archive me")
        store.save(note)
        // The first root's copy was written after anything the middle root can do.
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(7_200)],
                             ofItemAtPath: XCTUnwrap(markdownFiles("a", "notes").first).url.path)

        store.reconfigure(rootURL: folder("b"))
        store.archive(try XCTUnwrap(store.loadNote(id: note.id)))
        store.reconfigure(rootURL: folder("a"))

        XCTAssertEqual(store.loadArchived().map(\.id), [note.id])
        XCTAssertEqual(try files("a", "notes", holding: note.id), 0)
    }

    func testChangesOnBothRootsAreMerged() throws {
        let store = NoteStore(rootURL: folder("a"))
        let note = makeNote("P\nQ")
        store.save(note)

        store.reconfigure(rootURL: folder("b"))
        try edit(store, note.id) { $0.content = "P\nQ\nwritten on b" }
        let otherMac = NoteStore(rootURL: folder("a"))
        try edit(otherMac, note.id) { $0.content = "P\nQ\nwritten on the other Mac" }
        store.reconfigure(rootURL: folder("a"))

        let content = try XCTUnwrap(store.loadActive().first).content
        XCTAssertTrue(content.contains("written on b"), content)
        XCTAssertTrue(content.contains("written on the other Mac"), content)
    }

    func testWhatOnlyTheOtherRootChangedIsKeptWithoutAConflictedCopy() throws {
        let store = NoteStore(rootURL: folder("a"))
        let note = makeNote("P\nQ")
        store.save(note)

        store.reconfigure(rootURL: folder("b"))
        let otherMac = NoteStore(rootURL: folder("a"))
        try edit(otherMac, note.id) { $0.content = "P\nwritten on the other Mac" }
        store.reconfigure(rootURL: folder("a"))

        XCTAssertEqual(store.loadActive().map(\.content), ["P\nwritten on the other Mac"])
    }

    func testWhatARootHeldWhenItWasLeftIsRememberedOutsideEveryRootAndAcrossRelaunches() throws {
        let records = root.appendingPathComponent("records.json")
        let store = NoteStore(rootURL: folder("a"))
        store.switchRecordsURL = records
        let note = makeNote("P\nQ")
        store.save(note)
        store.reconfigure(rootURL: folder("b"))
        XCTAssertTrue(fm.fileExists(atPath: records.path))
        XCTAssertNil(try tree("a").keys.first { $0.contains("records") })

        let relaunched = NoteStore(rootURL: folder("b"))
        relaunched.switchRecordsURL = records
        try edit(relaunched, note.id) { $0.content = "P2\nQ" }
        relaunched.reconfigure(rootURL: folder("a"))

        XCTAssertEqual(relaunched.loadActive().map(\.content), ["P2\nQ"])
    }

    // MARK: - Leaving the old root alone, and what is said

    func testTheRootThatWasLeftIsByteForByteWhatItWas() throws {
        let store = NoteStore(rootURL: folder("a"))
        try addAttachment("shot.png", bytes: "pixels", to: store)
        let note = makeNote("one \(imageLink("shot.png"))")
        store.save(note)
        let archived = makeNote("two")
        store.save(archived)
        store.archive(archived)
        let trashed = makeNote("three")
        store.save(trashed)
        store.archive(trashed)
        store.deleteForever(try XCTUnwrap(store.loadNote(id: trashed.id, archived: true)))
        let before = try tree("a")
        XCTAssertFalse(before.isEmpty)

        store.reconfigure(rootURL: folder("b"))
        store.reconfigure(rootURL: folder("c"))

        XCTAssertEqual(try tree("a"), before)
    }

    func testSwitchingToTheRootThatIsAlreadyInUseChangesNothing() throws {
        let store = NoteStore(rootURL: folder("a"))
        store.save(makeNote("stay"))
        let before = try tree("a")

        let report = store.reconfigure(rootURL: folder("a"))

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(try tree("a"), before)
    }

    func testTheReportCountsWhatWasCarriedAndWhatWasMerged() throws {
        let store = NoteStore(rootURL: folder("a"))
        let shared = makeNote("shared\nonly here")
        store.save(shared)
        store.save(makeNote("active two"))
        let archived = makeNote("archived")
        store.save(archived)
        store.archive(archived)
        let there = NoteStore(rootURL: folder("b"))
        there.save(makeNote("shared\nonly there", id: shared.id))

        let report = store.reconfigure(rootURL: folder("b"))

        XCTAssertEqual(report.notes, 2)
        XCTAssertEqual(report.archived, 1)
        XCTAssertEqual(report.merged, 1)
        XCTAssertEqual(report.trashed, 0)
        XCTAssertEqual(report.couldNotCopy, 0)
    }

    func testAnUndownloadedFileIsCountedNotCopied() throws {
        let store = NoteStore(rootURL: folder("a"))
        store.save(makeNote("here"))
        try fm.createDirectory(at: folder("a").appendingPathComponent("attachments"), withIntermediateDirectories: true)
        try Data().write(to: folder("a").appendingPathComponent("attachments/.later.png.icloud"))

        let report = store.reconfigure(rootURL: folder("b"))

        XCTAssertEqual(report.notReadable, 1)
        XCTAssertEqual(report.attachments, 0)
        XCTAssertEqual(report.notes, 1)
    }

    func testTheMessageIsOneCalmSentence() {
        func message(_ report: StorageSwitchReport) -> String? { Toast.storageMovedMessage(report) }
        XCTAssertNil(message(StorageSwitchReport()))
        XCTAssertEqual(message(StorageSwitchReport(notes: 1)), "Moved 1 note")
        XCTAssertEqual(message(StorageSwitchReport(notes: 9, archived: 3, trashed: 2, attachments: 4)),
                       "Moved 9 notes, 3 archived, 2 in Trash and 4 attachments")
        XCTAssertEqual(message(StorageSwitchReport(notes: 2, merged: 1, attachments: 1)),
                       "Moved 2 notes and 1 attachment; 1 merged")
        XCTAssertEqual(message(StorageSwitchReport(notes: 2, notReadable: 2, couldNotCopy: 1)),
                       "Moved 2 notes; 1 could not be copied, 2 not downloaded yet")
        XCTAssertEqual(message(StorageSwitchReport(notReadable: 1)), "1 not downloaded yet")
    }
}
