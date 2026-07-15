// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ClickyAgentCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ClickyAgentCore",
            targets: ["ClickyAgentCore"]
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
        )
    ]
)
