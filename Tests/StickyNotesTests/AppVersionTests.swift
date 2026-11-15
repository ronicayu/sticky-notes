import XCTest
@testable import StickyNotesKit

final class AppVersionTests: XCTestCase {
    func testAStampedBundleShowsItsVersion() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.9.0", "CFBundleVersion": "412"]
        XCTAssertEqual(AppVersion.displayString(info: info), "v0.9.0")
    }

    func testAnUnstampedVersionShowsDev() {
        let info: [String: Any] = ["CFBundleShortVersionString": "__APP_VERSION__", "CFBundleVersion": "412"]
        XCTAssertEqual(AppVersion.displayString(info: info), "dev")
    }

    func testAnUnstampedBuildNumberShowsDev() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.9.0", "CFBundleVersion": "__BUILD_NUMBER__"]
        XCTAssertEqual(AppVersion.displayString(info: info), "dev")
    }

    func testMissingOrEmptyKeysShowDev() {
        XCTAssertEqual(AppVersion.displayString(info: [:]), "dev")
        XCTAssertEqual(
            AppVersion.displayString(info: ["CFBundleShortVersionString": "", "CFBundleVersion": "1"]),
            "dev"
        )
        XCTAssertEqual(
            AppVersion.displayString(info: ["CFBundleShortVersionString": "0.9.0"]),
            "dev"
        )
    }
}
