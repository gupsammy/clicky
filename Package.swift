// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ClickyCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ClickyAgentCore",
            targets: ["ClickyAgentCore"]
        ),
        .library(
            name: "ClickyDictationCore",
            targets: ["ClickyDictationCore"]
        )
    ],
    targets: [
        .target(
            name: "ClickyAgentCore",
            path: "leanring-buddy/AgentCore"
        ),
        .testTarget(
            name: "ClickyAgentCoreTests",
            dependencies: ["ClickyAgentCore"],
            path: "AgentCoreTests"
        ),
        .target(
            name: "ClickyDictationCore",
            path: "leanring-buddy/DictationCore"
        ),
        .testTarget(
            name: "ClickyDictationCoreTests",
            dependencies: ["ClickyDictationCore"],
            path: "DictationCoreTests"
        )
    ]
)
