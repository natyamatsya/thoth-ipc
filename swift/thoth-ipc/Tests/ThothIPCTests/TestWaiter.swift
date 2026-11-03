// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors

import Testing
import Atomics
@testable import ThothIPC
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

        // The waiter blocks, so it gets a thread of its own rather than one of
        // the cooperative threads the rest of the suite runs on.
        nonisolated(unsafe) var result = false
        let waiter = spawnPthread {
            result = try! w.waitIf({ !flag.load(ordering: .acquiring) }, timeout: .seconds(5))
        }

        usleep(20_000)
        flag.store(true, ordering: .releasing)
        try w.notify()

        await joinThread(waiter)
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

        nonisolated(unsafe) var result = false
        let waiter = spawnPthread {
            result = try! w.waitIf({ true }, timeout: .seconds(5))
        }

        usleep(20_000)
        try w.quitWaiting()

        await joinThread(waiter)
        #expect(result == true)
        await Waiter.clearStorage(name: "test_waiter_quit")
    }
}
