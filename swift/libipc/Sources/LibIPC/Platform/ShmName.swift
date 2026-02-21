// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/src/libipc/platform/posix/shm_name.h
// Produces POSIX shm-safe names identical to the C++ and Rust implementations.

/// Convert a UInt64 to a fixed-width 16-character lowercase hex string.
/// Mirrors Rust `to_hex()` — no Foundation required.
func toHex16(_ val: UInt64) -> String {
    let digits: [UInt8] = Array("0123456789abcdef".utf8)
    var buf = [UInt8](repeating: 0, count: 16)
    var v = val
    for i in stride(from: 15, through: 0, by: -1) {
        buf[i] = digits[Int(v & 0xf)]
        v >>= 4
    }
    return String(decoding: buf, as: UTF8.self)
}

/// FNV-1a 64-bit hash — identical to the C++ `fnv1a_64()` and Rust `fnv1a_64()`.
func fnv1a64(_ data: some Sequence<UInt8>) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in data {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
}

/// Maximum length for POSIX shm names.
/// On macOS `PSHMNAMLEN` is 31. On Linux the limit is typically 255.
/// Mirrors `LIBIPC_SHM_NAME_MAX` from the C++ build.
#if os(macOS)
let shmNameMax: Int = 31
#else
let shmNameMax: Int = 0  // 0 = no truncation
#endif

/// Produce a POSIX shm-safe name (with leading '/').
///
/// When `shmNameMax > 0`, names whose POSIX form would exceed that limit are
/// shortened to `/<prefix>_<16-hex-FNV-1a-hash>`.
/// Produces output byte-identical to the C++ `make_shm_name()` and Rust `make_shm_name()`.
func makeShmName(_ name: String) -> String {
    let result = name.hasPrefix("/") ? name : "/\(name)"

    guard shmNameMax > 0 else { return result }
    guard result.utf8.count > shmNameMax else { return result }

    // 1 (underscore) + 16 (hex hash)
    let hashSuffixLen = 17
    let prefixLen = shmNameMax > hashSuffixLen + 1 ? shmNameMax - hashSuffixLen - 1 : 0

    let hash = fnv1a64(result.utf8)
    let hexStr = toHex16(hash)

    var shortened = "/"
    if prefixLen > 0 {
        // Drop the leading '/' byte, take up to prefixLen bytes, decode as UTF-8.
        let bodyBytes = Array(result.utf8.dropFirst())
        let taken = Array(bodyBytes.prefix(prefixLen))
        shortened += String(decoding: taken, as: UTF8.self)
    }
    shortened += "_"
    shortened += hexStr
    return shortened
}
