// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/src/libipc/platform/apple/mutex.h + rust/libipc/platform/apple.rs
// Named inter-process mutex: ulock word-lock in shared memory.

import Darwin.POSIX
import Atomics

private let kMutexSpinCount = 40

// MARK: - IpcMutex

/// A named, inter-process mutex.
///
/// On Darwin this is an Apple ulock-based word mutex in shared memory,
/// binary-compatible with `ipc::sync::mutex` from the C++ libipc library.
///
/// Shared-memory layout (8 bytes):
///   offset 0: atomic<u32>  state   — 0=UNLOCKED, 1=LOCKED, 2=LOCKED+waiters
///   offset 4: atomic<u32>  holder  — PID of current owner, 0 if unlocked
///
/// `IpcMutex` is `~Copyable`: each value represents a unique open handle.
/// Use `ScopedAccess` for RAII locking.
public struct IpcMutex: ~Copyable, @unchecked Sendable {
    // @unchecked Sendable: mutex state lives in process-shared shm;
    // callers are responsible for correct concurrent use.

    private let cached: CachedShm
    private let abiGuard: SyncAbiGuard
    private let name_: String
    private let inCache: Bool
    private let syncOpened: Bool

    // MARK: Open

    /// Open (or create) a named inter-process mutex.
    ///
    /// All callers within the same process that open the same `name` share a
    /// single mmap (via `mutexCache`), matching the C++ `curr_prog` pattern.
    public static func open(name: String) async throws(IpcError) -> IpcMutex {
        let size = 8 // state(u32) + holder(u32)
        let cached: CachedShm
        let abiGuard = try SyncAbiGuard.openMutex(name: name)
        do {
            cached = try await mutexCache.acquire(name: name, size: size) { base in
                shmAtomicU32(at: base).store(0, ordering: .releasing)
                shmAtomicU32(at: base.advanced(by: 4)).store(0, ordering: .releasing)
            }
        } catch let e as IpcError {
            throw e
        } catch {
            throw IpcError.osError(EINVAL)
        }
        return IpcMutex(cached: cached, abiGuard: abiGuard, name_: name, inCache: true, syncOpened: false)
    }

    /// Open via the shared cache without an actor hop — for use from POSIX threads.
    static func openSync(name: String) throws(IpcError) -> IpcMutex {
        let size = 8 // state(u32) + holder(u32)
        let cached: CachedShm
        let abiGuard = try SyncAbiGuard.openMutex(name: name)
        do {
            cached = try mutexCache.acquireSync(name: name, size: size) { base in
                shmAtomicU32(at: base).store(0, ordering: .releasing)
                shmAtomicU32(at: base.advanced(by: 4)).store(0, ordering: .releasing)
            }
        } catch let e as IpcError { throw e }
          catch { throw IpcError.osError(EINVAL) }
        return IpcMutex(cached: cached, abiGuard: abiGuard, name_: name, inCache: true, syncOpened: true)
    }

    // MARK: Internal accessors

    private var stateWordPtr: UnsafeMutablePointer<UInt32> {
        cached.shm.ptr.assumingMemoryBound(to: UInt32.self)
    }

    private var stateAtomic: UnsafeAtomic<UInt32> {
        shmAtomicU32(at: cached.shm.ptr)
    }

    private var holderAtomic: UnsafeAtomic<UInt32> {
        shmAtomicU32(at: cached.shm.ptr.advanced(by: 4))
    }

    private static func isProcessAlive(_ pid: UInt32) -> Bool {
        if pid == 0 { return false }
        return kill(pid_t(pid), 0) == 0 || errno != ESRCH
    }

    private func tryRecoverDeadHolder() -> Bool {
        let holder = holderAtomic.load(ordering: .acquiring)
        if holder == 0 || Self.isProcessAlive(holder) { return false }
        let old = stateAtomic.exchange(0, ordering: .acquiringAndReleasing)
        holderAtomic.store(0, ordering: .releasing)
        if old == 2 {
            _ = _ulockWake(kULCompareAndWaitShared | kULFWakeAll, stateWordPtr, 0)
        }
        return true
    }

    // MARK: Lock / Unlock

