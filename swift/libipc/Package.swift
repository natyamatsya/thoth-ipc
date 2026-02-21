// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "libipc",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "LibIPC", targets: ["LibIPC"]),
    ],
    targets: [
        .target(
            name: "LibIPC",
            path: "Sources/LibIPC"
        ),
        .testTarget(
            name: "LibIPCTests",
            dependencies: ["LibIPC"],
            path: "Tests/LibIPCTests"
        ),
    ]
)
