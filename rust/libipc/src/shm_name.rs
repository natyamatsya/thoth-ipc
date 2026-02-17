// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/src/libipc/platform/posix/shm_name.h
// Produces POSIX shm-safe names identical to the C++ implementation.

/// FNV-1a 64-bit hash — identical to the C++ `fnv1a_64()`.
pub fn fnv1a_64(data: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for &b in data {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

/// Convert a 64-bit value to a fixed-width 16-char lowercase hex string.
fn to_hex(val: u64) -> [u8; 16] {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut buf = [0u8; 16];
    let mut v = val;
    for i in (0..16).rev() {
        buf[i] = DIGITS[(v & 0xf) as usize];
        v >>= 4;
    }
    buf
}

/// Maximum length for POSIX shm names. Set to 0 to disable truncation.
///
/// On macOS `PSHMNAMLEN` is 31. On Linux the limit is typically 255.
/// This mirrors `LIBIPC_SHM_NAME_MAX` from the C++ build.
#[cfg(target_os = "macos")]
pub const SHM_NAME_MAX: usize = 31;

#[cfg(not(target_os = "macos"))]
pub const SHM_NAME_MAX: usize = 0; // 0 = no truncation

/// Produce a POSIX shm-safe name (with leading '/').
///
/// When `SHM_NAME_MAX > 0`, names whose POSIX form (including the leading '/')
/// would exceed that limit are shortened to:
///     `/<prefix>_<16-hex-FNV-1a-hash>`
/// where `<prefix>` is a truncated portion of the original name for debuggability.
///
/// Produces output byte-identical to the C++ `make_shm_name()`.
pub fn make_shm_name(name: &str) -> String {
    let result = if name.starts_with('/') {
        name.to_string()
    } else {
        format!("/{name}")
    };

    if SHM_NAME_MAX == 0 {
        return result;
    }

    if result.len() <= SHM_NAME_MAX {
        return result;
    }

    // 1 (underscore) + 16 (hex hash)
    const HASH_SUFFIX_LEN: usize = 1 + 16;
    let prefix_len = if SHM_NAME_MAX > HASH_SUFFIX_LEN + 1 {
        SHM_NAME_MAX - HASH_SUFFIX_LEN - 1 // -1 for leading '/'
    } else {
        0
    };

    let hash = fnv1a_64(result.as_bytes());
    let hex = to_hex(hash);
    let hex_str = std::str::from_utf8(&hex).unwrap();

    let mut shortened = String::with_capacity(SHM_NAME_MAX);
    shortened.push('/');
    if prefix_len > 0 {
        // Skip the leading '/' of the original, take prefix_len bytes
        let original_body = &result[1..];
        let take = prefix_len.min(original_body.len());
        shortened.push_str(&original_body[..take]);
    }
    shortened.push('_');
    shortened.push_str(hex_str);
    shortened
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fnv1a_known_value() {
        // FNV-1a of empty string
        assert_eq!(fnv1a_64(b""), 0xcbf29ce484222325);
    }

    #[test]
    fn make_shm_name_prepends_slash() {
        let name = make_shm_name("foo");
        assert!(name.starts_with('/'));
        assert!(name.contains("foo"));
    }

    #[test]
    fn make_shm_name_keeps_existing_slash() {
        let name = make_shm_name("/bar");
        assert_eq!(&name[..4], "/bar");
    }

    #[test]
    fn to_hex_roundtrip() {
        let hex = to_hex(0x0123456789abcdef);
        assert_eq!(&hex, b"0123456789abcdef");
    }
}
