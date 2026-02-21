// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

/// Typed error for all LibIPC operations.
public enum IpcError: Error, Sendable {
    /// A POSIX system call failed with the given `errno` value.
    case osError(Int32)
    /// An argument was invalid (empty name, zero size, etc.).
    case invalidArgument(String)
    /// The operation timed out.
    case timeout
    /// The handle is not valid.
    case invalidHandle
}
