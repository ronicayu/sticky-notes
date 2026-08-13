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
        .executableTarget(
            name: "StickyNotes",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "Sources/StickyNotes"
        )
    ]
)
