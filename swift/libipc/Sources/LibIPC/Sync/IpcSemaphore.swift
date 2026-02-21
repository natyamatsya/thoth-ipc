// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/src/libipc/platform/posix/semaphore_impl.h + semaphore.rs
// Named inter-process semaphore via sem_open.

import Darwin.POSIX

// MARK: - IpcSemaphore

/// A named, inter-process semaphore.
///
/// Uses `sem_open` with a name derived from `makeShmName`.
/// macOS lacks `sem_timedwait` — timed waits are emulated via `sem_trywait`
/// polling with adaptive backoff, matching the C++ and Rust implementations.
///
/// `IpcSemaphore` is `~Copyable`: each value represents a unique open handle.
public struct IpcSemaphore: ~Copyable, @unchecked Sendable {
    // @unchecked Sendable: sem_t* is safe to use from multiple threads;
    // POSIX guarantees thread-safety for sem_wait/sem_post.

    private let handle: UnsafeMutablePointer<sem_t>
    private let semName: String

    // MARK: Open

    /// Open (or create) a named semaphore with the given initial `count`.
    ///
    /// The semaphore name is derived from `name` with a `_s` suffix to
    /// separate it from the shm namespace — matching the C++ and Rust impls.
    public static func open(name: String, count: UInt32 = 0) throws(IpcError) -> IpcSemaphore {
        guard !name.isEmpty else { throw .invalidArgument("name is empty") }
        let posixName = makeShmName("\(name)_s")
        let raw = posixName.withCString { ptr in
            sem_open(ptr, O_CREAT, mode_t(0o666), count)
        }
        guard let h = raw, h != SEM_FAILED else { throw .osError(errno) }
        return IpcSemaphore(handle: h, semName: posixName)
    }

    // MARK: Wait / Post

    /// Decrement (wait on) the semaphore.
    /// Blocks indefinitely until the semaphore count is > 0.
    public func wait() throws(IpcError) {
        guard sem_wait(handle) == 0 else { throw .osError(errno) }
    }

    /// Decrement (wait on) the semaphore with a timeout.
    /// Returns `true` if acquired within `timeout`, `false` on timeout.
    ///
    /// macOS lacks `sem_timedwait` — emulated via polling with adaptive backoff.
    public func wait(timeout: Duration) async throws(IpcError) -> Bool {
        let deadline = ContinuousClock.now + timeout
        var k: UInt32 = 0
        while true {
            if sem_trywait(handle) == 0 { return true }
            guard errno == EAGAIN else { throw .osError(errno) }
            if ContinuousClock.now >= deadline { return false }
            await adaptiveYield(&k)
        }
    }

    /// Increment (post) the semaphore `count` times.
    public func post(count: UInt32 = 1) throws(IpcError) {
        for _ in 0..<count {
            guard sem_post(handle) == 0 else { throw .osError(errno) }
        }
    }

    // MARK: Storage

    /// Remove the backing storage for a named semaphore.
    public static func clearStorage(name: String) {
        let posixName = makeShmName("\(name)_s")
        _ = posixName.withCString { sem_unlink($0) }
    }

    // MARK: Deinit

    deinit {
        sem_close(handle)
        _ = semName.withCString { sem_unlink($0) }
    }
}
