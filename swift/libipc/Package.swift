// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "libipc",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "LibIPC", targets: ["LibIPC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "LibIPCShim",
            path: "Sources/LibIPCShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "LibIPC",
            dependencies: [
                "LibIPCShim",
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            path: "Sources/LibIPC",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "LibIPCTests",
            dependencies: ["LibIPC"],
            path: "Tests/LibIPCTests"
        ),
    ]
)
