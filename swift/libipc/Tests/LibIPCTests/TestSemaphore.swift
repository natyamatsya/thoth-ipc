// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Tests for IpcSemaphore — mirrors rust/libipc/tests/test_semaphore.rs

import Testing
@testable import LibIPC

@Suite("IpcSemaphore")
struct TestSemaphore {

    @Test("open succeeds")
    func openSucceeds() throws {
        let name = "st_sem_o_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let _ = try IpcSemaphore.open(name: name, count: 0)
    }

    @Test("post then wait succeeds immediately")
    func postThenWait() throws {
        let name = "st_sem_pw_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let sem = try IpcSemaphore.open(name: name, count: 0)
        try sem.post()
        try sem.wait()
    }

    @Test("open with initial count allows immediate wait")
    func initialCount() throws {
        let name = "st_sem_i_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let sem = try IpcSemaphore.open(name: name, count: 3)
        try sem.wait()
        try sem.wait()
        try sem.wait()
    }

    @Test("wait with timeout returns false when count is 0")
    func waitTimeoutExpires() async throws {
        let name = "st_sem_t_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let sem = try IpcSemaphore.open(name: name, count: 0)
        let acquired = try await sem.wait(timeout: .milliseconds(50))
        #expect(!acquired)
    }

    @Test("wait with timeout succeeds when posted before deadline")
    func waitTimeoutSucceeds() async throws {
        let name = "st_sem_t2_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let sem = try IpcSemaphore.open(name: name, count: 0)
        try sem.post()
        let acquired = try await sem.wait(timeout: .milliseconds(100))
        #expect(acquired)
    }

    @Test("post count > 1 allows multiple waits")
    func postMultiple() throws {
        let name = "st_sem_m_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let sem = try IpcSemaphore.open(name: name, count: 0)
        try sem.post(count: 3)
        try sem.wait()
        try sem.wait()
        try sem.wait()
    }

    @Test("empty name throws")
    func emptyNameThrows() {
        #expect(throws: IpcError.self) {
            _ = try IpcSemaphore.open(name: "", count: 0)
        }
    }
}