    /// Lock the mutex (blocking, no timeout).
    public func lock() throws(IpcError) {
        var contended = false
        while true {
            for _ in 0..<kMutexSpinCount {
                let desired: UInt32 = contended ? 2 : 1
                let (got, _) = stateAtomic.weakCompareExchange(
                    expected: 0, desired: desired,
                    successOrdering: .acquiring, failureOrdering: .relaxed)
                if got {
                    holderAtomic.store(UInt32(getpid()), ordering: .releasing)
                    return
                }
            }

            let s = stateAtomic.load(ordering: .relaxed)
            if s == 0 { continue }
            if s == 1 {
                let (exchanged, _) = stateAtomic.weakCompareExchange(
                    expected: 1, desired: 2,
                    successOrdering: .relaxed, failureOrdering: .relaxed)
                if !exchanged { continue }
            }

            _ = _ulockWait(kULCompareAndWaitShared, stateWordPtr, 2, 0)
            contended = true
        }
    }

    /// Try to lock without blocking.
    /// Returns `true` if acquired, `false` if contended.
    public func tryLock() throws(IpcError) -> Bool {
        let (got, _) = stateAtomic.weakCompareExchange(
            expected: 0, desired: 1,
            successOrdering: .acquiring, failureOrdering: .relaxed)
        if got {
            holderAtomic.store(UInt32(getpid()), ordering: .releasing)
            return true
        }
        if tryRecoverDeadHolder() {
            let (got2, _) = stateAtomic.weakCompareExchange(
                expected: 0, desired: 1,
                successOrdering: .acquiring, failureOrdering: .relaxed)
            if got2 {
                holderAtomic.store(UInt32(getpid()), ordering: .releasing)
                return true
            }
        }
        return false
    }

    /// Lock with a timeout.
    /// Returns `true` if acquired within `timeout`, `false` on timeout.
    public func lock(timeout: Duration) async throws(IpcError) -> Bool {
        let deadline = ContinuousClock.now + timeout
        var triedRecovery = false
        var contended = false
        while true {
            for _ in 0..<kMutexSpinCount {
                let desired: UInt32 = contended ? 2 : 1
                let (got, _) = stateAtomic.weakCompareExchange(
                    expected: 0, desired: desired,
                    successOrdering: .acquiring, failureOrdering: .relaxed)
                if got {
                    holderAtomic.store(UInt32(getpid()), ordering: .releasing)
                    return true
                }
            }

            let s = stateAtomic.load(ordering: .relaxed)
            if s == 0 { continue }
            if s == 1 {
                let (exchanged, _) = stateAtomic.weakCompareExchange(
                    expected: 1, desired: 2,
                    successOrdering: .relaxed, failureOrdering: .relaxed)
                if !exchanged { continue }
            }

            let now = ContinuousClock.now
            if now >= deadline {
                if !triedRecovery {
                    triedRecovery = true
                    if tryRecoverDeadHolder() { continue }
                }
                return false
            }

            let remainingUs: UInt32 = {
                let ns = (deadline - now).components.attoseconds / 1_000_000_000
                let us = ns / 1_000
                return us > 0 && us < Int64(UInt32.max) ? UInt32(us) : UInt32.max
            }()

            let ret = _ulockWait(kULCompareAndWaitShared, stateWordPtr, 2, remainingUs)
            contended = true
            if ret < 0 {
                let err = errno
                if err == ETIMEDOUT {
                    if !triedRecovery {
                        triedRecovery = true
                        if tryRecoverDeadHolder() { continue }
                    }
                    return false
                }
                // EINTR or other: spurious, retry
            }
        }
    }

    /// Unlock the mutex.
    public func unlock() throws(IpcError) {
        holderAtomic.store(0, ordering: .releasing)
        let prev = stateAtomic.exchange(0, ordering: .releasing)
        if prev == 2 {
            _ = _ulockWake(kULCompareAndWaitShared, stateWordPtr, 0)
        }
    }

    // MARK: Storage

    /// Remove the backing shared memory for a named mutex.
    public static func clearStorage(name: String) async {
        await mutexCache.purge(name: name)
        SyncAbiGuard.clearMutexStorage(name: name)
        ShmHandle.clearStorage(name: name)
    }

    // MARK: Internal

    /// Raw pointer to the 8-byte ulock state block — used by `IpcCondition`.
    var shmBase: UnsafeMutableRawPointer {
        cached.shm.ptr
    }

    deinit {
        guard inCache else { return }
        if syncOpened {
            mutexCache.releaseSync(name: name_)
            return
        }
        let n = name_
        Task { await mutexCache.release(name: n) }
    }
}
