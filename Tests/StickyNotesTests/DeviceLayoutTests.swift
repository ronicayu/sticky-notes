import AppKit
import XCTest
@testable import StickyNotesKit

/// Where a note's window sits is this Mac's own: it is kept in `DeviceLayoutStore`,
/// never in the note's file, so dragging a note writes nothing a sync service
/// would carry to another Mac.
@MainActor final class DeviceLayoutTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var store: NoteStore!
    private var clock: ManualClock!
    private var scheduler: TestScheduler!
    private var layoutScheduler: TestScheduler!
    private var controllers: [NoteWindowController] = []
    private let fm = FileManager.default

    override func setUp() async throws {
        _ = NSApplication.shared
        directory = fm.temporaryDirectory.appendingPathComponent("DeviceLayout-\(UUID().uuidString)", isDirectory: true)
        root = directory.appendingPathComponent("vault", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        clock = ManualClock()
        scheduler = TestScheduler(clock: clock)
        layoutScheduler = TestScheduler()
        store = NoteStore(rootURL: root, clock: clock)
    }

    override func tearDown() async throws {
        controllers.forEach { $0.window?.close() }
        controllers = []
        try? fm.removeItem(at: directory)
    }

    // MARK: - Harness

    private func layoutURL(_ name: String = "layout.json") -> URL {
        directory.appendingPathComponent(name)
    }

    private func makeLayout(_ name: String = "layout.json") -> DeviceLayoutStore {
        DeviceLayoutStore(url: layoutURL(name), scheduler: layoutScheduler)
    }

    private func open(
        _ note: Note, layout: DeviceLayoutStore, placing: ((CGSize) -> CGRect)? = nil
    ) -> NoteWindowController {
        let controller = NoteWindowController(
            note: note, store: store, layout: layout, placing: placing, clock: clock, scheduler: scheduler,
            onClosed: { _ in }
        )
        controllers.append(controller)
        return controller
    }

    private func move(_ controller: NoteWindowController, to origin: NSPoint) throws {
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(origin)
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: window))
    }

    private let legacyId = UUID(uuidString: "6F0E0F00-0000-4000-8000-0000000000AA")!

    /// A note file as the previous build wrote it, with a plugin key and a comment
    /// around its window keys.
    private func writeLegacyFile(
        collapsed: Bool = true, floatLevel: String = "floating", body: String = "hello"
    ) throws -> URL {
        let url = store.activeURL.appendingPathComponent("legacy.md")
        let text = """
        ---
        id: \(legacyId.uuidString)
        title: Legacy
        color: blue
        labels: []
        tags: [a]
        positionX: 50.00
        positionY: 140.00
        # kept comment
        width: 260.00
        height: 210.00
        collapsed: \(collapsed)
        float: \(floatLevel)
        created: 2023-11-14T22:13:20Z
        updated: 2023-11-14T22:21:40Z
        ---

        \(body)
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func loadLegacy() throws -> Note {
        try XCTUnwrap(store.loadActive().first { $0.id == legacyId })
    }

    private func modificationDate(of url: URL) throws -> Date {
        try XCTUnwrap(fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    private func noteFile(for id: UUID) throws -> URL {
        try XCTUnwrap(
            fm.contentsOfDirectory(at: store.activeURL, includingPropertiesForKeys: nil)
                .first { (try? String(contentsOf: $0, encoding: .utf8))?.contains(id.uuidString) == true }
        )
    }

    // MARK: - The layout store

    func testALayoutSurvivesARelaunch() {
        let id = UUID()
        let layout = makeLayout()
        layout.set(NoteLayout(x: 10, y: 20, width: 300, height: 250, collapsed: true), for: id)
        layout.flush()

        let relaunched = makeLayout()

        XCTAssertEqual(relaunched.layout(for: id), NoteLayout(x: 10, y: 20, width: 300, height: 250, collapsed: true))
    }

    func testChangesReachTheFileOnlyAfterTheWriteDelay() {
        let layout = makeLayout()
        layout.set(NoteLayout(x: 1, y: 1, width: 100, height: 100), for: UUID())
        XCTAssertFalse(fm.fileExists(atPath: layoutURL().path), "written on every change; a drag reports many")

        layoutScheduler.advance(by: DeviceLayoutStore.writeDelay + 0.1)

        XCTAssertTrue(fm.fileExists(atPath: layoutURL().path))
    }

    func testADragArmsOneWriteNotOnePerMove() {
        let id = UUID()
        let layout = makeLayout()
        layout.set(NoteLayout(x: 0, y: 0, width: 100, height: 100), for: id)
        layoutScheduler.advance(by: 1)
        XCTAssertEqual(layoutScheduler.pendingCount, 0)

        for x in 1...50 { layout.set(NoteLayout(x: Double(x), y: 0, width: 100, height: 100), for: id) }

        XCTAssertEqual(layoutScheduler.pendingCount, 1, "each move armed its own write")
    }

    func testAStoreWithoutAFileKeepsLayoutInMemoryAndWritesNothing() {
        let id = UUID()
        let layout = DeviceLayoutStore(scheduler: layoutScheduler)
        layout.set(NoteLayout(x: 1, y: 2, width: 3, height: 4), for: id)
        layout.flush()

        XCTAssertEqual(layout.layout(for: id)?.x, 1)
        XCTAssertEqual(layoutScheduler.pendingCount, 0)
    }

    func testAnUnreadableLayoutFileIsAMacThatHasLaidNothingOut() throws {
        try Data("not json".utf8).write(to: layoutURL())

        XCTAssertNil(makeLayout().layout(for: UUID()))
    }

    func testTheMachineFilesLiveInTheAppsOwnFolderAndNotTheSharedApplicationSupportFolder() {
        let isolated = IsolatedSettings()
        defer { isolated.tearDown() }
        let settings = isolated.settings
        let shared = settings.localRootURL.standardizedFileURL.path

        for file in [settings.layoutURL, settings.switchRecordsURL] {
            let folder = file.deletingLastPathComponent().standardizedFileURL.path
            XCTAssertNotEqual(folder, shared, "\(file.lastPathComponent) is in the folder every app shares")
            XCTAssertTrue(folder.hasPrefix(shared + "/StickyNotes"), "\(file.path) is not in this app's folder")
            for scanned in [store.activeURL, store.archiveURL, store.trashURL] {
                XCTAssertFalse(file.standardizedFileURL.path.hasPrefix(scanned.standardizedFileURL.path),
                               "\(file.lastPathComponent) is in a folder the store reads")
            }
        }
    }

    func testMachineFilesFromTheSharedFolderMoveOnceAndOnlyWhenTheyAreOurs() throws {
        let isolated = IsolatedSettings()
        defer { isolated.tearDown() }
        let settings = isolated.settings
        let id = UUID()
        let oldLayout = settings.localRootURL.appendingPathComponent("layout.json")
        let oldRecords = settings.localRootURL.appendingPathComponent("storage-switch-records.json")
        let layout = DeviceLayoutStore(url: oldLayout, scheduler: layoutScheduler)
        layout.set(NoteLayout(x: 5, y: 6, width: 7, height: 8), for: id)
        layout.flush()
        try Data("{\"root\": {\"\(id)\": \"active:abc\"}}".utf8).write(to: oldRecords)

        settings.migrateMachineFiles()

        XCTAssertFalse(fm.fileExists(atPath: oldLayout.path))
        XCTAssertFalse(fm.fileExists(atPath: oldRecords.path))
        XCTAssertEqual(DeviceLayoutStore(url: settings.layoutURL).layout(for: id)?.x, 5)
        XCTAssertTrue(fm.fileExists(atPath: settings.switchRecordsURL.path))

        // Another app's file with the same name is not ours and stays where it is.
        try Data("{\"theme\": \"dark\"}".utf8).write(to: oldLayout)
        try fm.removeItem(at: settings.layoutURL)
        settings.migrateMachineFiles()
        XCTAssertTrue(fm.fileExists(atPath: oldLayout.path))
        XCTAssertFalse(fm.fileExists(atPath: settings.layoutURL.path))
    }

    func testOneBadEntryDoesNotCostTheOtherNotesTheirPlace() throws {
        let good = UUID(), bad = UUID()
        let json = """
        {"\(good)": {"x": 1, "y": 2, "width": 3, "height": 4, "collapsed": false},
         "\(bad)": {"x": "left"}, "not-an-id": {"x": 1}}
        """
        try Data(json.utf8).write(to: layoutURL())

        let layout = makeLayout()

        XCTAssertEqual(layout.layout(for: good)?.x, 1)
        XCTAssertNil(layout.layout(for: bad))
    }

    func testAFileThatIsNotALayoutIsKeptAsideBeforeTheFirstWrite() throws {
        try Data("garbage".utf8).write(to: layoutURL())

        let id = UUID()
        let layout = makeLayout()
        layout.set(NoteLayout(x: 1, y: 2, width: 3, height: 4), for: id)
        layout.flush()

        XCTAssertEqual(try Data(contentsOf: layoutURL().appendingPathExtension("bad")), Data("garbage".utf8))
        XCTAssertEqual(makeLayout().layout(for: id)?.x, 1)
    }

    func testNotesThatExistNowhereAreForgottenAtLaunchAndArchivedOnesAreKept() throws {
        let isolated = IsolatedSettings()
        defer { isolated.tearDown() }
        var active = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200), now: clock.now())
        active.content = "a"
        let archived = Note(id: UUID(), content: "b", width: 240, height: 200, color: .yellow, createdAt: clock.now(), updatedAt: clock.now())
        store.save(active)
        store.save(archived)
        store.archive(archived)
        let gone = UUID()
        let desk = DeskController(
            store: store, settings: isolated.settings, clock: clock, undo: UndoCenter(clock: clock),
            recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock), scheduler: scheduler
        )
        for id in [active.id, archived.id, gone] {
            desk.layout.set(NoteLayout(x: 1, y: 1, width: 240, height: 200), for: id)
        }

        desk.pruneLayout()

        XCTAssertNotNil(desk.layout.layout(for: active.id))
        XCTAssertNotNil(desk.layout.layout(for: archived.id), "an archived note lost its place")
        XCTAssertNil(desk.layout.layout(for: gone))
    }

    // MARK: - A note file is not written by a move

    func testMovingANoteWritesNeitherItsBytesNorItsModificationDate() throws {
        _ = try writeLegacyFile()
        let note = try loadLegacy()
        let controller = open(note, layout: makeLayout())
        let url = try noteFile(for: legacyId)
        let bytes = try Data(contentsOf: url)
        let modified = try modificationDate(of: url)

        try move(controller, to: NSPoint(x: 60, y: 160))
        controller.window?.setContentSize(NSSize(width: 280, height: 230))
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: controller.window))
        controller.dragZoneDidDoubleClick()
        controller.dragZoneDidDoubleClick()
        scheduler.advance(by: 10)
        layoutScheduler.advance(by: 10)

        XCTAssertEqual(try Data(contentsOf: url), bytes, "the note file was rewritten")
        XCTAssertEqual(try modificationDate(of: url), modified, "the note file was touched")
        XCTAssertEqual(scheduler.pendingCount, 0, "a window change armed a note save")
    }

    func testArrangingANoteWritesOnlyTheLayout() throws {
        let note = Note.makeNew(frame: NSRect(x: 100, y: 200, width: 240, height: 200), now: clock.now())
        var written = note
        written.content = "text"
        store.save(written)
        let layout = makeLayout()
        let controller = open(written, layout: layout)
        let url = try noteFile(for: note.id)
        let bytes = try Data(contentsOf: url)

        controller.setArrangedFrame(NSRect(x: 40, y: 60, width: 240, height: 200), animated: false)
        scheduler.advance(by: 10)

        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(layout.layout(for: note.id)?.x, 40)
        XCTAssertEqual(layout.layout(for: note.id)?.y, 60)
    }

    // MARK: - A note this Mac has not seen

    func testANoteWithNoLayoutEntryIsPlacedByNotePlacementAtItsHintedSize() throws {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 310, height: 270), now: clock.now())
        note.content = "synced in"
        store.save(note)
        let screen = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        var asked: [CGSize] = []
        let layout = makeLayout()

        _ = open(note, layout: layout, placing: { size in
            asked.append(size)
            return NotePlacement.next(previous: nil, screen: screen, size: size)
        })

        XCTAssertEqual(asked, [CGSize(width: 310, height: 270)])
        let placed = try XCTUnwrap(layout.layout(for: note.id))
        // The window then keeps itself on a real screen, whose size differs by host.
        let expected = NoteWindow.clampToVisibleScreen(
            NotePlacement.next(previous: nil, screen: screen, size: CGSize(width: 310, height: 270))
        )
        XCTAssertEqual(placed.frame, expected)
        XCTAssertFalse(placed.collapsed)
    }

    func testAPlacedNoteIsNotPlacedAgainOnTheNextLaunch() throws {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200), now: clock.now())
        note.content = "x"
        store.save(note)
        let layout = makeLayout()
        _ = open(note, layout: layout, placing: { _ in NSRect(x: 30, y: 90, width: 240, height: 200) })
        layout.flush()

        var asked = 0
        _ = open(note, layout: makeLayout(), placing: { _ in asked += 1; return .zero })

        XCTAssertEqual(asked, 0)
    }

    func testTheDeskPlacesANoteWithNoLayoutEntryOnThePointersScreenAtItsHintedSize() throws {
        let isolated = IsolatedSettings()
        defer { isolated.tearDown() }
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 300, height: 260), now: clock.now())
        note.content = "x"
        store.save(note)
        let desk = DeskController(
            store: store, settings: isolated.settings, clock: clock, undo: UndoCenter(clock: clock),
            recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock), scheduler: scheduler
        )
        defer { desk.windowControllers.values.forEach { $0.window?.close() } }
        let screen = NotePlacement.screenUnderPointer(
            mouse: NSEvent.mouseLocation, screens: NSScreen.screens.map(\.visibleFrame), main: NSScreen.main?.visibleFrame
        ) ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        desk.presentWindow(for: note, activate: false)

        let expected = NotePlacement.next(previous: nil, screen: screen, size: CGSize(width: 300, height: 260))
        XCTAssertEqual(desk.layout.layout(for: note.id)?.frame, expected)
    }

    // MARK: - The old keys, for one release

    func testAFileThatStillHasTheOldKeysSeedsThisMacsLayoutOnce() throws {
        _ = try writeLegacyFile()
        let note = try loadLegacy()
        XCTAssertEqual(note.legacyPlacement, LegacyPlacement(x: 50, y: 140, collapsed: true))
        let layout = makeLayout()

        _ = open(note, layout: layout, placing: { _ in XCTFail("placed a note the file placed"); return .zero })

        XCTAssertEqual(layout.layout(for: legacyId), NoteLayout(x: 50, y: 140, width: 260, height: 210, collapsed: true))

        // The seed is used once: a later change of the old keys is not read again.
        var changed = note
        changed.legacyPlacement = LegacyPlacement(x: 700, y: 700, collapsed: false)
        _ = open(changed, layout: layout)
        XCTAssertEqual(layout.layout(for: legacyId)?.x, 50)
    }

    func testTheOldKeysStayInTheFileUntouchedThroughMovesAndContentSaves() throws {
        _ = try writeLegacyFile()
        let note = try loadLegacy()
        let layout = makeLayout()
        let controller = open(note, layout: layout)
        let url = try noteFile(for: legacyId)
        let before = try String(contentsOf: url, encoding: .utf8)

        try move(controller, to: NSPoint(x: 70, y: 170))
        scheduler.advance(by: 10)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before, "a move rewrote the file")

        controller.noteDocument.setBody("hello again")
        scheduler.advance(by: 1)

        let after = try String(contentsOf: url, encoding: .utf8)
        for line in ["positionX: 50.00", "positionY: 140.00", "collapsed: true", "tags: [a]", "# kept comment", "width: 260.00"] {
            XCTAssertTrue(after.contains(line), "\(line) changed in the file:\n\(after)")
        }
        XCTAssertEqual(after.components(separatedBy: "positionX").count, 2, "a second positionX line was written")
        XCTAssertTrue(after.hasSuffix("hello again"), after)
        XCTAssertFalse(after.contains("Conflicted copy"), after)
        XCTAssertEqual(layout.layout(for: legacyId)?.x, 70)
    }

    func testTheOldKeysAreKeptExactlyAsTheyWereByAWrite() throws {
        _ = try writeLegacyFile()
        let note = try loadLegacy()

        let text = store.recoveryText(for: note)

        for line in ["positionX: 50.00", "positionY: 140.00", "collapsed: true"] {
            XCTAssertTrue(text.contains("\n\(line)\n"), "\(line) changed:\n\(text)")
        }
    }

    func testChangedOrDroppedOldKeysAreNotAnOutsideChangeAndNotAConflict() throws {
        let url = try writeLegacyFile()
        let note = try loadLegacy()
        let document = NoteDocument(note: note, repository: store, scheduler: scheduler, clock: clock)
        var applied: [NoteDocument.Applied] = []
        document.didApplyExternal = { applied.append($0) }

        // A Mac on an older build moved the note, and one on a later build dropped the keys.
        let moved = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "positionX: 50.00", with: "positionX: 999.00")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("collapsed") }
            .joined(separator: "\n")
        try moved.write(to: url, atomically: true, encoding: .utf8)
        document.storeDidChange()

        XCTAssertTrue(applied.isEmpty, "a change of the old keys was taken for an edit of the note")
        document.setBody("hello again")
        scheduler.advance(by: 1)
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(after.hasSuffix("hello again"), after)
        XCTAssertFalse(after.contains("Conflicted copy"), after)
    }

    func testAnyGeometryDifferenceIsNotAReasonToMergeVersions() {
        var a = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200), now: Date(timeIntervalSince1970: 100))
        a.content = "same"
        a.legacyPlacement = LegacyPlacement(x: 1, y: 2, collapsed: false)
        var b = a
        b.width = 500
        b.height = 500
        b.legacyPlacement = LegacyPlacement(x: 900, y: 800, collapsed: true)
        b.updatedAt = Date(timeIntervalSince1970: 200)

        XCTAssertFalse(ConflictResolver.needsMerge([a, b]))
        XCTAssertEqual(ConflictResolver.merge([a, b])?.content, "same")
    }

    func testANewNoteFileNeverCarriesTheRetiredKeys() {
        let note = Note.makeNew(frame: NSRect(x: 5, y: 6, width: 240, height: 200), now: clock.now())

        let text = store.recoveryText(for: note)

        XCTAssertFalse(text.contains("positionX"))
        XCTAssertFalse(text.contains("positionY"))
        XCTAssertFalse(text.contains("collapsed"))
        XCTAssertTrue(text.contains("width: 240.00"))
        XCTAssertTrue(text.contains("height: 200.00"))
    }

    // MARK: - Per device

    func testCollapsingANoteOnOneMacLeavesItExpandedOnTheOther() throws {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200), now: clock.now())
        note.content = "shared"
        store.save(note)
        let laptop = makeLayout("laptop.json"), desktop = makeLayout("desktop.json")
        let laptopWindow = open(note, layout: laptop, placing: { _ in NSRect(x: 40, y: 80, width: 240, height: 200) })
        let url = try noteFile(for: note.id)
        let bytes = try Data(contentsOf: url)

        laptopWindow.dragZoneDidDoubleClick()
        laptop.flush()
        scheduler.advance(by: 10)

        XCTAssertEqual(laptop.layout(for: note.id)?.collapsed, true)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "collapsing wrote the note file")
        let otherMac = open(note, layout: desktop, placing: { _ in NSRect(x: 160, y: 200, width: 240, height: 200) })
        XCTAssertEqual(desktop.layout(for: note.id)?.collapsed, false)
        XCTAssertEqual(desktop.layout(for: note.id)?.x, 160, "the other Mac took this Mac's place")
        XCTAssertGreaterThan(try XCTUnwrap(otherMac.window).frame.height, NoteWindowController.collapsedHeight)
    }

    func testACollapsedNoteReopensCollapsedAfterARelaunch() throws {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200), now: clock.now())
        note.content = "x"
        store.save(note)
        let layout = makeLayout()
        let first = open(note, layout: layout, placing: { _ in NSRect(x: 40, y: 80, width: 240, height: 200) })
        first.dragZoneDidDoubleClick()
        layout.flush()
        first.window?.close()

        let second = open(note, layout: makeLayout())

        XCTAssertEqual(try XCTUnwrap(second.window).frame.height, NoteWindowController.collapsedHeight)
    }

    func testTheLayoutOfANoteSurvivesAStorageSwitch() throws {
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200), now: clock.now())
        note.content = "moves with me"
        store.save(note)
        let layout = makeLayout()
        let before = open(note, layout: layout, placing: { _ in NSRect(x: 33, y: 99, width: 240, height: 200) })
        let frame = try XCTUnwrap(before.window).frame
        layout.flush()
        before.window?.close()

        store.reconfigure(rootURL: directory.appendingPathComponent("other-vault", isDirectory: true))

        let moved = try XCTUnwrap(store.loadActive().first { $0.id == note.id })
        let after = open(moved, layout: makeLayout(), placing: { _ in XCTFail("placed it again"); return .zero })
        XCTAssertEqual(try XCTUnwrap(after.window).frame, frame)
    }

    func testBringingANoteBackFromTheArchiveOpensItExpanded() throws {
        let isolated = IsolatedSettings()
        defer { isolated.tearDown() }
        var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200), now: clock.now())
        note.content = "x"
        store.save(note)
        let desk = DeskController(
            store: store, settings: isolated.settings, clock: clock, undo: UndoCenter(clock: clock),
            recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock), scheduler: scheduler
        )
        desk.layout.set(NoteLayout(x: 40, y: 80, width: 240, height: 200, collapsed: true), for: note.id)
        store.archive(note)
        let url = try XCTUnwrap(
            fm.contentsOfDirectory(at: store.archiveURL, includingPropertiesForKeys: nil).first
        )
        let bytes = try Data(contentsOf: url)

        let observer = NotificationCenter.default.addObserver(
            forName: NoteStore.didChange, object: nil, queue: nil
        ) { note in
            nonisolated(unsafe) let notification = note
            MainActor.assumeIsolated { desk.storeDidChange(notification) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.restore(note)

        XCTAssertEqual(desk.layout.layout(for: note.id)?.collapsed, false)
        XCTAssertEqual(desk.layout.layout(for: note.id)?.x, 40, "it came back somewhere else")
        let restored = try noteFile(for: note.id)
        XCTAssertEqual(try Data(contentsOf: restored), bytes, "restoring rewrote the file to expand it")
    }

    func testRestoringANoteTheOldKeysLeftCollapsedOpensItExpandedBelowItsBar() throws {
        let isolated = IsolatedSettings()
        defer { isolated.tearDown() }
        _ = try writeLegacyFile()
        let note = try loadLegacy()
        let desk = DeskController(
            store: store, settings: isolated.settings, clock: clock, undo: UndoCenter(clock: clock),
            recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock), scheduler: scheduler
        )
        store.archive(note)
        let observer = NotificationCenter.default.addObserver(forName: NoteStore.didChange, object: nil, queue: nil) { note in
            nonisolated(unsafe) let notification = note
            MainActor.assumeIsolated { desk.storeDidChange(notification) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.restore(note)

        let entry = try XCTUnwrap(desk.layout.layout(for: legacyId))
        XCTAssertFalse(entry.collapsed)
        XCTAssertEqual(entry.x, 50)
        XCTAssertEqual(entry.y, 140 - (210 - Double(NoteWindowController.collapsedHeight)), "it grows upward from its bar")
        XCTAssertEqual(entry.height, 210)
    }

    // MARK: - Over full-screen apps

    func testAFloatingNoteShowsOverFullScreenAppsAndADesktopNoteDoesNot() {
        let floating = NoteWindow.collectionBehavior(for: .floating)
        let desktop = NoteWindow.collectionBehavior(for: .desktop)

        XCTAssertTrue(floating.contains(.fullScreenAuxiliary))
        XCTAssertTrue(floating.contains(.canJoinAllSpaces))
        XCTAssertFalse(desktop.contains(.fullScreenAuxiliary))
        XCTAssertFalse(desktop.contains(.canJoinAllSpaces))
    }

    func testTheWindowsCollectionBehaviourFollowsTheFloatLevel() throws {
        func note(_ level: NoteFloatLevel) -> Note {
            var note = Note.makeNew(frame: NSRect(x: 0, y: 0, width: 240, height: 200), now: clock.now())
            note.floatLevel = level
            return note
        }
        let floating = open(note(.floating), layout: makeLayout(), placing: { _ in NSRect(x: 0, y: 0, width: 240, height: 200) })
        let onDesktop = open(note(.desktop), layout: makeLayout(), placing: { _ in NSRect(x: 0, y: 0, width: 240, height: 200) })

        XCTAssertTrue(try XCTUnwrap(floating.window).collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(try XCTUnwrap(onDesktop.window).collectionBehavior.contains(.fullScreenAuxiliary))

        for (controller, level) in [(floating, NoteFloatLevel.desktop), (onDesktop, .floating)] {
            let item = NSMenuItem()
            item.representedObject = level.rawValue
            controller.perform(NSSelectorFromString("pickFloatLevel:"), with: item)
        }

        XCTAssertFalse(try XCTUnwrap(floating.window).collectionBehavior.contains(.fullScreenAuxiliary),
                       "a note put on the desktop still shows over full-screen apps")
        XCTAssertTrue(try XCTUnwrap(onDesktop.window).collectionBehavior.contains(.fullScreenAuxiliary),
                      "a note put back above everything does not")
    }
}
