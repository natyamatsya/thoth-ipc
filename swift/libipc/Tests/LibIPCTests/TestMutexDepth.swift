// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Deeper IpcMutex tests — port of rust/libipc/tests/test_mutex.rs (missing cases)

import Testing
@testable import LibIPC
import Darwin.POSIX

// MARK: - Tests

@Suite("IpcMutex depth")
struct TestMutexDepth {

    // Port of MutexTest.MultipleCycles
    @Test("100 lock/unlock cycles on one thread")
    func multipleCycles() async throws {
        let name = "swift_mtxd_cycles_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcMutex.clearStorage(name: name) } }
        let mtx = try await IpcMutex.open(name: name)
        for _ in 0..<100 {
            try mtx.lock()
            try mtx.unlock()
        }
    }

    // Port of MutexTest.CriticalSection — 2 threads protect a non-atomic counter
    @Test("critical section — 2 threads, non-atomic counter")
    func criticalSection() async throws {
        let name = "swift_mtxd_cs_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcMutex.clearStorage(name: name) } }
        _ = try await IpcMutex.open(name: name)   // ensure SHM is initialised

        let iterations = 100
        nonisolated(unsafe) var counter = 0

        let threads = (0..<2).map { _ in
            spawnPthread {
                let mtx = try! IpcMutex.openSync(name: name)
                for _ in 0..<iterations {
                    try! mtx.lock()
                    counter += 1
                    try! mtx.unlock()
                }
            }
        }
        for t in threads { await joinThread(t) }
        #expect(counter == iterations * 2)
    }

    // Port of MutexTest.LockContention — mutual exclusion: no two threads in CS simultaneously
    @Test("mutual exclusion — no simultaneous critical section entry")
    func lockContention() async throws {
        let name = "swift_mtxd_contend_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcMutex.clearStorage(name: name) } }
        _ = try await IpcMutex.open(name: name)

        nonisolated(unsafe) var flags = (false, false)
        nonisolated(unsafe) var violation = false

        let t1 = spawnPthread {
            let mtx = try! IpcMutex.openSync(name: name)
            for _ in 0..<50 {
                try! mtx.lock()
                flags.0 = true
                if flags.1 { violation = true }
                var ts = timespec(tv_sec: 0, tv_nsec: 10_000); nanosleep(&ts, nil)
                flags.0 = false
                try! mtx.unlock()
            }
        }
        let t2 = spawnPthread {
            let mtx = try! IpcMutex.openSync(name: name)
            for _ in 0..<50 {
                try! mtx.lock()
                flags.1 = true
                if flags.0 { violation = true }
                var ts = timespec(tv_sec: 0, tv_nsec: 10_000); nanosleep(&ts, nil)
                flags.1 = false
                try! mtx.unlock()
            }
        }
        await joinThread(t1); await joinThread(t2)
        #expect(!violation)
    }

    // Port of MutexTest.RapidLockUnlock
    @Test("rapid lock/unlock — 2 threads × 1000 ops")
    func rapidLockUnlock() async throws {
        let name = "swift_mtxd_rapid_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcMutex.clearStorage(name: name) } }
        _ = try await IpcMutex.open(name: name)

        let threads = (0..<2).map { _ in
            spawnPthread {
                let mtx = try! IpcMutex.openSync(name: name)
                for _ in 0..<1000 { try! mtx.lock(); try! mtx.unlock() }
            }
        }
        for t in threads { await joinThread(t) }
        // Completes without deadlock
    }

    // Port of MutexTest.NamedMutexInterThread — ordering via mutex
    @Test("inter-thread ordering: t2 sees t1's write after lock")
    func interThreadOrdering() async throws {
        let name = "swift_mtxd_order_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcMutex.clearStorage(name: name) } }
        _ = try await IpcMutex.open(name: name)

        nonisolated(unsafe) var shared = 0

        let t1 = spawnPthread {
            let mtx = try! IpcMutex.openSync(name: name)
            try! mtx.lock()
            shared = 100
            var ts = timespec(tv_sec: 0, tv_nsec: 50_000_000); nanosleep(&ts, nil)
            try! mtx.unlock()
        }
        let t2 = spawnPthread {
            var ts = timespec(tv_sec: 0, tv_nsec: 10_000_000); nanosleep(&ts, nil)
            let mtx = try! IpcMutex.openSync(name: name)
            try! mtx.lock()
            shared = 200
            try! mtx.unlock()
        }
        await joinThread(t1)
        await joinThread(t2)
        #expect(shared == 200)
    }

    // Port of MutexTest.HighContention — 8 threads × 50 ops
    @Test("high contention — 8 threads × 50 ops")
    func highContention() async throws {
        let name = "swift_mtxd_hc_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcMutex.clearStorage(name: name) } }
        _ = try await IpcMutex.open(name: name)

        nonisolated(unsafe) var counter = 0
        let threads = (0..<8).map { _ in
            spawnPthread {
                let mtx = try! IpcMutex.openSync(name: name)
                for _ in 0..<50 {
                    try! mtx.lock()
                    counter += 1
                    var ts = timespec(tv_sec: 0, tv_nsec: 100_000); nanosleep(&ts, nil)
                    try! mtx.unlock()
                }
            }
        }
        for t in threads { await joinThread(t) }
        #expect(counter == 8 * 50)
    }

    // Port of MutexTest.lock_timeout_times_out_when_held
    @Test("lock(timeout:) times out when held by another thread")
    func lockTimeoutTimesOut() async throws {
        let name = "swift_mtxd_lttimeout_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcMutex.clearStorage(name: name) } }
        let mtx = try await IpcMutex.open(name: name)
        try mtx.lock()

        nonisolated(unsafe) var timedOut = false
        let t = spawnPthread {
            let mtx2 = try! IpcMutex.openSync(name: name)
            // lock(timeout:) is async — bridge via runBlocking
            let acquired = try! runBlocking { try await mtx2.lock(timeout: .milliseconds(50)) }
            timedOut = !acquired
        }
        await joinThread(t)
        try mtx.unlock()
        #expect(timedOut)
    }

    // Port of MutexTest.try_lock_contended
    @Test("tryLock returns false when held by another thread")
    func tryLockContended() async throws {
        let name = "swift_mtxd_trycontend_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcMutex.clearStorage(name: name) } }
        let mtx = try await IpcMutex.open(name: name)
        try mtx.lock()

        nonisolated(unsafe) var sawContention = false
        let t = spawnPthread {
            let mtx2 = try! IpcMutex.openSync(name: name)
            let acquired = try! mtx2.tryLock()
            if !acquired { sawContention = true }
            else { try! mtx2.unlock() }
        }
        var ts = timespec(tv_sec: 0, tv_nsec: 50_000_000); nanosleep(&ts, nil)
        await joinThread(t)
        try mtx.unlock()
        #expect(sawContention)
    }
}
