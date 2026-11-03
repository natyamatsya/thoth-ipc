// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Tests for IpcCondition — mirrors rust/thoth-ipc/tests/test_condition.rs

import Testing
import Atomics
@testable import ThothIPC
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("IpcCondition")
struct TestCondition {

    @Test("open succeeds")
    func openSucceeds() async throws {
        let name = "swift_test_cond_open_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcCondition.clearStorage(name: name) } }
        let _ = try await IpcCondition.open(name: name)
    }

    @Test("notify does not hang when no waiters")
    func notifyNoWaiters() async throws {
        let name = "swift_test_cond_notify_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcCondition.clearStorage(name: name) } }
        defer { Task { await IpcMutex.clearStorage(name: name + "_m") } }
        let mtx = try await IpcMutex.open(name: name + "_m")
        let cond = try await IpcCondition.open(name: name)
        try cond.notify(mutex: mtx)
    }

    @Test("broadcast does not hang when no waiters")
    func broadcastNoWaiters() async throws {
        let name = "swift_test_cond_bcast_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcCondition.clearStorage(name: name) } }
        defer { Task { await IpcMutex.clearStorage(name: name + "_m") } }
        let mtx = try await IpcMutex.open(name: name + "_m")
        let cond = try await IpcCondition.open(name: name)
        try cond.broadcast(mutex: mtx)
    }

    @Test("wait with timeout returns false when not signalled")
    func waitTimeoutExpires() async throws {
        let mtxName  = "swift_test_cond_mtx_tm_\(UInt32.random(in: 0..<UInt32.max))"
        let condName = "swift_test_cond_tm_\(UInt32.random(in: 0..<UInt32.max))"
        defer {
            Task { await IpcMutex.clearStorage(name: mtxName) }
            Task { await IpcCondition.clearStorage(name: condName) }
        }
        let mtx  = try await IpcMutex.open(name: mtxName)
        let cond = try await IpcCondition.open(name: condName)
        try mtx.lock()
        let signalled = try cond.wait(mutex: mtx, timeout: .milliseconds(50))
        try mtx.unlock()
        #expect(!signalled)
    }

    @Test("notify wakes a waiting task")
    func notifyWakesWaiter() async throws {
        let mtxName  = "swift_test_cond_mtx_nw_\(UInt32.random(in: 0..<UInt32.max))"
        let condName = "swift_test_cond_nw_\(UInt32.random(in: 0..<UInt32.max))"
        defer {
            Task { await IpcMutex.clearStorage(name: mtxName) }
            Task { await IpcCondition.clearStorage(name: condName) }
        }
        let mtx  = try await IpcMutex.open(name: mtxName)
        let cond = try await IpcCondition.open(name: condName)

        // The waiter blocks, so it gets a thread of its own. A notify without
        // a waiter is lost, so the wake comes only once the waiter is in the
        // wait: it holds the mutex from before it says so until the wait
        // releases it.
        let entered = ManagedAtomic<Bool>(false)
        nonisolated(unsafe) var signalled = false
        let waiter = spawnPthread {
            try! mtx.lock()
            entered.store(true, ordering: .releasing)
            signalled = try! cond.wait(mutex: mtx, timeout: .seconds(5))
            try! mtx.unlock()
        }

        while !entered.load(ordering: .acquiring) { usleep(1_000) }
        try mtx.lock()
        try mtx.unlock()
        try cond.notify(mutex: mtx)

        await joinThread(waiter)
        #expect(signalled)
    }
}
