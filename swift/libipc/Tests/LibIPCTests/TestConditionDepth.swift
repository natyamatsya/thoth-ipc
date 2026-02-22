// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Deeper IpcCondition tests — port of rust/libipc/tests/test_condition.rs (missing cases)

import Testing
@testable import LibIPC
import Darwin.POSIX

// MARK: - Tests

@Suite("IpcCondition depth")
struct TestConditionDepth {

    // Port of ConditionTest.WaitNotify — basic wait/notify across threads
    @Test("wait/notify across threads")
    func waitNotify() async throws {
        let cvName  = "swift_cvd_wn_cv_\(UInt32.random(in: 0..<UInt32.max))"
        let mtxName = "swift_cvd_wn_mx_\(UInt32.random(in: 0..<UInt32.max))"
        defer {
            Task { await IpcCondition.clearStorage(name: cvName) }
            Task { await IpcMutex.clearStorage(name: mtxName) }
        }
        _ = try await IpcCondition.open(name: cvName)
        _ = try await IpcMutex.open(name: mtxName)

        nonisolated(unsafe) var notified = false

        let waiter = spawnPthread {
            let cv  = try! IpcCondition.openSync(name: cvName)
            let mtx = try! IpcMutex.openSync(name: mtxName)
            try! mtx.lock()
            try! cv.wait(mutex: mtx)
            notified = true
            try! mtx.unlock()
        }

        var ts = timespec(tv_sec: 0, tv_nsec: 50_000_000); nanosleep(&ts, nil)

        let cv  = try await IpcCondition.open(name: cvName)
        let mtx = try await IpcMutex.open(name: mtxName)
        try mtx.lock()
        try cv.notify()
        try mtx.unlock()

        await joinThread(waiter)
        #expect(notified)
    }

    // Port of ConditionTest.Broadcast — 5 waiters all wake on broadcast
    @Test("broadcast wakes all 5 waiters")
    func broadcast() async throws {
        let cvName  = "swift_cvd_bc_cv_\(UInt32.random(in: 0..<UInt32.max))"
        let mtxName = "swift_cvd_bc_mx_\(UInt32.random(in: 0..<UInt32.max))"
        defer {
            Task { await IpcCondition.clearStorage(name: cvName) }
            Task { await IpcMutex.clearStorage(name: mtxName) }
        }
        _ = try await IpcCondition.open(name: cvName)
        _ = try await IpcMutex.open(name: mtxName)

        nonisolated(unsafe) var wakeCount = 0

        let waiters = (0..<5).map { _ in
            spawnPthread {
                let cv  = try! IpcCondition.openSync(name: cvName)
                let mtx = try! IpcMutex.openSync(name: mtxName)
                try! mtx.lock()
                try! cv.wait(mutex: mtx)
                wakeCount += 1
                try! mtx.unlock()
            }
        }

        var ts = timespec(tv_sec: 0, tv_nsec: 100_000_000); nanosleep(&ts, nil)

        let cv  = try await IpcCondition.open(name: cvName)
        let mtx = try await IpcMutex.open(name: mtxName)
        try mtx.lock()
        try cv.broadcast()
        try mtx.unlock()

        for w in waiters { await joinThread(w) }
        #expect(wakeCount == 5)
    }

    // Port of ConditionTest.TimedWait — wait(timeout:) returns false on timeout
    @Test("timed wait returns false on timeout")
    func timedWait() async throws {
        let cvName  = "swift_cvd_tw_cv_\(UInt32.random(in: 0..<UInt32.max))"
        let mtxName = "swift_cvd_tw_mx_\(UInt32.random(in: 0..<UInt32.max))"
        defer {
            Task { await IpcCondition.clearStorage(name: cvName) }
            Task { await IpcMutex.clearStorage(name: mtxName) }
        }
        let cv  = try await IpcCondition.open(name: cvName)
        let mtx = try await IpcMutex.open(name: mtxName)

        let t0 = ContinuousClock.now
        try mtx.lock()
        let signalled = try cv.wait(mutex: mtx, timeout: .milliseconds(100))
        try mtx.unlock()
        let elapsed = ContinuousClock.now - t0

        #expect(!signalled)
        #expect(elapsed >= .milliseconds(80))
    }

