import AppKit
import XCTest
@testable import StickyNotesKit

/// What VoiceOver gets from the custom views, read through the NSAccessibility
/// API on the views themselves.
@MainActor final class NoteAccessibilityTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var isolated: IsolatedSettings!
    private var clock: ManualClock!
    private var scheduler: TestScheduler!
    private var undo: UndoCenter!
    private var desk: DeskController!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("A11y-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = ManualClock()
        scheduler = TestScheduler(clock: clock)
        store = NoteStore(rootURL: root, clock: clock)
        isolated = IsolatedSettings()
        undo = UndoCenter(clock: clock)
        desk = DeskController(
            store: store, settings: isolated.settings, clock: clock, undo: undo,
            recovery: RecoveryFiles(settings: isolated.settings, store: store, clock: clock),
            scheduler: scheduler,
            layout: DeviceLayoutStore(url: root.appendingPathComponent("layout.json"), scheduler: TestScheduler())
        )
        desk.motionDuration = { _ in 0 }
    }

    override func tearDown() async throws {
        scheduler.advance(by: 1)
        store?.stopWatching()
        desk.windowControllers.values.forEach { $0.window?.close() }
        isolated.tearDown()
        try? FileManager.default.removeItem(at: root)
    }

    private func open(
        _ title: String = "Groceries", content: String = "body", labels: [String] = []
    ) throws -> NoteWindowController {
        var note = Note.makeNew(frame: NSRect(x: 40, y: 40, width: 240, height: 200), now: clock.now())
        note.title = title
        note.content = content
        note.labels = labels
        store.save(note)
        desk.presentWindow(for: note)
        return try XCTUnwrap(desk.windowControllers[note.id])
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view = view else { return [] }
        return (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { views(type, in: $0) }
    }

    private func all<T: NSView>(_ type: T.Type, in controller: NoteWindowController) -> [T] {
        var found: [T] = []
        func walk(_ view: NSView) {
            if let match = view as? T { found.append(match) }
            view.subviews.forEach(walk)
        }
        if let content = controller.window?.contentView { walk(content) }
        return found
    }

    private func button(labelled label: String, in controller: NoteWindowController) throws -> NSButton {
        try XCTUnwrap(all(NSButton.self, in: controller).first { $0.accessibilityLabel() == label }, "no button \(label)")
    }

    // MARK: - Label chips

    func testAChipIsAButtonThatSaysItRemovesItsLabel() {
        let chip = LabelChipView(labelName: "work")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40), styleMask: [], backing: .buffered, defer: true)
        window.contentView?.addSubview(chip)
        var removed = 0
        chip.onRemove = { removed += 1 }

        XCTAssertTrue(chip.isAccessibilityElement())
        XCTAssertEqual(chip.accessibilityRole(), .button)
        XCTAssertEqual(chip.accessibilityLabel(), "#work, remove")
        XCTAssertTrue(chip.accessibilityPerformPress())
        XCTAssertEqual(removed, 1)
        chip.performClick(nil)
        XCTAssertEqual(removed, 2)
    }

    func testRemovingALabelWithItsChipOffersAnUndoThatPutsItBackWhereItWas() throws {
        let controller = try open(labels: ["home", "work", "later"])
        let chip = try XCTUnwrap(all(LabelChipView.self, in: controller).first { $0.labelName == "work" })

        chip.performClick(nil)

        XCTAssertEqual(controller.labels, ["home", "later"])
        XCTAssertTrue(undo.hasPendingOffer)
        undo.undoLastAction(nil)
        XCTAssertEqual(controller.labels, ["home", "work", "later"])
        XCTAssertEqual(all(LabelChipView.self, in: controller).map(\.labelName), ["home", "work", "later"])
    }

    func testTakingBackALabelRemovalTwiceDoesNotDuplicateTheLabel() throws {
        let controller = try open(labels: ["work"])
        var restore: (() -> Void)?
        controller.onLabelRemoved = { _, undo in restore = undo }

        try XCTUnwrap(all(LabelChipView.self, in: controller).first).performClick(nil)
        XCTAssertEqual(controller.labels, [])
        try XCTUnwrap(restore)()
        try XCTUnwrap(restore)()

        XCTAssertEqual(controller.labels, ["work"])
    }

    func testTheLabelMenuStaysAToggleWithNoToast() throws {
        let controller = try open(labels: ["work"])
        let menu = controller.makeLabelMenu()
        let item = try XCTUnwrap(menu.items.first { $0.title == "#work" })

        _ = item.target?.perform(item.action, with: item)

        XCTAssertEqual(controller.labels, [])
        XCTAssertFalse(undo.hasPendingOffer)
    }

    func testTheRemovalToastNamesTheLabel() {
        XCTAssertEqual(Toast.labelRemovedMessage(label: "work"), "Removed #work")
    }

    // MARK: - Collapsed bar

    func testACollapsedNoteOffersItsTitleBarAsAButtonThatExpandsIt() throws {
        let controller = try open("Groceries")
        controller.toggleCollapse()
        let bar = try XCTUnwrap(all(CenteredTitleLabel.self, in: controller).first)

        XCTAssertFalse(bar.isHidden)
        XCTAssertTrue(bar.isAccessibilityElement())
        XCTAssertEqual(bar.accessibilityRole(), .button)
        XCTAssertEqual(bar.accessibilityLabel(), "Groceries, collapsed note, click to expand")

        XCTAssertTrue(bar.accessibilityPerformPress())
        XCTAssertFalse(controller.isCollapsed)
        XCTAssertTrue(bar.isHidden, "an expanded note should not expose the collapsed bar")
    }

    func testTheCollapsedBarSaysUntitledAndTaskProgressInWords() throws {
        let controller = try open("", content: "- [x] a\n- [ ] b")
        controller.toggleCollapse()
        let bar = try XCTUnwrap(all(CenteredTitleLabel.self, in: controller).first)

        XCTAssertEqual(bar.accessibilityLabel(), "Untitled, 1 of 2 tasks done, collapsed note, click to expand")
    }

    func testTheDailyNoteTitleIsPlainText() {
        let label = CenteredTitleLabel(frame: .zero)
        label.text = "Daily Note · Nov 15"
        XCTAssertEqual(label.accessibilityRole(), .staticText)
        XCTAssertEqual(label.accessibilityLabel(), "Daily Note · Nov 15")
        XCTAssertFalse(label.accessibilityPerformPress())
    }

    // MARK: - Top bar

    func testTheDragStripIsADescribedGroupWithACollapseAction() throws {
        let controller = try open()
        let strip = try XCTUnwrap(all(NoteDragZone.self, in: controller).first)

        XCTAssertTrue(strip.isAccessibilityElement())
        XCTAssertEqual(strip.accessibilityRole(), .group)
        XCTAssertEqual(strip.accessibilityLabel(), "Note top bar")
        XCTAssertEqual(strip.accessibilityHelp(), "Drag to move the note. Double-click to collapse or expand it.")

        var actions = try XCTUnwrap(strip.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), ["Collapse note"])
        XCTAssertTrue(try XCTUnwrap(actions[0].handler)())
        XCTAssertTrue(controller.isCollapsed)

        actions = try XCTUnwrap(strip.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), ["Expand note"])
        XCTAssertTrue(try XCTUnwrap(actions[0].handler)())
        XCTAssertFalse(controller.isCollapsed)
    }

    // MARK: - Chrome buttons

    func testTheChromeButtonsSayWhatTheyDoAndTheColorButtonSaysTheColor() throws {
        let controller = try open()

        let expand = try button(labelled: "Collapse note", in: controller)
        XCTAssertEqual(expand.accessibilityRole(), .button)
        controller.toggleCollapse()
        XCTAssertEqual(expand.accessibilityLabel(), "Expand note")

        let color = try button(labelled: "Color and float level", in: controller)
        XCTAssertEqual(color.accessibilityRole(), .menuButton)
        XCTAssertEqual(color.accessibilityValue() as? String, controller.color.displayName)
        controller.setColor(.blue)
        XCTAssertEqual(color.accessibilityValue() as? String, NoteColor.blue.displayName)

        XCTAssertEqual(try button(labelled: "Labels", in: controller).accessibilityRole(), .menuButton)
        XCTAssertEqual(try button(labelled: "Archive note", in: controller).accessibilityRole(), .button)
    }

    // MARK: - Resize grip

    func testTheResizeGripResizesByActionAndKeepsTheTopLeftCorner() throws {
        let controller = try open()
        let window = try XCTUnwrap(controller.window)
        let grip = try XCTUnwrap(all(ResizeGripView.self, in: controller).first)
        XCTAssertTrue(grip.isAccessibilityElement())
        XCTAssertEqual(grip.accessibilityRole(), .growArea)
        XCTAssertEqual(grip.accessibilityLabel(), "Resize note")
        let actions = try XCTUnwrap(grip.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), ["Make wider", "Make narrower", "Make taller", "Make shorter"])

        let before = window.frame
        XCTAssertTrue(try XCTUnwrap(actions[0].handler)())
        XCTAssertEqual(window.frame.width, before.width + 40, accuracy: 0.5)
        XCTAssertTrue(try XCTUnwrap(actions[2].handler)())
        XCTAssertEqual(window.frame.height, before.height + 40, accuracy: 0.5)
        XCTAssertEqual(window.frame.maxY, before.maxY, accuracy: 0.5, "the top edge moved")
        XCTAssertEqual(window.frame.minX, before.minX, accuracy: 0.5)
    }

    func testResizingByActionNearTheScreenEdgeStopsGrowingInsteadOfMovingTheNote() throws {
        let controller = try open()
        let window = try XCTUnwrap(controller.window)
        let screen = try XCTUnwrap(NSScreen.main?.visibleFrame, "no screen")
        window.setFrame(
            NSRect(x: screen.maxX - 250, y: screen.minY + 30, width: 240, height: 200), display: false
        )
        let grip = try XCTUnwrap(all(ResizeGripView.self, in: controller).first)
        let actions = try XCTUnwrap(grip.accessibilityCustomActions())
        let before = window.frame

        XCTAssertTrue(try XCTUnwrap(actions[0].handler)())
        XCTAssertTrue(try XCTUnwrap(actions[2].handler)())

        XCTAssertEqual(window.frame.minX, before.minX, accuracy: 0.5, "the left edge moved")
        XCTAssertEqual(window.frame.maxY, before.maxY, accuracy: 0.5, "the top edge moved")
        XCTAssertLessThanOrEqual(window.frame.maxX, screen.maxX + 0.5)
        XCTAssertGreaterThanOrEqual(window.frame.minY, screen.minY - 0.5)
    }

    func testTheResizeGripIsNotThereForACollapsedNote() throws {
        let controller = try open()
        controller.toggleCollapse()
        let grip = try XCTUnwrap(all(ResizeGripView.self, in: controller).first)
        XCTAssertFalse(grip.isAccessibilityElement())
        controller.toggleCollapse()
        XCTAssertTrue(grip.isAccessibilityElement())
    }

    // MARK: - Checkboxes

    private func checkBoxes(of controller: NoteWindowController) -> [NSAccessibilityElement] {
        let children = controller.textView.accessibilityChildren() ?? []
        return children.compactMap { $0 as? NSAccessibilityElement }.filter { $0.accessibilityRole() == .checkBox }
    }

    func testEachCheckboxReportsItsStateAndTogglesWhenPressed() throws {
        let controller = try open(content: "- [ ] **Buy** milk\n- [x] Call mum\nplain line")
        var boxes = checkBoxes(of: controller)

        XCTAssertEqual(boxes.count, 2)
        XCTAssertEqual(boxes.map { $0.accessibilityLabel() }, ["Buy milk", "Call mum"])
        XCTAssertEqual(boxes.map { ($0.accessibilityValue() as? NSNumber)?.intValue }, [0, 1])
        XCTAssertTrue(boxes.allSatisfy { $0.accessibilityParent() as AnyObject === controller.textView })

        XCTAssertTrue(boxes[0].accessibilityPerformPress())

        XCTAssertEqual(controller.textView.string, "- [x] **Buy** milk\n- [x] Call mum\nplain line")
        XCTAssertEqual(controller.bufferedNote.content, controller.textView.string, "the press was not an edit of the note")
        boxes = checkBoxes(of: controller)
        XCTAssertEqual(boxes.map { ($0.accessibilityValue() as? NSNumber)?.intValue }, [1, 1])

        XCTAssertTrue(boxes[1].accessibilityPerformPress())
        XCTAssertEqual(checkBoxes(of: controller).map { ($0.accessibilityValue() as? NSNumber)?.intValue }, [1, 0])
    }

    func testAnElementWhoseBoxHasMovedDoesNothingAndReadsSafely() throws {
        let controller = try open(content: "- [ ] one\nplain [ text")
        let stale = try XCTUnwrap(checkBoxes(of: controller).first)

        controller.editor.replaceText("Added above\n\n- [ ] one\nplain [ text")
        let before = controller.textView.string

        XCTAssertFalse(stale.accessibilityPerformPress(), "a press landed on whatever is at the old place")
        XCTAssertEqual(controller.textView.string, before)
        XCTAssertNil(stale.accessibilityLabel())
        XCTAssertNil(stale.accessibilityValue())
        XCTAssertEqual(stale.accessibilityFrame(), .zero)

        controller.editor.replaceText("x")
        XCTAssertFalse(stale.accessibilityPerformPress())
        XCTAssertNil(stale.accessibilityLabel())
        XCTAssertNil(stale.accessibilityValue())
        XCTAssertEqual(stale.accessibilityFrame(), .zero)
        XCTAssertEqual(controller.textView.checkboxTitle(afterMarker: NSRange(location: 5, length: 20)), "")
        XCTAssertEqual(controller.textView.string, "x")
    }

    func testTheCheckboxElementsAreKeptWhileTheirBoxesStayAndRenewedWhenTheyMove() throws {
        let controller = try open(content: "- [ ] one\n- [ ] two")
        let first = checkBoxes(of: controller)
        XCTAssertTrue(first[0].accessibilityPerformPress())
        let again = checkBoxes(of: controller)
        XCTAssertTrue(zip(first, again).allSatisfy { $0 === $1 }, "VoiceOver's focus would jump after a toggle")

        controller.editor.replaceText("Above\n- [x] one\n- [ ] two")
        let moved = checkBoxes(of: controller)
        XCTAssertEqual(moved.count, 2)
        XCTAssertFalse(zip(first, moved).contains { $0 === $1 })
        XCTAssertEqual(moved.map { $0.accessibilityLabel() }, ["one", "two"])
        XCTAssertEqual(moved.map { ($0.accessibilityValue() as? NSNumber)?.intValue }, [1, 0])
    }

    func testANoteWithoutTasksExposesNoCheckboxes() throws {
        XCTAssertTrue(checkBoxes(of: try open(content: "just words")).isEmpty)
    }

    // MARK: - Rows

    func testARowOfTheNotesPanelReadsAsOneSentence() {
        var note = Note.makeNew(frame: .zero, now: Date())
        note.title = "Groceries"
        note.content = "- [x] eggs\n- [ ] milk"
        note.labels = ["home"]
        let cell = NotesPanelCell()
        cell.configure(with: NoteMatch(note: note, score: 0, excerpt: "Groceries"))

        XCTAssertTrue(cell.isAccessibilityElement())
        XCTAssertTrue((cell.accessibilityChildren() ?? []).isEmpty)
        let spoken = cell.accessibilityLabel() ?? ""
        XCTAssertTrue(spoken.hasPrefix("Groceries, 1 of 2 tasks done, #home, "), spoken)
    }

    func testARowOfTheQuickSwitcherReadsAsOneSentenceAndSaysArchived() {
        var note = Note.makeNew(frame: .zero, now: Date())
        note.title = ""
        note.content = "Call the dentist"
        let cell = QuickSwitcherCell()
        cell.configure(with: NoteMatch(note: note, score: 0, excerpt: "Call the dentist"), archived: true)

        XCTAssertTrue(cell.isAccessibilityElement())
        XCTAssertEqual(cell.accessibilityLabel(), "Call the dentist, just now, archived")
    }

    func testAnEmptyNoteRowSaysSo() {
        XCTAssertEqual(
            NoteRowAccessibility.label(heading: "", progress: nil, detail: "", trailing: "2 min. ago"),
            "Empty note, 2 min. ago"
        )
    }

    // MARK: - Settings

    @MainActor private final class NoCoordinator: SettingsCoordinator {
        func applyStorageMode(_ mode: SettingsWindowController.StorageMode) {}
        func applyDailyPattern(_ pattern: String?) {}
        func applyDailyTemplate(_ path: String?) {}
        func revealStorageFolder() {}
        func openTodaysDailyNote() {}
    }

    func testTheDefaultColorSwatchesAreNamedAndOneIsSelected() throws {
        let coordinator = NoCoordinator()
        isolated.settings.defaultNoteColor = .green
        let settings = SettingsWindowController(coordinator: coordinator, settings: isolated.settings)
        var swatches: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton, NoteColor(rawValue: button.identifier?.rawValue ?? "") != nil {
                swatches.append(button)
            }
            view.subviews.forEach(walk)
        }
        walk(try XCTUnwrap(settings.window?.contentView))

        XCTAssertEqual(swatches.count, NoteColor.allCases.count)
        for swatch in swatches {
            let color = try XCTUnwrap(NoteColor(rawValue: swatch.identifier?.rawValue ?? ""))
            XCTAssertEqual(swatch.accessibilityLabel(), color.displayName)
            XCTAssertEqual(swatch.accessibilityRole(), .radioButton)
            XCTAssertEqual((swatch.accessibilityValue() as? NSNumber)?.intValue, color == .green ? 1 : 0)
        }
    }
}
