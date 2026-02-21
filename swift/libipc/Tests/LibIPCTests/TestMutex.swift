// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Tests for IpcMutex — mirrors rust/libipc/tests/test_mutex.rs

import Testing
@testable import LibIPC

@Suite("IpcMutex")
struct TestMutex {

    @Test("open succeeds")
    func openSucceeds() async throws {
        let name = "swift_test_mtx_open_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcMutex.clearStorage(name: name) } }
        let _ = try await IpcMutex.open(name: name)
    }

    @Test("lock and unlock")
    func lockUnlock() async throws {
        let name = "swift_test_mtx_lu_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcMutex.clearStorage(name: name) } }
        let mtx = try await IpcMutex.open(name: name)
        try mtx.lock()
        try mtx.unlock()
    }

    @Test("tryLock returns true when unlocked")
    func tryLockUnlocked() async throws {
        let name = "swift_test_mtx_try_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcMutex.clearStorage(name: name) } }
        let mtx = try await IpcMutex.open(name: name)
        let acquired = try mtx.tryLock()
        #expect(acquired)
        try mtx.unlock()
    }

    @Test("tryLock returns false when already locked")
    func tryLockLocked() async throws {
        let name = "swift_test_mtx_try2_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcMutex.clearStorage(name: name) } }
        let mtx = try await IpcMutex.open(name: name)
        try mtx.lock()
        let acquired = try mtx.tryLock()
        #expect(!acquired)
        try mtx.unlock()
    }

    @Test("lock with timeout succeeds when unlocked")
    func lockTimeoutSucceeds() async throws {
        let name = "swift_test_mtx_tm_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcMutex.clearStorage(name: name) } }
        let mtx = try await IpcMutex.open(name: name)
        let acquired = try await mtx.lock(timeout: .milliseconds(100))
        #expect(acquired)
        try mtx.unlock()
    }

    @Test("two opens of same name share the same mutex")
    func twoOpensShareMutex() async throws {
        let name = "swift_test_mtx_share_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcMutex.clearStorage(name: name) } }
        let mtx1 = try await IpcMutex.open(name: name)
        let mtx2 = try await IpcMutex.open(name: name)
        try mtx1.lock()
        let acquired = try mtx2.tryLock()
        #expect(!acquired)
        try mtx1.unlock()
    }
}
