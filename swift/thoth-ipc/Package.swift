// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "thoth-ipc",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ThothIPC", targets: ["ThothIPC"]),
        .library(name: "ThothIPCProtobuf", targets: ["ThothIPCProtobuf"]),
        .library(name: "ThothIPCSecureCrypto", targets: ["ThothIPCSecureCrypto"]),
        .executable(name: "demo-send-recv", targets: ["DemoSendRecv"]),
        .executable(name: "demo-chat",      targets: ["DemoChat"]),
        .executable(name: "demo-channel-aggregator", targets: ["DemoChannelAggregator"]),
        .executable(name: "demo-pipeline",  targets: ["DemoPipeline"]),
        .executable(name: "demo-bounded-buffer", targets: ["DemoBoundedBuffer"]),
        .executable(name: "demo-msg-que",   targets: ["DemoMsgQue"]),
        .executable(name: "bench-ipc",        targets: ["BenchIpc"]),
        .executable(name: "xlang-harness",    targets: ["XlangHarness"]),
    ],
    dependencies: [
        .package(path: "vendor/swift-atomics"),
        .package(path: "vendor/flatbuffers"),
        .package(path: "vendor/swift-protobuf"),
        .package(path: "../../secure-crypto-c"),
    ],
    targets: [
        .target(
            name: "ThothIPCShim",
            path: "Sources/ThothIPCShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "ThothIPC",
            dependencies: [
                "ThothIPCShim",
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "FlatBuffers", package: "flatbuffers"),
            ],
            path: "Sources/ThothIPC",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ThothIPCProtobuf",
            dependencies: [
                "ThothIPC",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/ThothIPCProtobuf",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "ThothIPCSecureCrypto",
            dependencies: [
                "ThothIPC",
                .product(name: "LibIPCSecureCryptoC", package: "secure-crypto-c"),
            ],
            path: "Sources/ThothIPCSecureCrypto",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "DemoSendRecv",
            dependencies: ["ThothIPC"],
            path: "Sources/Demos/DemoSendRecv"
        ),
        .executableTarget(
            name: "XlangHarness",
            dependencies: ["ThothIPC", "ThothIPCSecureCrypto"],
            path: "Sources/XlangHarness"
        ),
        .executableTarget(
            name: "DemoChat",
            dependencies: ["ThothIPC"],
            path: "Sources/Demos/DemoChat"
        ),
        .executableTarget(
            name: "DemoChannelAggregator",
            dependencies: ["ThothIPC"],
            path: "Sources/Demos/DemoChannelAggregator"
        ),
        .executableTarget(
            name: "DemoPipeline",
            dependencies: ["ThothIPC"],
            path: "Sources/Demos/DemoPipeline"
        ),
        .executableTarget(
            name: "DemoBoundedBuffer",
            dependencies: ["ThothIPC"],
            path: "Sources/Demos/DemoBoundedBuffer"
        ),
        .executableTarget(
            name: "DemoMsgQue",
            dependencies: ["ThothIPC"],
            path: "Sources/Demos/DemoMsgQue"
        ),
        .executableTarget(
            name: "BenchIpc",
            dependencies: ["ThothIPC"],
            path: "Sources/Bench/BenchIpc"
        ),
        .testTarget(
            name: "ThothIPCTests",
            dependencies: [
                "ThothIPC",
                .product(name: "FlatBuffers", package: "flatbuffers"),
            ],
            path: "Tests/ThothIPCTests"
        ),
        .testTarget(
            name: "ThothIPCProtobufTests",
            dependencies: [
                "ThothIPC",
                "ThothIPCProtobuf",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Tests/ThothIPCProtobufTests"
        ),
        .testTarget(
            name: "ThothIPCSecureCryptoTests",
            dependencies: [
                "ThothIPC",
                "ThothIPCSecureCrypto",
            ],
            path: "Tests/ThothIPCSecureCryptoTests"
        ),
    ]
)
