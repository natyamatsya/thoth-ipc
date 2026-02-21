// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/src/libipc/platform/posix/mutex.h + mutex.rs
// Named inter-process mutex: pthread_mutex_t in shared memory.

import Darwin.POSIX

// MARK: - pthread_mutex_trylock async-safe wrapper

/// Calls `pthread_mutex_trylock` from a nonisolated context, bypassing the
/// Swift 6 `__PTHREAD_SWIFT_UNAVAILABLE_FROM_ASYNC` annotation.
/// This is intentional: we are polling (not blocking), so it is safe to call
/// from the cooperative thread pool.
@inline(__always)
private nonisolated func tryLockSync(_ ptr: UnsafeMutablePointer<pthread_mutex_t>) -> Int32 {
    pthread_mutex_trylock(ptr)
}

// MARK: - IpcMutex

/// A named, inter-process mutex.
///
/// On Darwin this is a `pthread_mutex_t` stored in shared memory with
/// `PTHREAD_PROCESS_SHARED` attribute, binary-compatible with
/// `ipc::sync::mutex` from the C++ libipc library.
///
/// `IpcMutex` is `~Copyable`: each value represents a unique open handle.
/// Use `ScopedAccess` for RAII locking.
public struct IpcMutex: ~Copyable, @unchecked Sendable {
    // @unchecked Sendable: the pthread_mutex_t lives in process-shared shm;
    // callers are responsible for correct concurrent use.

    private let cached: CachedShm
    private let name_: String
    private let inCache: Bool
    private let syncOpened: Bool

    // MARK: Open

    /// Open (or create) a named inter-process mutex.
    ///
    /// All callers within the same process that open the same `name` share a
    /// single mmap (via `mutexCache`), matching the C++ `curr_prog` pattern.
    public static func open(name: String) async throws(IpcError) -> IpcMutex {
        let size = MemoryLayout<pthread_mutex_t>.size
        let cached: CachedShm
        do {
            cached = try await mutexCache.acquire(name: name, size: size) { base in
                let ptr = base.assumingMemoryBound(to: pthread_mutex_t.self)
                ptr.initialize(to: pthread_mutex_t())

                var attr = pthread_mutexattr_t()
                var eno = pthread_mutexattr_init(&attr)
                guard eno == 0 else { throw IpcError.osError(eno) }

                eno = pthread_mutexattr_setpshared(&attr, PTHREAD_PROCESS_SHARED)
                guard eno == 0 else {
                    pthread_mutexattr_destroy(&attr)
                    throw IpcError.osError(eno)
                }

                eno = pthread_mutex_init(ptr, &attr)
                pthread_mutexattr_destroy(&attr)
                guard eno == 0 else { throw IpcError.osError(eno) }
            }
        } catch let e as IpcError {
            throw e
        } catch {
            throw IpcError.osError(EINVAL)
        }
        return IpcMutex(cached: cached, name_: name, inCache: true, syncOpened: false)
    }

    /// Open via the shared cache without an actor hop — for use from POSIX threads.
    static func openSync(name: String) throws(IpcError) -> IpcMutex {
        let size = MemoryLayout<pthread_mutex_t>.size
        let cached: CachedShm
        do {
            cached = try mutexCache.acquireSync(name: name, size: size) { base in
                let ptr = base.assumingMemoryBound(to: pthread_mutex_t.self)
                ptr.initialize(to: pthread_mutex_t())
                var attr = pthread_mutexattr_t()
                var eno = pthread_mutexattr_init(&attr)
                guard eno == 0 else { throw IpcError.osError(eno) }
                eno = pthread_mutexattr_setpshared(&attr, PTHREAD_PROCESS_SHARED)
                guard eno == 0 else { pthread_mutexattr_destroy(&attr); throw IpcError.osError(eno) }
                eno = pthread_mutex_init(ptr, &attr)
                pthread_mutexattr_destroy(&attr)
                guard eno == 0 else { throw IpcError.osError(eno) }
            }
        } catch let e as IpcError { throw e }
          catch { throw IpcError.osError(EINVAL) }
        return IpcMutex(cached: cached, name_: name, inCache: true, syncOpened: true)
    }

    // MARK: Lock / Unlock

    /// Lock the mutex (blocking, no timeout).
    public func lock() throws(IpcError) {
        let eno = pthread_mutex_lock(mutexPtr)
        guard eno == 0 else { throw .osError(eno) }
    }

    /// Try to lock without blocking.
    /// Returns `true` if acquired, `false` if contended.
    public func tryLock() throws(IpcError) -> Bool {
        let eno = tryLockSync(mutexPtr)
        switch eno {
        case 0:      return true
        case EBUSY:  return false
        default:     throw .osError(eno)
        }
    }

    /// Lock with a timeout.
    /// Returns `true` if acquired within `timeout`, `false` on timeout.
    ///
    /// macOS lacks `pthread_mutex_timedlock` — emulated via `tryLock` polling
    /// with adaptive backoff, matching the C++ and Rust implementations.
    public func lock(timeout: Duration) async throws(IpcError) -> Bool {
        let deadline = ContinuousClock.now + timeout
        var k: UInt32 = 0
        while true {
            // pthread_mutex_trylock is annotated unavailable-from-async in Swift 6;
            // call it through a nonisolated sync wrapper to satisfy the compiler.
            let eno = tryLockSync(mutexPtr)
            switch eno {
            case 0:     return true
            case EBUSY: break
            default:    throw .osError(eno)
            }
            if ContinuousClock.now >= deadline { return false }
            await adaptiveYield(&k)
        }
    }

    /// Unlock the mutex.
    public func unlock() throws(IpcError) {
        let eno = pthread_mutex_unlock(mutexPtr)
        guard eno == 0 else { throw .osError(eno) }
    }

    // MARK: Storage

    /// Remove the backing shared memory for a named mutex.
    public static func clearStorage(name: String) async {
        await mutexCache.purge(name: name)
        ShmHandle.clearStorage(name: name)
    }

    // MARK: Internal

    /// Raw pointer to the `pthread_mutex_t` — used by `IpcCondition`.
    var mutexPtr: UnsafeMutablePointer<pthread_mutex_t> {
        cached.shm.ptr.assumingMemoryBound(to: pthread_mutex_t.self)
    }

    deinit {
        guard inCache else { return }
        if syncOpened {
            mutexCache.releaseSync(name: name_)
            return
        }
        // Do NOT call pthread_mutex_destroy here. On macOS the virtual address
        // may be recycled to a different shm segment after munmap, and destroy
        // would corrupt whatever mutex now lives at that address.
        // The shm munmap + unlink in ShmHandle.deinit is sufficient.
        let n = name_
        Task { await mutexCache.release(name: n) }
    }
}