    // Port of ConditionTest.ProducerConsumer — predicate-based wait
    @Test("producer/consumer with predicate loop")
    func producerConsumer() async throws {
        let cvName  = "swift_cvd_pc_cv_\(UInt32.random(in: 0..<UInt32.max))"
        let mtxName = "swift_cvd_pc_mx_\(UInt32.random(in: 0..<UInt32.max))"
        defer {
            Task { await IpcCondition.clearStorage(name: cvName) }
            Task { await IpcMutex.clearStorage(name: mtxName) }
        }
        _ = try await IpcCondition.open(name: cvName)
        _ = try await IpcMutex.open(name: mtxName)

        nonisolated(unsafe) var buffer = 0
        nonisolated(unsafe) var ready  = false
        nonisolated(unsafe) var consumed = 0

        let producer = spawnPthread {
            var ts = timespec(tv_sec: 0, tv_nsec: 50_000_000); nanosleep(&ts, nil)
            let cv  = try! IpcCondition.openSync(name: cvName)
            let mtx = try! IpcMutex.openSync(name: mtxName)
            try! mtx.lock()
            buffer = 42; ready = true
            try! cv.notify()
            try! mtx.unlock()
        }

        let consumer = spawnPthread {
            let cv  = try! IpcCondition.openSync(name: cvName)
            let mtx = try! IpcMutex.openSync(name: mtxName)
            try! mtx.lock()
            while !ready {
                _ = try! cv.wait(mutex: mtx, timeout: .seconds(2))
            }
            consumed = buffer
            try! mtx.unlock()
        }

        await joinThread(producer); await joinThread(consumer)
        #expect(consumed == 42)
    }

    // Port of ConditionTest.MultipleNotify — 3 sequential notify calls
    @Test("3 sequential notify calls wake waiter 3 times")
    func multipleNotify() async throws {
        let cvName  = "swift_cvd_mn_cv_\(UInt32.random(in: 0..<UInt32.max))"
        let mtxName = "swift_cvd_mn_mx_\(UInt32.random(in: 0..<UInt32.max))"
        defer {
            Task { await IpcCondition.clearStorage(name: cvName) }
            Task { await IpcMutex.clearStorage(name: mtxName) }
        }
        _ = try await IpcCondition.open(name: cvName)
        _ = try await IpcMutex.open(name: mtxName)

        nonisolated(unsafe) var wakeCount = 0
        let numNotifications = 3

        let waiter = spawnPthread {
            let cv  = try! IpcCondition.openSync(name: cvName)
            let mtx = try! IpcMutex.openSync(name: mtxName)
            for _ in 0..<numNotifications {
                try! mtx.lock()
                _ = try! cv.wait(mutex: mtx, timeout: .seconds(1))
                wakeCount += 1
                try! mtx.unlock()
                var ts = timespec(tv_sec: 0, tv_nsec: 10_000_000); nanosleep(&ts, nil)
            }
        }

        for _ in 0..<numNotifications {
            var ts = timespec(tv_sec: 0, tv_nsec: 50_000_000); nanosleep(&ts, nil)
            let cv  = try await IpcCondition.open(name: cvName)
            let mtx = try await IpcMutex.open(name: mtxName)
            try mtx.lock(); try cv.notify(); try mtx.unlock()
        }

        await joinThread(waiter)
        #expect(wakeCount == numNotifications)
    }

    // Port of ConditionTest.SpuriousWakeupPattern — predicate loop handles spurious wakeups
    @Test("spurious wakeup pattern — predicate loop")
    func spuriousWakeupPattern() async throws {
        let cvName  = "swift_cvd_sp_cv_\(UInt32.random(in: 0..<UInt32.max))"
        let mtxName = "swift_cvd_sp_mx_\(UInt32.random(in: 0..<UInt32.max))"
        defer {
            Task { await IpcCondition.clearStorage(name: cvName) }
            Task { await IpcMutex.clearStorage(name: mtxName) }
        }
        _ = try await IpcCondition.open(name: cvName)
        _ = try await IpcMutex.open(name: mtxName)

        nonisolated(unsafe) var predicate = false
        nonisolated(unsafe) var done      = false

        let waiter = spawnPthread {
            let cv  = try! IpcCondition.openSync(name: cvName)
            let mtx = try! IpcMutex.openSync(name: mtxName)
            try! mtx.lock()
            while !predicate {
                _ = try! cv.wait(mutex: mtx, timeout: .milliseconds(100))
            }
            done = true
            try! mtx.unlock()
        }

        var ts = timespec(tv_sec: 0, tv_nsec: 50_000_000); nanosleep(&ts, nil)

        let cv  = try await IpcCondition.open(name: cvName)
        let mtx = try await IpcMutex.open(name: mtxName)
        try mtx.lock(); predicate = true; try cv.notify(); try mtx.unlock()

        await joinThread(waiter)
        #expect(done)
    }

