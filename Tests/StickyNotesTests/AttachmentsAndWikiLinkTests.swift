import AppKit
import XCTest
@testable import StickyNotesKit

final class AttachmentsTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NoteStore(rootURL: root, format: .markdown)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func pngData(_ size: NSSize = NSSize(width: 4, height: 4)) throws -> Data {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    }

    func testSavedImageLandsInTheAttachmentsFolder() throws {
        let reference = try XCTUnwrap(Attachments.save(imageData: try pngData(), fileExtension: "png", for: store))
        let file = try XCTUnwrap(Attachments.resolve(reference, for: store))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "no file at \(file.path)")
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, "attachments")
    }

    /// Notes live in `notes/`, so the reference has to climb out of it for
    /// Obsidian to resolve the same path we do.
    func testReferenceIsRelativeToTheNotesFolder() throws {
        let reference = try XCTUnwrap(Attachments.save(imageData: try pngData(), fileExtension: "png", for: store))
        XCTAssertTrue(reference.hasPrefix("../attachments/"), "got \(reference)")
    }

    func testResolvedPathMatchesTheFileOnDisk() throws {
        let reference = try XCTUnwrap(Attachments.save(imageData: try pngData(), fileExtension: "png", for: store))
        let resolved = try XCTUnwrap(Attachments.resolve(reference, for: store))
        let listed = try FileManager.default.contentsOfDirectory(
            at: Attachments.directory(for: store), includingPropertiesForKeys: nil
        )
        XCTAssertEqual(resolved.standardizedFileURL.lastPathComponent, listed.first?.lastPathComponent)
    }

    func testTwoImagesSavedInTheSameSecondDoNotCollide() throws {
        let now = Date()
        let first = try XCTUnwrap(Attachments.save(imageData: try pngData(), fileExtension: "png", for: store, now: now))
        let second = try XCTUnwrap(Attachments.save(imageData: try pngData(), fileExtension: "png", for: store, now: now))
        XCTAssertNotEqual(first, second)

        let listed = try FileManager.default.contentsOfDirectory(
            at: Attachments.directory(for: store), includingPropertiesForKeys: nil
        )
        XCTAssertEqual(listed.count, 2, "the second image overwrote the first")
    }

    func testCopiedFileKeepsItsOriginalName() throws {
        let source = root.appendingPathComponent("diagram.png")
        try pngData().write(to: source)

        let reference = try XCTUnwrap(Attachments.copy(fileAt: source, for: store))
        XCTAssertEqual((reference as NSString).lastPathComponent, "diagram.png")
    }

    func testCopyingATakenNameFallsBackToATimestamp() throws {
        let source = root.appendingPathComponent("diagram.png")
        try pngData().write(to: source)

        let first = try XCTUnwrap(Attachments.copy(fileAt: source, for: store))
        let second = try XCTUnwrap(Attachments.copy(fileAt: source, for: store))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try XCTUnwrap(Attachments.resolve(first, for: store)).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try XCTUnwrap(Attachments.resolve(second, for: store)).path))
    }

    func testImagesUseImageMarkdownAndOtherFilesUsePlainLinks() {
        XCTAssertEqual(Attachments.markdown(for: "../attachments/a.png", isImage: true),
                       "![a.png](../attachments/a.png)")
        XCTAssertEqual(Attachments.markdown(for: "../attachments/report.pdf", isImage: false),
                       "[report.pdf](../attachments/report.pdf)")
    }

    func testImageExtensionsAreRecognized() {
        for ext in ["png", "jpg", "jpeg", "gif", "heic", "PNG"] {
            XCTAssertTrue(Attachments.isImageExtension(ext), "\(ext) should be an image")
        }
        for ext in ["pdf", "txt", "zip", "md"] {
            XCTAssertFalse(Attachments.isImageExtension(ext), "\(ext) should not be an image")
        }
    }

    func testAbsolutePathsAndURLsResolveUnchanged() throws {
        let absolute = try XCTUnwrap(Attachments.resolve("/tmp/x.png", for: store))
        XCTAssertEqual(absolute.path, "/tmp/x.png")

        let remote = try XCTUnwrap(Attachments.resolve("https://example.com/x.png", for: store))
        XCTAssertEqual(remote.scheme, "https")
    }

    func testPasteWithNothingUsefulReturnsNil() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AttachmentsTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("just some text", forType: .string)
        XCTAssertNil(Attachments.handlePaste(pasteboard, for: store),
                     "plain text should fall through to a normal paste")
    }

    func testPastingImageDataSavesAnAttachment() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AttachmentsTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(try pngData(), forType: .png)

        let markdown = try XCTUnwrap(Attachments.handlePaste(pasteboard, for: store))
        XCTAssertTrue(markdown.hasPrefix("!["), "expected image markdown, got \(markdown)")

        let reference = String(markdown[markdown.index(after: markdown.firstIndex(of: "(")!)..<markdown.lastIndex(of: ")")!])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try XCTUnwrap(Attachments.resolve(reference, for: store)).path))
    }
}

