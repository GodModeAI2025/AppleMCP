// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "M3MCP",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(name: "M3MCPApp", targets: ["M3MCPApp"]),
        .executable(name: "M3MCPBridge", targets: ["M3MCPBridge"])
    ],
    targets: [
        .target(
            name: "M3MCPCore",
            path: "Sources/M3MCPCore"
        ),
        .executableTarget(
            name: "M3MCPApp",
            dependencies: ["M3MCPCore"],
            path: "Sources/M3MCPApp",
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/M3MCPApp/Resources/Info.plist",
                    // FoundationModels ships with macOS 26. Weak-linking keeps the app launchable on
                    // macOS 15, where a hard dependency would abort at load time.
                    "-Xlinker", "-weak_framework",
                    "-Xlinker", "FoundationModels"
                ])
            ]
        ),
        .executableTarget(
            name: "M3MCPBridge",
            dependencies: ["M3MCPCore"],
            path: "Sources/M3MCPBridge"
        ),
        .testTarget(
            name: "M3MCPCoreTests",
            dependencies: ["M3MCPCore"],
            path: "Tests/M3MCPCoreTests"
        )
    ]
)
