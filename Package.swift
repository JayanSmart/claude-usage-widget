// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "ClaudeUsageCore",
            path: "Sources/ClaudeUsageCore"
        ),
        .executableTarget(
            name: "ClaudeUsage",
            dependencies: ["ClaudeUsageCore"],
            path: "Sources/ClaudeUsage",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
                .linkedFramework("WebKit"),
            ]
        ),
        .executableTarget(
            name: "ClaudeUsageTests",
            dependencies: ["ClaudeUsageCore"],
            path: "Tests/ClaudeUsageTests"
        ),
    ]
)
