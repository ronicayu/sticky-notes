import AppKit
import XCTest
@testable import StickyNotesKit

/// What one typed character costs the Markdown editor, in a 2 KB and a 50 KB
/// note. A benchmark, not an assertion: it prints the times so they can be
/// compared before and after a change. Skipped unless `STICKY_BENCH=1` is set:
/// `STICKY_BENCH=1 xctest .build/out/Products/Debug/StickyNotesTests.xctest -XCTest StickyNotesTests.RestyleBenchTests`
@MainActor final class RestyleBenchTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestyleBench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sample(sections: Int) -> String {
        (0..<sections).map { i in
            "## Section \(i)\n\nSome **bold** and *italic* with a [link](https://example.com/\(i)) and `code`, see [[Note \(i)]] or https://example.org/\(i).\n\n- [ ] task \(i)\n- plain item\n"
        }.joined(separator: "\n")
    }

    private func median(_ samples: [Double]) -> Double {
        samples.sorted()[samples.count / 2]
    }

    /// One keystroke the way the text view delivers it: the storage changes, the
    /// caret moves, then the delegate hears about it.
    private func typeCharacter(into editor: MarkdownEditorController, at location: Int) {
        let range = NSRange(location: location, length: 0)
        editor.textView.setSelectedRange(range)
        _ = editor.textView.shouldChangeText(in: range, replacementString: "x")
        editor.textStorage.replaceCharacters(in: range, with: "x")
        editor.textView.setSelectedRange(NSRange(location: location + 1, length: 0))
        editor.textView.didChangeText()
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        body()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    func testBenchmarkPerKeystrokeRestyle() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STICKY_BENCH"] == "1", "set STICKY_BENCH=1 to run")
        for (label, sections) in [("2 KB", 12), ("50 KB", 300)] {
            let text = sample(sections: sections)
            let store = NoteStore(rootURL: root)
            let editor = MarkdownEditorController(text: text, store: store, clock: ManualClock(), options: .note)
            let middle = (text as NSString).length / 2
            let spot = (text as NSString).range(of: "plain item", range: NSRange(location: middle, length: 400)).location

            var keystroke: [Double] = []
            for offset in 0..<15 {
                keystroke.append(milliseconds { typeCharacter(into: editor, at: spot + offset) })
            }
            var incremental: [Double] = []
            let restyler = MarkdownRestyler()
            let sliced = NSTextStorage(string: editor.textStorage.string)
            restyler.restyleAll(sliced)
            for offset in 0..<15 {
                let place = NSRange(location: spot + offset, length: 0)
                sliced.replaceCharacters(in: place, with: "x")
                incremental.append(milliseconds {
                    let slice = restyler.restyle(
                        sliced, edited: NSRange(location: place.location, length: 1), changeInLength: 1)
                    MarkdownStyler.updateMarkerVisibility(
                        in: sliced, selection: NSRange(location: place.location + 1, length: 0), within: slice)
                })
            }
            var styler: [Double] = []
            let storage = NSTextStorage(string: editor.textStorage.string)
            for _ in 0..<7 {
                styler.append(milliseconds {
                    MarkdownStyler.apply(to: storage)
                    MarkdownStyler.updateMarkerVisibility(in: storage, selection: NSRange(location: spot, length: 0))
                })
            }
            let visibility = milliseconds { editor.refreshMarkerVisibility() }
            print("  one marker-visibility refresh in the editor:", String(format: "%.2f", visibility), "ms")
            print("  restyle \(label) (\(text.utf8.count) bytes): keystroke through the editor median",
                  String(format: "%.2f", median(keystroke)), "ms; styler only: full pass median",
                  String(format: "%.2f", median(styler)), "ms, one-paragraph pass median",
                  String(format: "%.2f", median(incremental)), "ms")
        }
    }
}
