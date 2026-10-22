// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of cpp-ipc/src/libipc/platform/apple/condition.h + rust/thoth-ipc/src/condition.rs
// Named inter-process condition variable: ulock sequence-counter in shared
// memory on macOS, the linux_a0 requeue-PI condition (C++
// platform/linux/condition.h) on Linux.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Atomics
import ThothIPCShim

#if os(macOS)
/// seq(u32) + waiters(i32).
let conditionPayloadSize = 8
#else
/// The alephzero a0_cnd_t, a u32 futex sequence word.
let conditionPayloadSize = ABI.a0_cnd_size
#endif

// MARK: - IpcCondition

/// A named, inter-process condition variable.
///
/// Binary-compatible with `thoth::sync::condition` from the C++ library: a
/// ulock sequence-counter condition on Darwin (layout below), the linux_a0
/// a0_cnd_t (4 bytes) on Linux, whose waiters the kernel requeues onto the
/// paired mutex.
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
        let size = conditionPayloadSize
        let cached: CachedShm
        let abiGuard = try SyncAbiGuard.openCondition(name: name)
        do {
            cached = try await condCache.acquire(name: name, size: size) { base in
                base.initializeMemory(as: UInt8.self, repeating: 0, count: size)
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
        let size = conditionPayloadSize
        let cached: CachedShm
        let abiGuard = try SyncAbiGuard.openCondition(name: name)
        do {
            cached = try condCache.acquireSync(name: name, size: size) { base in
                base.initializeMemory(as: UInt8.self, repeating: 0, count: size)
            }
        } catch let e as IpcError { throw e }
          catch { throw IpcError.osError(EINVAL) }
        return IpcCondition(cached: cached, abiGuard: abiGuard, name_: name, inCache: true, syncOpened: true)
    }

    #if os(macOS)

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

    /// Wake one waiter. `mutex` is the one waiters pass to `wait`; this backend
    /// does not need it (Linux requeues waiters onto it).
    public func notify(mutex: borrowing IpcMutex) throws(IpcError) {
        _ = seqAtomic.loadThenWrappingIncrement(ordering: .acquiringAndReleasing)
        if waitersAtomic.load(ordering: .acquiring) > 0 {
            _ = _ulockWake(kULCompareAndWaitShared, seqWordPtr, 0)
        }
    }

    /// Wake all waiters. `mutex` as for `notify`.
    public func broadcast(mutex: borrowing IpcMutex) throws(IpcError) {
        _ = seqAtomic.loadThenWrappingIncrement(ordering: .acquiringAndReleasing)
        if waitersAtomic.load(ordering: .acquiring) > 0 {
            _ = _ulockWake(kULCompareAndWaitShared | kULFWakeAll, seqWordPtr, 0)
        }
    }
    #else

    // MARK: Wait / Notify / Broadcast (linux_a0, C++ platform/linux/condition.h)

    private var a0Cond: UnsafeMutableRawPointer { cached.shm.ptr }

    /// One a0_cnd wait. A mutex that comes back from a dead holder is made
    /// consistent and the wait reports a wake-up (callers re-check their
    /// predicate), as Rust and Zig do. True if signalled.
    private func waitA0(_ mutex: borrowing IpcMutex, timeoutNs: Int64) throws(IpcError) -> Bool {
        let eno = thoth_a0_cnd_wait(a0Cond, mutex.shmBase, timeoutNs)
        switch eno {
        case 0: return true
        case ETIMEDOUT: return false
        case EOWNERDEAD:
            _ = thoth_a0_mtx_consistent(mutex.shmBase) // held by this thread
            return true
        default: throw .osError(eno)
        }
    }

    /// Wait on the condition variable. The caller must hold `mutex` locked.
    /// The mutex is atomically released and re-acquired around the wait.
    /// Blocks indefinitely until signalled.
    public func wait(mutex: borrowing IpcMutex) throws(IpcError) {
        _ = try waitA0(mutex, timeoutNs: -1)
    }

    /// Wait on the condition variable with a timeout.
    /// Returns `true` if signalled within `timeout`, `false` on timeout.
    /// The caller must hold `mutex` locked.
    public func wait(mutex: borrowing IpcMutex, timeout: Duration) throws(IpcError) -> Bool {
        try waitA0(mutex, timeoutNs: durationNs(timeout))
    }

    /// Wake one waiter, requeued onto `mutex` (the one waiters pass to `wait`).
    public func notify(mutex: borrowing IpcMutex) throws(IpcError) {
        let eno = thoth_a0_cnd_signal(a0Cond, mutex.shmBase)
        if eno != 0 { throw .osError(eno) }
    }

    /// Wake all waiters, requeued onto `mutex`.
    public func broadcast(mutex: borrowing IpcMutex) throws(IpcError) {
        let eno = thoth_a0_cnd_broadcast(a0Cond, mutex.shmBase)
        if eno != 0 { throw .osError(eno) }
    }

    #endif

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
