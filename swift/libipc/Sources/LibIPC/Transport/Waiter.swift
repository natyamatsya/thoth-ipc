// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/src/libipc/waiter.h.
// Condition-variable + mutex wrapper used by the IPC channel to
// sleep/wake sender and receiver threads.

import Darwin.POSIX
import Atomics

/// A named waiter combining a condition variable, a mutex, and a quit flag.
///
/// Used internally by IPC channels to implement blocking send/recv with
/// timeout support. Mirrors `ipc::detail::waiter` / Rust `Waiter`.
///
/// `Waiter` is `~Copyable`: each value owns a unique open handle pair.
public struct Waiter: ~Copyable, @unchecked Sendable {
    // @unchecked Sendable: cond and lock are inter-process primitives that are
    // themselves thread-safe; quit is an atomic Bool.

    private let cond: IpcCondition
    private let lock: IpcMutex
    // Quit flag — process-local; not in shared memory.
    private let quit: ManagedAtomic<UInt8>  // 0 = running, 1 = quit

    // MARK: Open

    /// Open a named waiter. Creates the underlying condition variable and mutex
    /// with names derived from `name`.
    public static func open(name: String) async throws(IpcError) -> Waiter {
        let condName = "\(name)_WAITER_COND_"
        let lockName = "\(name)_WAITER_LOCK_"
        let cond = try await IpcCondition.open(name: condName)
        let lock = try await IpcMutex.open(name: lockName)
        // Allocate the quit flag on the heap (process-local).
        let quit = ManagedAtomic<UInt8>(0)
        return Waiter(cond: cond, lock: lock, quit: quit)
    }

    private init(cond: consuming IpcCondition, lock: consuming IpcMutex, quit: ManagedAtomic<UInt8>) {
        self.cond = cond
        self.lock = lock
        self.quit = quit
    }

    // MARK: Wait / Notify / Broadcast

    /// Block until `pred` returns `false` or quit is signalled.
    /// Returns `false` on timeout, `true` otherwise.
    ///
    /// - Parameters:
    ///   - pred: Evaluated under the lock. Block while it returns `true`.
    ///   - timeout: Optional deadline; `nil` = wait forever.
    public func waitIf(
        _ pred: () -> Bool,
        timeout: Duration? = nil
    ) throws(IpcError) -> Bool {
        try lock.lock()
        defer { try? lock.unlock() }
        while quit.load(ordering: .relaxed) == 0 && pred() {  // 0 = running
            if let t = timeout {
                let signalled = try cond.wait(mutex: lock, timeout: t)
                if !signalled {
                    return false  // timeout
                }
            } else {
                try cond.wait(mutex: lock)
            }
        }
        return true
    }

    /// Wake one waiter.
    ///
    /// Briefly acquires the lock to ensure the waiter is already in `cond.wait`
    /// before broadcasting — mirrors the C++ / Rust barrier pattern.
    public func notify() throws(IpcError) {
        try lock.lock()
        try lock.unlock()
        try cond.notify()
    }

    /// Wake all waiters.
    public func broadcast() throws(IpcError) {
        try lock.lock()
        try lock.unlock()
        try cond.broadcast()
    }

    /// Signal quit and broadcast to wake all waiters.
    public func quitWaiting() throws(IpcError) {
        quit.store(1, ordering: .releasing)  // signal quit
        try broadcast()
    }

    // MARK: Storage

    /// Remove the backing storage for a named waiter.
    public static func clearStorage(name: String) async {
        await IpcCondition.clearStorage(name: "\(name)_WAITER_COND_")
        await IpcMutex.clearStorage(name: "\(name)_WAITER_LOCK_")
    }

    // MARK: Deinit
    // ManagedAtomic is ARC-managed — no manual destroy needed.
}
