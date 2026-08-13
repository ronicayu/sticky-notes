// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StickyNotes",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-markdown", from: "0.4.0")
    ],
    targets: [
        // All app code lives here so the test target can import it. The
        // executable is only the NSApplication bootstrap.
        .target(
            name: "StickyNotesKit",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "Sources/StickyNotesKit"
        ),
        .executableTarget(
            name: "StickyNotes",
            dependencies: ["StickyNotesKit"],
            path: "Sources/StickyNotes"
        ),
        .testTarget(
            name: "StickyNotesTests",
            dependencies: [
                "StickyNotesKit",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Tests/StickyNotesTests"
        )
    ]
)
