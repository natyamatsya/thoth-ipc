// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Tests for IpcCondition — mirrors rust/libipc/tests/test_condition.rs

import Testing
@testable import LibIPC

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
        let cond = try await IpcCondition.open(name: name)
        try cond.notify()
    }

    @Test("broadcast does not hang when no waiters")
    func broadcastNoWaiters() async throws {
        let name = "swift_test_cond_bcast_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcCondition.clearStorage(name: name) } }
        let cond = try await IpcCondition.open(name: name)
        try cond.broadcast()
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

        let waiterTask = Task {
            try mtx.lock()
            let signalled = try cond.wait(mutex: mtx, timeout: .seconds(5))
            try mtx.unlock()
            return signalled
        }

        // Give the waiter time to enter the wait.
        try await Task.sleep(for: .milliseconds(20))
        try cond.notify()

        let signalled = try await waiterTask.value
        #expect(signalled)
    }
}
