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
        .library(name: "LibIPCProtobuf", targets: ["LibIPCProtobuf"]),
        .library(name: "LibIPCSecureCrypto", targets: ["LibIPCSecureCrypto"]),
        .executable(name: "demo-send-recv", targets: ["DemoSendRecv"]),
        .executable(name: "demo-chat",      targets: ["DemoChat"]),
        .executable(name: "demo-msg-que",   targets: ["DemoMsgQue"]),
        .executable(name: "bench-ipc",        targets: ["BenchIpc"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
        .package(url: "https://github.com/google/flatbuffers.git", from: "25.2.10"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.27.0"),
        .package(path: "../../secure-crypto-c"),
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
                .product(name: "FlatBuffers", package: "flatbuffers"),
            ],
            path: "Sources/LibIPC",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "LibIPCProtobuf",
            dependencies: [
                "LibIPC",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/LibIPCProtobuf",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "LibIPCSecureCrypto",
            dependencies: [
                "LibIPC",
                .product(name: "LibIPCSecureCryptoC", package: "secure-crypto-c"),
            ],
            path: "Sources/LibIPCSecureCrypto",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "DemoSendRecv",
            dependencies: ["LibIPC"],
            path: "Sources/Demos/DemoSendRecv"
        ),
        .executableTarget(
            name: "DemoChat",
            dependencies: ["LibIPC"],
            path: "Sources/Demos/DemoChat"
        ),
        .executableTarget(
            name: "DemoMsgQue",
            dependencies: ["LibIPC"],
            path: "Sources/Demos/DemoMsgQue"
        ),
        .executableTarget(
            name: "BenchIpc",
            dependencies: ["LibIPC"],
            path: "Sources/Bench/BenchIpc"
        ),
        .testTarget(
            name: "LibIPCTests",
            dependencies: [
                "LibIPC",
                .product(name: "FlatBuffers", package: "flatbuffers"),
            ],
            path: "Tests/LibIPCTests"
        ),
        .testTarget(
            name: "LibIPCProtobufTests",
            dependencies: [
                "LibIPC",
                "LibIPCProtobuf",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Tests/LibIPCProtobufTests"
        ),
        .testTarget(
            name: "LibIPCSecureCryptoTests",
            dependencies: [
                "LibIPC",
                "LibIPCSecureCrypto",
            ],
            path: "Tests/LibIPCSecureCryptoTests"
        ),
    ]
)
