// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "imessage-mcp",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "IMessageMCPCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "imessage-mcp", dependencies: ["IMessageMCPCore"]),
        .testTarget(name: "IMessageMCPCoreTests", dependencies: ["IMessageMCPCore"]),
    ]
)