    // Port of ConditionTest.BroadcastSequential — 4 threads all wake on broadcast
    @Test("broadcast sequential — 4 threads")
    func broadcastSequential() async throws {
        let cvName  = "swift_cvd_bs_cv_\(UInt32.random(in: 0..<UInt32.max))"
        let mtxName = "swift_cvd_bs_mx_\(UInt32.random(in: 0..<UInt32.max))"
        defer {
            Task { await IpcCondition.clearStorage(name: cvName) }
            Task { await IpcMutex.clearStorage(name: mtxName) }
        }
        _ = try await IpcCondition.open(name: cvName)
        _ = try await IpcMutex.open(name: mtxName)

        nonisolated(unsafe) var processed = 0

        let threads = (0..<4).map { _ in
            spawnPthread {
                let cv  = try! IpcCondition.openSync(name: cvName)
                let mtx = try! IpcMutex.openSync(name: mtxName)
                try! mtx.lock()
                _ = try! cv.wait(mutex: mtx, timeout: .seconds(2))
                processed += 1
                try! mtx.unlock()
            }
        }

        var ts = timespec(tv_sec: 0, tv_nsec: 100_000_000); nanosleep(&ts, nil)

        let cv  = try await IpcCondition.open(name: cvName)
        let mtx = try await IpcMutex.open(name: mtxName)
        try mtx.lock(); try cv.broadcast(); try mtx.unlock()

        for t in threads { await joinThread(t) }
        #expect(processed == 4)
    }

    // Port of ConditionTest.NamedSharing — two threads open same name independently
    @Test("named sharing — two threads open same name")
    func namedSharing() async throws {
        let cvName  = "swift_cvd_ns_cv_\(UInt32.random(in: 0..<UInt32.max))"
        let mtxName = "swift_cvd_ns_mx_\(UInt32.random(in: 0..<UInt32.max))"
        defer {
            Task { await IpcCondition.clearStorage(name: cvName) }
            Task { await IpcMutex.clearStorage(name: mtxName) }
        }
        _ = try await IpcCondition.open(name: cvName)
        _ = try await IpcMutex.open(name: mtxName)

        nonisolated(unsafe) var value = 0

        let t1 = spawnPthread {
            let cv  = try! IpcCondition.openSync(name: cvName)
            let mtx = try! IpcMutex.openSync(name: mtxName)
            try! mtx.lock()
            _ = try! cv.wait(mutex: mtx, timeout: .seconds(1))
            value = 100
            try! mtx.unlock()
        }
        let t2 = spawnPthread {
            var ts = timespec(tv_sec: 0, tv_nsec: 50_000_000); nanosleep(&ts, nil)
            let cv  = try! IpcCondition.openSync(name: cvName)
            let mtx = try! IpcMutex.openSync(name: mtxName)
            try! mtx.lock(); try! cv.notify(); try! mtx.unlock()
        }

        await joinThread(t1); await joinThread(t2)
        #expect(value == 100)
    }

    // Port of ConditionTest.NotifyVsBroadcast — notify wakes ≥1; broadcast wakes all
    @Test("notify wakes ≥1 waiter; broadcast wakes all 3")
    func notifyVsBroadcast() async throws {
        let cvName  = "swift_cvd_nvb_cv_\(UInt32.random(in: 0..<UInt32.max))"
        let mtxName = "swift_cvd_nvb_mx_\(UInt32.random(in: 0..<UInt32.max))"
        defer {
            Task { await IpcCondition.clearStorage(name: cvName) }
            Task { await IpcMutex.clearStorage(name: mtxName) }
        }
        _ = try await IpcCondition.open(name: cvName)
        _ = try await IpcMutex.open(name: mtxName)

        // Phase 1: notify — 3 waiters with 200ms timeout; send 1 notify after 20ms
        nonisolated(unsafe) var wokenByNotify = 0
        let phase1 = (0..<3).map { _ in
            spawnPthread {
                let cv  = try! IpcCondition.openSync(name: cvName)
                let mtx = try! IpcMutex.openSync(name: mtxName)
                try! mtx.lock()
                _ = try! cv.wait(mutex: mtx, timeout: .milliseconds(200))
                wokenByNotify += 1
                try! mtx.unlock()
            }
        }
        var ts20 = timespec(tv_sec: 0, tv_nsec: 20_000_000); nanosleep(&ts20, nil)
        let cv  = try await IpcCondition.open(name: cvName)
        let mtx = try await IpcMutex.open(name: mtxName)
        try mtx.lock(); try cv.notify(); try mtx.unlock()
        for t in phase1 { await joinThread(t) }
        #expect(wokenByNotify >= 1)

        // Phase 2: broadcast — 3 waiters with 2s timeout; all should wake
        nonisolated(unsafe) var wokenByBroadcast = 0
        let phase2 = (0..<3).map { _ in
            spawnPthread {
                let cv2  = try! IpcCondition.openSync(name: cvName)
                let mtx2 = try! IpcMutex.openSync(name: mtxName)
                try! mtx2.lock()
                _ = try! cv2.wait(mutex: mtx2, timeout: .seconds(2))
                wokenByBroadcast += 1
                try! mtx2.unlock()
            }
        }
        var ts50 = timespec(tv_sec: 0, tv_nsec: 50_000_000); nanosleep(&ts50, nil)
        try mtx.lock(); try cv.broadcast(); try mtx.unlock()
        for t in phase2 { await joinThread(t) }
        #expect(wokenByBroadcast == 3)
    }
}
