// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/src/libipc/platform/posix/condition.h + condition.rs
// Named inter-process condition variable: pthread_cond_t in shared memory.

import Darwin.POSIX

// MARK: - IpcCondition

/// A named, inter-process condition variable.
///
/// On Darwin this is a `pthread_cond_t` stored in shared memory with
/// `PTHREAD_PROCESS_SHARED` attribute, binary-compatible with
/// `ipc::sync::condition` from the C++ libipc library.
///
/// `IpcCondition` is `~Copyable`: each value represents a unique open handle.
public struct IpcCondition: ~Copyable, @unchecked Sendable {
    // @unchecked Sendable: the pthread_cond_t lives in process-shared shm;
    // callers are responsible for correct concurrent use.

    private let cached: CachedShm
    private let name_: String

    // MARK: Open

    /// Open (or create) a named inter-process condition variable.
    ///
    /// All callers within the same process that open the same `name` share a
    /// single mmap (via `condCache`), matching the C++ `curr_prog` pattern.
    public static func open(name: String) async throws(IpcError) -> IpcCondition {
        let size = MemoryLayout<pthread_cond_t>.size
        let cached: CachedShm
        do {
            cached = try await condCache.acquire(name: name, size: size) { base in
            let ptr = base.assumingMemoryBound(to: pthread_cond_t.self)
            ptr.initialize(to: pthread_cond_t())

            var attr = pthread_condattr_t()
            var eno = pthread_condattr_init(&attr)
            guard eno == 0 else { throw IpcError.osError(eno) }

            eno = pthread_condattr_setpshared(&attr, PTHREAD_PROCESS_SHARED)
            guard eno == 0 else {
                pthread_condattr_destroy(&attr)
                throw IpcError.osError(eno)
            }

            eno = pthread_cond_init(ptr, &attr)
            pthread_condattr_destroy(&attr)
            guard eno == 0 else { throw IpcError.osError(eno) }
            }
        } catch let e as IpcError {
            throw e
        } catch {
            throw IpcError.osError(EINVAL)
        }
        return IpcCondition(cached: cached, name_: name)
    }

    // MARK: Wait / Notify / Broadcast

    /// Wait on the condition variable. The caller must hold `mutex` locked.
    /// The mutex is atomically released and re-acquired around the wait.
    /// Blocks indefinitely until signalled.
    public func wait(mutex: borrowing IpcMutex) throws(IpcError) {
        let eno = pthread_cond_wait(condPtr, mutex.mutexPtr)
        guard eno == 0 else { throw .osError(eno) }
    }

    /// Wait on the condition variable with a timeout.
    /// Returns `true` if signalled within `timeout`, `false` on timeout.
    /// The caller must hold `mutex` locked.
    public func wait(mutex: borrowing IpcMutex, timeout: Duration) throws(IpcError) -> Bool {
        var ts = timespec()
        var tv = timeval()
        gettimeofday(&tv, nil)
        let totalNs = Int64(tv.tv_usec) * 1_000 + Int64(timeout.components.attoseconds / 1_000_000_000)
        let totalSec = Int64(tv.tv_sec) + Int64(timeout.components.seconds) + totalNs / 1_000_000_000
        ts.tv_sec = __darwin_time_t(totalSec)
        ts.tv_nsec = Int(totalNs % 1_000_000_000)

        let eno = pthread_cond_timedwait(condPtr, mutex.mutexPtr, &ts)
        switch eno {
        case 0:         return true
        case ETIMEDOUT: return false
        default:        throw .osError(eno)
        }
    }

    /// Wake one waiter.
    public func notify() throws(IpcError) {
        let eno = pthread_cond_signal(condPtr)
        guard eno == 0 else { throw .osError(eno) }
    }

    /// Wake all waiters.
    public func broadcast() throws(IpcError) {
        let eno = pthread_cond_broadcast(condPtr)
        guard eno == 0 else { throw .osError(eno) }
    }

    // MARK: Storage

    /// Remove the backing shared memory for a named condition variable.
    public static func clearStorage(name: String) async {
        await condCache.purge(name: name)
        ShmHandle.clearStorage(name: name)
    }

    // MARK: Internal

    private var condPtr: UnsafeMutablePointer<pthread_cond_t> {
        cached.shm.ptr.assumingMemoryBound(to: pthread_cond_t.self)
    }

    deinit {
        // Do NOT call pthread_cond_destroy here — same reasoning as IpcMutex.
        let n = name_
        Task { await condCache.release(name: n) }
    }
}
