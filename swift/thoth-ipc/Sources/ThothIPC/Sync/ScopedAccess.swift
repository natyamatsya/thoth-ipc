// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of cpp-ipc/src/libipc/scoped_access.h + scoped_access.rs
// RAII lock guard for IpcMutex.

// MARK: - ScopedAccess

/// RAII lock guard for `IpcMutex`.
///
/// Locks the mutex on creation and unlocks it in `deinit`.
/// `~Copyable` ensures the guard cannot be duplicated, mirroring the
/// Rust ownership model.
public struct ScopedAccess: ~Copyable {
    private let mutex: IpcMutex

    /// Lock `mutex` and return a guard that unlocks it on drop.
    public init(locking mutex: consuming IpcMutex) throws(IpcError) {
        try mutex.lock()
        self.mutex = mutex
    }

    deinit {
        try? mutex.unlock()
    }
}
