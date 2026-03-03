// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/src/libipc/platform/apple/condition.h + rust/libipc/src/condition.rs
// Named inter-process condition variable: ulock sequence-counter in shared memory.

import Darwin.POSIX
import Atomics

// MARK: - IpcCondition

/// A named, inter-process condition variable.
///
/// On Darwin this is a ulock sequence-counter condition variable in shared
/// memory, binary-compatible with `ipc::sync::condition` from the C++ libipc
/// library.
///
/// Shared-memory layout (8 bytes):
///   offset 0: atomic<u32>  seq     — monotonically incremented on notify/broadcast
///   offset 4: atomic<i32>  waiters — count of threads in __ulock_wait
///
/// `IpcCondition` is `~Copyable`: each value represents a unique open handle.
public struct IpcCondition: ~Copyable, @unchecked Sendable {
    // @unchecked Sendable: state lives in process-shared shm;
    // callers are responsible for correct concurrent use.

    private let cached: CachedShm
    private let abiGuard: SyncAbiGuard
    private let name_: String
    private let inCache: Bool
    private let syncOpened: Bool

    // MARK: Open

    /// Open (or create) a named inter-process condition variable.
    ///
    /// All callers within the same process that open the same `name` share a
    /// single mmap (via `condCache`), matching the C++ `curr_prog` pattern.
    public static func open(name: String) async throws(IpcError) -> IpcCondition {
        let size = 8 // seq(u32) + waiters(i32)
        let cached: CachedShm
        let abiGuard = try SyncAbiGuard.openCondition(name: name)
        do {
            cached = try await condCache.acquire(name: name, size: size) { base in
                shmAtomicU32(at: base).store(0, ordering: .releasing)
                shmAtomicI32(at: base.advanced(by: 4)).store(0, ordering: .releasing)
            }
        } catch let e as IpcError {
            throw e
        } catch {
            throw IpcError.osError(EINVAL)
        }
        return IpcCondition(cached: cached, abiGuard: abiGuard, name_: name, inCache: true, syncOpened: false)
    }

    /// Open via the shared cache without an actor hop — for use from POSIX threads.
    static func openSync(name: String) throws(IpcError) -> IpcCondition {
        let size = 8 // seq(u32) + waiters(i32)
        let cached: CachedShm
        let abiGuard = try SyncAbiGuard.openCondition(name: name)
        do {
            cached = try condCache.acquireSync(name: name, size: size) { base in
                shmAtomicU32(at: base).store(0, ordering: .releasing)
                shmAtomicI32(at: base.advanced(by: 4)).store(0, ordering: .releasing)
            }
        } catch let e as IpcError { throw e }
          catch { throw IpcError.osError(EINVAL) }
        return IpcCondition(cached: cached, abiGuard: abiGuard, name_: name, inCache: true, syncOpened: true)
    }

    // MARK: Internal accessors

    private var seqWordPtr: UnsafeMutablePointer<UInt32> {
        cached.shm.ptr.assumingMemoryBound(to: UInt32.self)
    }

    private var seqAtomic: UnsafeAtomic<UInt32> {
        shmAtomicU32(at: cached.shm.ptr)
    }

    private var waitersAtomic: UnsafeAtomic<Int32> {
        shmAtomicI32(at: cached.shm.ptr.advanced(by: 4))
    }

    // MARK: Wait / Notify / Broadcast

    /// Wait on the condition variable. The caller must hold `mutex` locked.
    /// The mutex is atomically released and re-acquired around the wait.
    /// Blocks indefinitely until signalled.
    public func wait(mutex: borrowing IpcMutex) throws(IpcError) {
        let expectedSeq = seqAtomic.load(ordering: .acquiring)
        _ = waitersAtomic.loadThenWrappingIncrement(ordering: .relaxed)
        try mutex.unlock()
        while true {
            if seqAtomic.load(ordering: .acquiring) != expectedSeq { break }
            let ret = _ulockWait(kULCompareAndWaitShared, seqWordPtr, UInt64(expectedSeq), 0)
            if ret >= 0 { break }
            let err = errno
            if err == EINTR { continue }
            break
        }
        _ = waitersAtomic.loadThenWrappingDecrement(ordering: .relaxed)
        try mutex.lock()
    }

    /// Wait on the condition variable with a timeout.
    /// Returns `true` if signalled within `timeout`, `false` on timeout.
    /// The caller must hold `mutex` locked.
    public func wait(mutex: borrowing IpcMutex, timeout: Duration) throws(IpcError) -> Bool {
        let expectedSeq = seqAtomic.load(ordering: .acquiring)
        _ = waitersAtomic.loadThenWrappingIncrement(ordering: .relaxed)
        try mutex.unlock()
        var notified = false
        let deadline = ContinuousClock.now + timeout
        outer: while true {
            if seqAtomic.load(ordering: .acquiring) != expectedSeq {
                notified = true
                break
            }
            let now = ContinuousClock.now
            if now >= deadline { break }
            let remainingUs: UInt32 = {
                let ns = (deadline - now).components.attoseconds / 1_000_000_000
                let us = ns / 1_000
                return us > 0 && us < Int64(UInt32.max) ? UInt32(us) : UInt32.max
            }()
            let ret = _ulockWait(kULCompareAndWaitShared, seqWordPtr, UInt64(expectedSeq), remainingUs)
            if ret >= 0 {
                continue
            }
            let err = errno
            if err == EINTR { continue }
            if err == ETIMEDOUT { break }
            break outer
        }
        if seqAtomic.load(ordering: .acquiring) != expectedSeq { notified = true }
        _ = waitersAtomic.loadThenWrappingDecrement(ordering: .relaxed)
        try mutex.lock()
        return notified
    }

    /// Wake one waiter.
    public func notify() throws(IpcError) {
        _ = seqAtomic.loadThenWrappingIncrement(ordering: .acquiringAndReleasing)
        if waitersAtomic.load(ordering: .acquiring) > 0 {
            _ = _ulockWake(kULCompareAndWaitShared, seqWordPtr, 0)
        }
    }

    /// Wake all waiters.
    public func broadcast() throws(IpcError) {
        _ = seqAtomic.loadThenWrappingIncrement(ordering: .acquiringAndReleasing)
        if waitersAtomic.load(ordering: .acquiring) > 0 {
            _ = _ulockWake(kULCompareAndWaitShared | kULFWakeAll, seqWordPtr, 0)
        }
    }

    // MARK: Storage

    /// Remove the backing shared memory for a named condition variable.
    public static func clearStorage(name: String) async {
        await condCache.purge(name: name)
        SyncAbiGuard.clearConditionStorage(name: name)
        ShmHandle.clearStorage(name: name)
    }

    deinit {
        guard inCache else { return }
        if syncOpened {
            condCache.releaseSync(name: name_)
        } else {
            let n = name_
            Task { await condCache.release(name: n) }
        }
    }
}
