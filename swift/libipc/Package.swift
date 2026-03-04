// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageEnv = ProcessInfo.processInfo.environment
let secureOpenSSL = packageEnv["LIBIPC_SECURE_OPENSSL"] == "1"
let openSSLPrefix = packageEnv["LIBIPC_OPENSSL_PREFIX"] ?? "/opt/homebrew/opt/openssl@3"

let secureCryptoCSettings: [CSetting] = secureOpenSSL
    ? [
        .define("LIBIPC_SECURE_OPENSSL"),
        .unsafeFlags(["-I\(openSSLPrefix)/include"]),
    ]
    : []

let secureCryptoLinkerSettings: [LinkerSetting] = secureOpenSSL
    ? [
        .unsafeFlags(["-L\(openSSLPrefix)/lib", "-lcrypto"]),
    ]
    : []

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
                "LibIPCSecureCryptoC",
            ],
            path: "Sources/LibIPCSecureCrypto",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "LibIPCSecureCryptoC",
            path: "Sources/LibIPCSecureCryptoC",
            publicHeadersPath: "include",
            cSettings: secureCryptoCSettings,
            linkerSettings: secureCryptoLinkerSettings
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
