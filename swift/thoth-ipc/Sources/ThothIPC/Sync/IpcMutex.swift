// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of cpp-ipc/src/libipc/platform/apple/mutex.h + rust/thoth-ipc/platform/apple.rs
// Named inter-process mutex: ulock word-lock in shared memory on macOS, the
// linux_a0 robust priority-inheriting futex mutex (C++ platform/linux/mutex.h)
// on Linux.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Atomics
import ThothIPCShim

#if os(macOS)
private let kMutexSpinCount = 40
/// state(u32) + holder(u32).
let mutexPayloadSize = 8
#else
/// The vendored alephzero a0_mtx_t, zero-filled by its first opener.
let mutexPayloadSize = ABI.a0_mtx_size
#endif

// MARK: - IpcMutex

/// A named, inter-process mutex.
///
/// Binary-compatible with `thoth::sync::mutex` from the C++ library. On Darwin
/// it is an Apple ulock-based word mutex in shared memory (8 bytes):
///   offset 0: atomic<u32>  state   — 0=UNLOCKED, 1=LOCKED, 2=LOCKED+waiters
///   offset 4: atomic<u32>  holder  — PID of current owner, 0 if unlocked
/// On Linux it is the linux_a0 a0_mtx_t (24 bytes), run by the same C code
/// C++ uses; a lock whose holder died is recovered.
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
        let size = mutexPayloadSize
        let cached: CachedShm
        let abiGuard = try SyncAbiGuard.openMutex(name: name)
        do {
            cached = try await mutexCache.acquire(name: name, size: size) { base in
                base.initializeMemory(as: UInt8.self, repeating: 0, count: size)
            }
        } catch let e as IpcError {
            throw e
        } catch {
            throw IpcError.osError(EINVAL)
        }
        return IpcMutex(cached: cached, abiGuard: abiGuard, name_: name, inCache: true, syncOpened: false)
    }

    /// Open via the shared cache without an actor hop — safe from POSIX threads
    /// and blocking (non-async) call sites, mirroring `Route.connectBlocking`.
    public static func openSync(name: String) throws(IpcError) -> IpcMutex {
        let size = mutexPayloadSize
        let cached: CachedShm
        let abiGuard = try SyncAbiGuard.openMutex(name: name)
        do {
            cached = try mutexCache.acquireSync(name: name, size: size) { base in
                base.initializeMemory(as: UInt8.self, repeating: 0, count: size)
            }
        } catch let e as IpcError { throw e }
          catch { throw IpcError.osError(EINVAL) }
        return IpcMutex(cached: cached, abiGuard: abiGuard, name_: name, inCache: true, syncOpened: true)
    }

    #if os(macOS)

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
    #else

    // MARK: Lock / Unlock (linux_a0, C++ platform/linux/mutex.h robust_mutex)

    /// A lock whose holder died is made consistent, released and taken again,
    /// as C++ does. True once held, false on timeout (`timeoutNs` < 0: never).
    private func lockA0(timeoutNs: Int64) throws(IpcError) -> Bool {
        while true {
            let eno = thoth_a0_mtx_lock(shmBase, timeoutNs)
            switch eno {
            case 0: return true
            case ETIMEDOUT: return false
            case EOWNERDEAD:
                // This thread holds it now, so neither call can fail.
                _ = thoth_a0_mtx_consistent(shmBase)
                _ = thoth_a0_mtx_unlock(shmBase)
            default: throw .osError(eno)
            }
        }
    }

    /// Lock the mutex (blocking, no timeout).
    public func lock() throws(IpcError) {
        _ = try lockA0(timeoutNs: -1)
    }

    /// Try to lock without blocking.
    /// Returns `true` if acquired, `false` if contended — also when this thread
    /// already holds it (the error-checking a0 mutex reports EDEADLK), as Rust.
    public func tryLock() throws(IpcError) -> Bool {
        do { return try lockA0(timeoutNs: 0) } catch .osError(EDEADLK) { return false }
    }

    /// Lock with a timeout.
    /// Returns `true` if acquired within `timeout`, `false` on timeout.
    public func lock(timeout: Duration) async throws(IpcError) -> Bool {
        try lockA0(timeoutNs: durationNs(timeout))
    }

    /// Unlock the mutex.
    public func unlock() throws(IpcError) {
        let eno = thoth_a0_mtx_unlock(shmBase)
        if eno != 0 { throw .osError(eno) }
    }

    #endif

    // MARK: Storage

    /// Remove the backing shared memory for a named mutex.
    public static func clearStorage(name: String) async {
        await mutexCache.purge(name: name)
        SyncAbiGuard.clearMutexStorage(name: name)
        ShmHandle.clearStorage(name: name)
    }

    // MARK: Internal

    /// The shared payload (the ulock state block, or the a0_mtx_t a paired
    /// condition requeues onto) — used by `IpcCondition`.
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
