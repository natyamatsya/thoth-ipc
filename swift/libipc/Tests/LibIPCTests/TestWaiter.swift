// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

import Testing
import Atomics
@testable import LibIPC

@Suite("Waiter")
struct TestWaiter {

    @Test("open succeeds")
    func openSucceeds() async throws {
        let w = try await Waiter.open(name: "test_waiter_open")
        _ = w
        await Waiter.clearStorage(name: "test_waiter_open")
    }

    @Test("notify wakes a waiting task")
    func notifyWakes() async throws {
        let w = try await Waiter.open(name: "test_waiter_notify")
        let flag = ManagedAtomic<Bool>(false)

        let waiter = Task {
            try w.waitIf({ !flag.load(ordering: .acquiring) }, timeout: .seconds(5))
        }

        try await Task.sleep(for: .milliseconds(20))
        flag.store(true, ordering: .releasing)
        try w.notify()

        let result = try await waiter.value
        #expect(result == true)
        await Waiter.clearStorage(name: "test_waiter_notify")
    }

    @Test("waitIf returns false on timeout")
    func waitIfTimeout() async throws {
        let w = try await Waiter.open(name: "test_waiter_timeout")
        let result = try w.waitIf({ true }, timeout: .milliseconds(50))
        #expect(result == false)
        await Waiter.clearStorage(name: "test_waiter_timeout")
    }

    @Test("quitWaiting unblocks waitIf")
    func quitUnblocks() async throws {
        let w = try await Waiter.open(name: "test_waiter_quit")

        let waiter = Task {
            try w.waitIf({ true }, timeout: .seconds(5))
        }

        try await Task.sleep(for: .milliseconds(20))
        try w.quitWaiting()

        let result = try await waiter.value
        #expect(result == true)
        await Waiter.clearStorage(name: "test_waiter_quit")
    }
}
