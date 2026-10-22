// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of cpp-ipc/src/libipc/platform/apple/semaphore_impl.h
//   + rust/thoth-ipc/src/semaphore.rs (mod apple / AppleSemaphore).
// Named inter-process semaphore: ulock counting semaphore in shared memory on
// macOS, a POSIX named semaphore (C++ platform/posix/semaphore_impl.h) on Linux.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Atomics
import ThothIPCShim

#if os(macOS)

// MARK: - IpcSemaphore

/// A named, inter-process counting semaphore.
///
/// On Darwin this is an Apple ulock-based counting semaphore in shared memory,
/// binary-compatible with `thoth::sync::semaphore` (the `ulock_sem_t`) from the
/// C++ libipc library. A POSIX `sem_open` object is a different kernel object
/// and does NOT interoperate with the C++ shm-ulock semaphore; this one does.
///
/// Shared-memory layout (user region, 4 bytes):
///   offset 0: atomic<u32>  count   — token count
/// The backing `ShmHandle` appends the C++ trailing `acc_` ref counter
/// (`calcSize(4) == 8`), shared across all processes mapping the segment.
///
/// `IpcSemaphore` is `~Copyable`: each value represents a unique open handle.
public struct IpcSemaphore: ~Copyable, @unchecked Sendable {
    // @unchecked Sendable: the count lives in process-shared shm;
    // callers are responsible for correct concurrent use.

    private let shm: ShmHandle

    // MARK: Open

    /// Open (or create) a named semaphore with the given initial `count`.
    ///
    /// The `name` passed here is the fully-qualified logical name (the harness
    /// already appends the `_s` suffix). It is transformed exactly once, via
    /// `ShmHandle.acquire` → `makeShmName`, matching the C++ `shm::acquire`.
    public static func open(name: String, count: UInt32 = 0) throws(IpcError) -> IpcSemaphore {
        guard !name.isEmpty else { throw .invalidArgument("name is empty") }
        // sizeof(ulock_sem_t) == 4 (atomic<u32> count); ShmHandle appends the
        // C++ trailing acc_ ref counter (calcSize(4) == 8).
        let shm = try ShmHandle.acquire(
            name: name,
            size: MemoryLayout<UInt32>.size,
            mode: .createOrOpen)
        // First opener initialises the count (mirrors C++ `ref() <= 1`).
        if shm.previousRefCount <= 0 {
            shmAtomicU32(at: shm.ptr).store(count, ordering: .releasing)
        }
        return IpcSemaphore(shm: shm)
    }

    // MARK: Internal accessors

    /// Raw pointer to the 4-byte `count` word — passed to the ulock syscalls.
    private var countWordPtr: UnsafeMutablePointer<UInt32> {
        shm.ptr.assumingMemoryBound(to: UInt32.self)
    }

    private var countAtomic: UnsafeAtomic<UInt32> {
        shmAtomicU32(at: shm.ptr)
    }

    // MARK: Wait / Post

    /// Decrement (wait on) the semaphore.
    /// Blocks indefinitely until the count is > 0.
    public func wait() throws(IpcError) {
        let cptr = countWordPtr
        while true {
            // Try to decrement (CAS loop); succeeds while count > 0.
            var cur = countAtomic.load(ordering: .acquiring)
            while cur > 0 {
                let (won, original) = countAtomic.weakCompareExchange(
                    expected: cur, desired: cur - 1,
                    successOrdering: .acquiring, failureOrdering: .relaxed)
                if won { return }
                cur = original
            }
            // count == 0: sleep until it changes (infinite), loop on EINTR.
            let ret = _ulockWait(kULCompareAndWaitShared, cptr, 0, 0)
            if ret < 0 {
                let err = errno
                if err == EINTR { continue }
                // Spurious / other: fall through and re-check the count.
            }
        }
    }

    /// Decrement (wait on) the semaphore with a timeout.
    /// Returns `true` if acquired within `timeout`, `false` on timeout.
    public func wait(timeout: Duration) async throws(IpcError) -> Bool {
        let deadline = ContinuousClock.now + timeout
        let cptr = countWordPtr
        while true {
            // Try to decrement (CAS loop); succeeds while count > 0.
            var cur = countAtomic.load(ordering: .acquiring)
            while cur > 0 {
                let (won, original) = countAtomic.weakCompareExchange(
                    expected: cur, desired: cur - 1,
                    successOrdering: .acquiring, failureOrdering: .relaxed)
                if won { return true }
                cur = original
            }
            // count == 0: sleep until it changes (or timeout).
            let now = ContinuousClock.now
            if now >= deadline { return false }
            let remainingUs: UInt32 = {
                let comps = (deadline - now).components
                // 1 microsecond == 1e12 attoseconds; 1 second == 1e6 microseconds.
                let us = comps.seconds &* 1_000_000 &+ comps.attoseconds / 1_000_000_000_000
                if us <= 0 { return 0 }
                return us >= Int64(UInt32.max) ? UInt32.max : UInt32(us)
            }()
            if remainingUs == 0 { return false }
            let ret = _ulockWait(kULCompareAndWaitShared, cptr, 0, remainingUs)
            if ret < 0 {
                let err = errno
                if err == ETIMEDOUT { return false }
                // EINTR / spurious / other: loop back and re-check the count.
            }
        }
    }

