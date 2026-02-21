// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/include/libipc/rw_lock.h (spin_lock class) + spin_lock.rs
// Lock-free spin lock with adaptive backoff.

import Atomics

// MARK: - SpinLock

/// A simple spin lock with adaptive backoff.
///
/// Port of `ipc::spin_lock` from cpp-ipc. Uses a `ManagedAtomic<UInt32>`
/// exchanged to 1 on lock, stored to 0 on unlock, with adaptive yield
/// between retries.
///
/// `SpinLock` is a class so it can be used as shared mutable state without
/// copying. Use `lock()` / `unlock()` directly or wrap in `ScopedAccess`.
public final class SpinLock: @unchecked Sendable {
    private let lc = ManagedAtomic<UInt32>(0)

    public init() {}

    /// Acquire the lock (spinning with adaptive backoff).
    public func lock() async {
        var k: UInt32 = 0
        while lc.exchange(1, ordering: .acquiring) != 0 {
            await adaptiveYield(&k)
        }
    }

    /// Release the lock.
    public func unlock() {
        lc.store(0, ordering: .releasing)
    }
}
