// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "iPhoneAssistantCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "AssistantCore", targets: ["AssistantCore"]),
    ],
    targets: [
        .target(
            name: "AssistantCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "AssistantCoreTests",
            dependencies: ["AssistantCore"]
        ),
    ]
)