final class WikiLinkTests: XCTestCase {

    private func note(title: String = "", content: String = "") -> Note {
        Note(
            id: UUID(), title: title, content: content,
            positionX: 0, positionY: 0, width: 1, height: 1,
            collapsed: false, color: .yellow, labels: [],
            createdAt: Date(), updatedAt: Date()
        )
    }

    func testURLRoundTripsTheTarget() throws {
        let url = try XCTUnwrap(WikiLink.url(for: "Some Note"))
        XCTAssertEqual(WikiLink.target(of: url), "Some Note")
    }

    func testTargetsWithAwkwardCharactersSurvive() throws {
        for target in ["a/b", "Q3 & Q4", "café", "100% done", "a?b=c"] {
            let url = try XCTUnwrap(WikiLink.url(for: target), "no URL for \(target)")
            XCTAssertEqual(WikiLink.target(of: url), target)
        }
    }

    func testEmptyTargetsProduceNoURL() {
        XCTAssertNil(WikiLink.url(for: ""))
        XCTAssertNil(WikiLink.url(for: "   "))
    }

    func testOtherSchemesAreNotWikiLinks() throws {
        XCTAssertNil(WikiLink.target(of: try XCTUnwrap(URL(string: "https://example.com"))))
    }

    func testResolvesByTitleIgnoringCase() throws {
        let notes = [note(title: "Groceries"), note(title: "Standup")]
        XCTAssertEqual(WikiLink.resolve("groceries", in: notes)?.id, notes[0].id)
        XCTAssertEqual(WikiLink.resolve("  STANDUP  ", in: notes)?.id, notes[1].id)
    }

    /// An untitled note is known by its first line everywhere else in the UI,
    /// so a wiki link should find it the same way.
    func testResolvesAnUntitledNoteByItsFirstLine() throws {
        let notes = [note(content: "Call the dentist\nmore detail here")]
        XCTAssertEqual(WikiLink.resolve("Call the dentist", in: notes)?.id, notes[0].id)
    }

    func testUnknownTargetsResolveToNothing() {
        XCTAssertNil(WikiLink.resolve("No Such Note", in: [note(title: "Groceries")]))
        XCTAssertNil(WikiLink.resolve("anything", in: []))
    }

    func testTitleMatchWinsOverAFirstLineMatch() throws {
        let byLine = note(content: "Plan\nbody")
        let byTitle = note(title: "Plan", content: "different body")
        XCTAssertEqual(WikiLink.resolve("Plan", in: [byLine, byTitle])?.id, byTitle.id)
    }

    func testObsidianURLNamesTheVaultAndFile() throws {
        let url = try XCTUnwrap(WikiLink.obsidianURL(vaultPath: "/Users/x/Notes Vault", target: "Daily/2026-03-04"))
        XCTAssertEqual(url.scheme, "obsidian")
        XCTAssertEqual(url.host, "open")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first(where: { $0.name == "vault" })?.value, "Notes Vault")
        XCTAssertEqual(items.first(where: { $0.name == "file" })?.value, "Daily/2026-03-04")
    }

    // MARK: - Styling

    private func styled(_ source: String) -> NSTextStorage {
        let storage = NSTextStorage(string: source)
        MarkdownStyler.apply(to: storage)
        return storage
    }

    func testWikiLinkTextIsLinked() {
        let source = "see [[Groceries]] for the list"
        let storage = styled(source)
        let at = (source as NSString).range(of: "Groceries").location
        let value = storage.attribute(.link, at: at, effectiveRange: nil)
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        XCTAssertEqual(url.flatMap(WikiLink.target(of:)), "Groceries")
    }

    func testWikiLinkBracketsAreMarkers() {
        let storage = styled("see [[Groceries]] now")
        var markers: [String] = []
        let ns = storage.string as NSString
        storage.enumerateAttribute(.mdMarkerScope, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { markers.append(ns.substring(with: range)) }
        }
        XCTAssertEqual(markers, ["[[", "]]"])
    }

    func testWikiLinkInsideCodeIsLiteral() {
        let source = "type `[[Groceries]]` to link"
        let storage = styled(source)
        let at = (source as NSString).range(of: "Groceries").location
        XCTAssertNil(storage.attribute(.link, at: at, effectiveRange: nil))
    }

    func testSingleBracketsAreNotWikiLinks() {
        let storage = styled("a [bracketed] phrase")
        XCTAssertNil(storage.attribute(.link, at: 3, effectiveRange: nil))
    }
}
