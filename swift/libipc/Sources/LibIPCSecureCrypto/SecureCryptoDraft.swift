// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

import LibIPC

/// Draft marker module for optional secure crypto integration.
///
/// The concrete C-ABI-backed implementation is introduced incrementally to keep
/// the core LibIPC target dependency-free by default.
public enum SecureCryptoDraft {
    public static let envelopeVersion: UInt8 = 1
}
