// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/include/libipc/rw_lock.h (rw_lock class) + rw_lock.rs
// Single-word atomic read-write lock using bit flags.
//
// High bit (wFlag) marks exclusive/write lock.
// Low 31 bits count concurrent shared/read locks.

import Atomics

// MARK: - RwLock

/// A single-word atomic read-write lock.
///
/// Port of `ipc::rw_lock` from cpp-ipc. Writers get exclusive access;
/// multiple readers can hold the lock concurrently.
///
/// `RwLock` is a class so it can be used as shared mutable state without
/// copying.
public final class RwLock: @unchecked Sendable {
    private static let wMask: UInt32 = 0x7FFF_FFFF  // reader count mask
    private static let wFlag: UInt32 = 0x8000_0000  // writer flag

    private let lc = ManagedAtomic<UInt32>(0)

    public init() {}

    // MARK: Write lock

    /// Acquire an exclusive (write) lock.
    public func lock() async {
        var k: UInt32 = 0
        // Set the writer flag; spin until no other writer holds it.
        while true {
            let old = lc.loadThenBitwiseOr(with: Self.wFlag, ordering: .acquiringAndReleasing)
            if old == 0 { break }               // got w-lock, no readers
            if old & Self.wFlag == 0 { break }  // readers present, no other writer
            await adaptiveYield(&k)
        }
        // Wait for all active readers to finish.
        k = 0
        while lc.load(ordering: .acquiring) & Self.wMask != 0 {
            await adaptiveYield(&k)
        }
    }

    /// Release the exclusive (write) lock.
    public func unlock() {
        lc.store(0, ordering: .releasing)
    }

    // MARK: Read lock

    /// Acquire a shared (read) lock.
    public func lockShared() async {
        var k: UInt32 = 0
        var old = lc.load(ordering: .acquiring)
        while true {
            if old & Self.wFlag != 0 {
                // A writer is active — spin.
                await adaptiveYield(&k)
                old = lc.load(ordering: .acquiring)
            } else {
                let (success, current) = lc.compareExchange(
                    expected: old,
                    desired: old &+ 1,
                    successOrdering: .releasing,
                    failureOrdering: .relaxed
                )
                if success { return }
                old = current
            }
        }
    }

    /// Release a shared (read) lock.
    public func unlockShared() {
        _ = lc.wrappingDecrementThenLoad(ordering: .releasing)
    }
}
