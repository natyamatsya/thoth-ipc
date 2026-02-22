// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Deeper Waiter tests — port of rust/libipc/tests/test_waiter.rs (missing cases)

import Testing
@testable import LibIPC
import Darwin.POSIX
import Atomics

@Suite("Waiter depth")
struct TestWaiterDepth {

    // Port of waiter_broadcast — 4 threads wait through 3 increments
    @Test("broadcast — 4 threads wait through 3 sequential increments")
    func broadcast() async throws {
        let name = "swift_wd_bc_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Waiter.clearStorage(name: name) } }
        await Waiter.clearStorage(name: name)

        let k = ManagedAtomic<Int>(0)

        var threads: [pthread_t] = []
        for _ in 0..<4 {
            let w = try await Waiter.open(name: name)
            threads.append(spawnPthread {
                for i in 0..<3 {
                    _ = try! w.waitIf({ k.load(ordering: .acquiring) == i })
                }
            })
        }

        let waiter = try await Waiter.open(name: name)
        for val in 1...3 {
            var ts = timespec(tv_sec: 0, tv_nsec: 50_000_000); nanosleep(&ts, nil)
            k.store(val, ordering: .releasing)
            try waiter.broadcast()
        }

        for t in threads { await joinThread(t) }
    }

    // Port of waiter_quit_with_predicate — predicate-based quit via notify
    @Test("quit with predicate — notify wakes thread when predicate becomes false")
    func quitWithPredicate() async throws {
        let name = "swift_wd_qp_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Waiter.clearStorage(name: name) } }
        await Waiter.clearStorage(name: name)

        let quit = ManagedAtomic<Bool>(false)
        let w1 = try await Waiter.open(name: name)

        let t = spawnPthread {
            _ = try! w1.waitIf({ !quit.load(ordering: .acquiring) })
        }

        var ts = timespec(tv_sec: 0, tv_nsec: 100_000_000); nanosleep(&ts, nil)

        let w2 = try await Waiter.open(name: name)
        quit.store(true, ordering: .releasing)
        try w2.notify()
        await joinThread(t)
    }

    // Port of waiter_notify_one — notify wakes at least one, broadcast wakes rest
    @Test("notify wakes at least one; broadcast wakes all remaining")
    func notifyOne() async throws {
        let name = "swift_wd_no_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Waiter.clearStorage(name: name) } }
        await Waiter.clearStorage(name: name)

        let flag  = ManagedAtomic<Bool>(false)
        let woken = ManagedAtomic<Int>(0)

        var threads: [pthread_t] = []
        for _ in 0..<3 {
            let w = try await Waiter.open(name: name)
            threads.append(spawnPthread {
                _ = try! w.waitIf({ !flag.load(ordering: .acquiring) },
                                  timeout: .seconds(2))
                woken.wrappingIncrement(ordering: .relaxed)
            })
        }

        var ts = timespec(tv_sec: 0, tv_nsec: 100_000_000); nanosleep(&ts, nil)
        flag.store(true, ordering: .releasing)

        let waiter = try await Waiter.open(name: name)
        try waiter.notify()
        var ts2 = timespec(tv_sec: 0, tv_nsec: 50_000_000); nanosleep(&ts2, nil)
        try waiter.broadcast()

        for t in threads { await joinThread(t) }
        let total = woken.load(ordering: .relaxed)
        #expect(total == 3)
    }

    // Port of waiter_wait_predicate_false — returns immediately when pred is false
    @Test("waitIf returns true immediately when predicate is already false")
    func waitPredicateFalse() async throws {
        let name = "swift_wd_pf_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Waiter.clearStorage(name: name) } }
        let waiter = try await Waiter.open(name: name)
        let result = try waiter.waitIf({ false })
        #expect(result)
    }

    // Port of waiter_reopen — multiple open/close cycles, still works
    @Test("reopen — multiple open/close cycles, waiter still functional")
    func reopen() async throws {
        let name = "swift_wd_ro_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Waiter.clearStorage(name: name) } }
        await Waiter.clearStorage(name: name)

        for _ in 0..<5 { _ = try await Waiter.open(name: name) }

        let flag = ManagedAtomic<Bool>(false)
        let w1 = try await Waiter.open(name: name)

        let t = spawnPthread {
            _ = try! w1.waitIf({ !flag.load(ordering: .acquiring) },
                               timeout: .seconds(2))
        }

        var ts = timespec(tv_sec: 0, tv_nsec: 50_000_000); nanosleep(&ts, nil)
        flag.store(true, ordering: .releasing)
        let w2 = try await Waiter.open(name: name)
        try w2.broadcast()
        await joinThread(t)
    }
}
