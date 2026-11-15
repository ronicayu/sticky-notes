import AppKit
import StickyNotesKit

// Before anything reads a note: a file that is only in iCloud then fails to read
// at once on this thread, instead of freezing the app until it has downloaded.
DatalessFiles.refuseMaterializingOnThisThread()

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