    /// Increment (post) the semaphore `count` times, waking one waiter per post.
    public func post(count: UInt32 = 1) throws(IpcError) {
        let cptr = countWordPtr
        for _ in 0..<count {
            _ = countAtomic.loadThenWrappingIncrement(ordering: .releasing)
            _ = _ulockWake(kULCompareAndWaitShared, cptr, 0)
        }
    }

    // MARK: Storage

    /// Remove the backing shared memory for a named semaphore.
    ///
    /// Uses the same single name transform as `open`, so it targets the same
    /// shm object the C++/Rust implementations use.
    public static func clearStorage(name: String) {
        ShmHandle.clearStorage(name: name)
    }

    // The `shm` member's own `deinit` decrements the ref counter and unlinks
    // the segment when it is the last mapping, so no explicit `deinit` here.
}

#else

// MARK: - IpcSemaphore (Linux)

/// A named, inter-process counting semaphore.
///
/// On Linux this is a POSIX named semaphore, interoperable with the C++
/// `semaphore` (platform/posix/semaphore_impl.h), Rust's `PosixSemaphore` and
/// the Zig port. Two kernel-visible names per semaphore, as in C++:
///   * the semaphore itself: `sem_open(makeShmName("<name>_s"))` — C++ appends
///     "_s" so the hash differs from the shm namespace;
///   * a 1-byte shm segment `<name>` whose trailing ref counter counts the
///     process handles, so the last one to close unlinks the semaphore.
///
/// `IpcSemaphore` is `~Copyable`: each value represents a unique open handle.
public struct IpcSemaphore: ~Copyable, @unchecked Sendable {
    // @unchecked Sendable: sem_t operations are thread-safe.

    private let refs: ShmHandle
    private let sem: UnsafeMutableRawPointer
    private let semName: String

    /// The kernel name of logical semaphore `name`.
    private static func semName(_ name: String) -> String { makeShmName("\(name)_s") }

    // MARK: Open

    /// Open (or create) a named semaphore with the given initial `count`.
    ///
    /// The `name` passed here is the fully-qualified logical name (the harness
    /// already appends the `_s` suffix), as for C++ `semaphore::open`.
    public static func open(name: String, count: UInt32 = 0) throws(IpcError) -> IpcSemaphore {
        guard !name.isEmpty else { throw .invalidArgument("name is empty") }
        let refs = try ShmHandle.acquire(name: name, size: 1, mode: .createOrOpen)
        let sn = semName(name)
        guard let sem = sn.withCString({ thoth_ipc_sem_open_create($0, 0o666, count) }) else {
            throw .osError(errno)
        }
        return IpcSemaphore(refs: refs, sem: sem, semName: sn)
    }

    private var handle: UnsafeMutablePointer<sem_t> { sem.assumingMemoryBound(to: sem_t.self) }

    // MARK: Wait / Post

    /// Decrement (wait on) the semaphore.
    /// Blocks indefinitely until the count is > 0.
    public func wait() throws(IpcError) {
        while sem_wait(handle) != 0 {
            guard errno == EINTR else { throw .osError(errno) }
        }
    }

    /// Decrement (wait on) the semaphore with a timeout.
    /// Returns `true` if acquired within `timeout`, `false` on timeout.
    public func wait(timeout: Duration) async throws(IpcError) -> Bool {
        // sem_timedwait takes an absolute CLOCK_REALTIME deadline.
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        let at = Int64(now.tv_sec) * 1_000_000_000 + Int64(now.tv_nsec) + durationNs(timeout)
        var deadline = timespec(tv_sec: Int(at / 1_000_000_000), tv_nsec: Int(at % 1_000_000_000))
        while sem_timedwait(handle, &deadline) != 0 {
            switch errno {
            case EINTR: continue
            case ETIMEDOUT: return false
            case let e: throw .osError(e)
            }
        }
        return true
    }

    /// Increment (post) the semaphore `count` times, waking one waiter per post.
    public func post(count: UInt32 = 1) throws(IpcError) {
        for _ in 0..<count where sem_post(handle) != 0 { throw .osError(errno) }
    }

    // MARK: Storage

    /// Remove the semaphore and its handle counter.
    public static func clearStorage(name: String) {
        _ = semName(name).withCString { sem_unlink($0) }
        ShmHandle.clearStorage(name: name)
    }

    /// Close this handle; the last one in any process unlinks the semaphore.
    deinit {
        sem_close(handle)
        if refs.refCount <= 1 { _ = semName.withCString { sem_unlink($0) } }
    }
}

#endif
