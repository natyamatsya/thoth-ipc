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
    name: "secure-crypto-c",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "LibIPCSecureCryptoC", targets: ["LibIPCSecureCryptoC"]),
    ],
    targets: [
        .target(
            name: "LibIPCSecureCryptoC",
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
