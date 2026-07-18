// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors

// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageEnv = ProcessInfo.processInfo.environment
let secureOpenSSL = packageEnv["THOTH_IPC_SECURE_OPENSSL"] == "1"
let openSSLPrefix = packageEnv["THOTH_IPC_OPENSSL_PREFIX"] ?? "/opt/homebrew/opt/openssl@3"

let secureCryptoCSettings: [CSetting] = secureOpenSSL
    ? [
        .define("THOTH_IPC_SECURE_OPENSSL"),
        .unsafeFlags(["-I\(openSSLPrefix)/include"]),
    ]
    : []

let secureCryptoLinkerSettings: [LinkerSetting] = secureOpenSSL
    ? [
        .unsafeFlags(["-L\(openSSLPrefix)/lib", "-lcrypto"]),
    ]
    : []

let package = Package(
    name: "secure-crypto-c",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ThothIPCSecureCryptoC", targets: ["ThothIPCSecureCryptoC"]),
    ],
    targets: [
        .target(
            name: "ThothIPCSecureCryptoC",
            path: ".",
            exclude: [
                "CMakeLists.txt",
                "Package.swift",
            ],
            sources: [
                "src/secure_crypto_c.c",
            ],
            publicHeadersPath: "include",
            cSettings: secureCryptoCSettings,
            linkerSettings: secureCryptoLinkerSettings
        ),
    ]
)
