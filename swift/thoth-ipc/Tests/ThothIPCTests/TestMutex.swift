// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Tests for IpcMutex — mirrors rust/thoth-ipc/tests/test_mutex.rs

import Testing
@testable import ThothIPC

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

    // Parity with C++ MutexTest.ClearStorageOrphansLiveHandle and Rust
    // clear_storage_orphans_live_handle. clearStorage while a handle is still
    // open must orphan (not corrupt) the segment — the live handle keeps its
    // mapping alive via CachedShm ARC — and a fresh open(name) must be an
    // independent segment. See context/refcount-aware-clear-storage-rfc.md.
    @Test("clearStorage orphans a live handle; fresh open is independent")
    func clearStorageOrphansLiveHandle() async throws {
        let name = "swift_test_mtx_orphan_\(UInt32.random(in: 0..<UInt32.max))"
        await IpcMutex.clearStorage(name: name)

        let a = try await IpcMutex.open(name: name)
        #expect(try a.tryLock())            // A holds the lock

        // Clear while A is live -> orphan (purge cache entry + unlink name).
        await IpcMutex.clearStorage(name: name)

        // A's orphaned segment stays usable.
        try a.unlock()
        #expect(try a.tryLock())
        try a.unlock()

        // Fresh open -> independent segment: A and B can each hold "the lock"
        // simultaneously because they are on different segments.
        let b = try await IpcMutex.open(name: name)
        #expect(try a.tryLock())            // A on its orphan
        #expect(try b.tryLock())            // B independent -> also succeeds
        try a.unlock()
        try b.unlock()

        await IpcMutex.clearStorage(name: name)
    }
}
