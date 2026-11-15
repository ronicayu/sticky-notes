import Foundation
@testable import StickyNotesKit

/// A clock the test moves by hand.
final class ManualClock: AppClock {
    var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    func now() -> Date { current }

    func advance(by seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }
}

/// `Settings` over a throwaway `UserDefaults` suite and two temp folders, so a
/// test never reads or writes the developer's real preferences or storage.
/// Call `tearDown()` when done: suites persist as plist files otherwise.
final class IsolatedSettings {
    let settings: Settings
    /// Stands in for `~/Library/Application Support`.
    let localRoot: URL
    /// Stands in for iCloud Drive; the folder does not exist, so iCloud reads as unavailable.
    let iCloudRoot: URL
    private let suiteName: String
    private let directory: URL

    init() {
        suiteName = "StickyNotesTests-\(UUID().uuidString)"
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IsolatedSettings-\(UUID().uuidString)", isDirectory: true)
        localRoot = directory.appendingPathComponent("local", isDirectory: true)
        iCloudRoot = directory.appendingPathComponent("icloud", isDirectory: true)
        try? FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        settings = Settings(
            defaults: UserDefaults(suiteName: suiteName)!,
            localRootURL: localRoot,
            iCloudRootURL: iCloudRoot
        )
    }

    func tearDown() {
        settings.defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
