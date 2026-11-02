// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Deeper IpcSemaphore tests — port of rust/thoth-ipc/tests/test_semaphore.rs (missing cases)
//
// A thread shares a semaphore as another process would: with a handle of its own, opened
// by name. The test's own handle stays open throughout, so a thread's handle closing never
// removes the semaphore (only the last handle does).

import Atomics
import Testing
@testable import ThothIPC
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs `body` with a handle of its own to semaphore `name`; a handle that cannot be
/// opened, or a body that throws, counts in `failures`.
private func withOwnHandle(
    _ name: String, _ failures: ManagedAtomic<Int>, _ body: (borrowing IpcSemaphore) throws -> Void
) {
    do {
        let sem = try IpcSemaphore.open(name: name, count: 0)
        try body(sem)
    } catch {
        failures.wrappingIncrement(ordering: .relaxed)
    }
}

// MARK: - Tests

@Suite("IpcSemaphore depth")
struct TestSemaphoreDepth {

    // Port of SemaphoreTest.PostWithCount — post 5, wait 5 times
    @Test("post 5 then wait 5 times")
    func postWithCount() throws {
        let name = "swift_semd_pc_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let sem = try IpcSemaphore.open(name: name, count: 0)
        try sem.post(count: 5)
        for _ in 0..<5 { try sem.wait() }
    }

    // Port of SemaphoreTest.WaitTimeout — wait on empty sem times out
    @Test("wait times out on empty semaphore")
    func waitTimeout() async throws {
        let name = "swift_semd_wt_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let sem = try IpcSemaphore.open(name: name, count: 0)
        let t0 = ContinuousClock.now
        let waited = try await sem.wait(timeout: .milliseconds(50))
        let elapsed = ContinuousClock.now - t0
        #expect(!waited)
        #expect(elapsed >= .milliseconds(40))
    }

    // Port of SemaphoreTest.InfiniteWait — post from another thread unblocks infinite wait
    @Test("infinite wait unblocked by post from another thread")
    func infiniteWait() async throws {
        let name = "swift_semd_iw_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let sem = try IpcSemaphore.open(name: name, count: 0)
        let succeeded = ManagedAtomic<Bool>(false)
        let failures = ManagedAtomic<Int>(0)

        let waiter = spawnPthread {
            withOwnHandle(name, failures) { s in
                try s.wait()
                succeeded.store(true, ordering: .releasing)
            }
        }

        var ts = timespec(tv_sec: 0, tv_nsec: 50_000_000); nanosleep(&ts, nil)
        try sem.post()
        await joinThread(waiter)
        let failuresValue = failures.load(ordering: .acquiring)
        #expect(failuresValue == 0)
        let succeededValue = succeeded.load(ordering: .acquiring)
        #expect(succeededValue)
    }

    // Port of SemaphoreTest.ProducerConsumer — 10 items, 1 producer, 1 consumer
    @Test("producer/consumer — 10 items")
    func producerConsumer() async throws {
        let name = "swift_semd_pc2_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let sem = try IpcSemaphore.open(name: name, count: 0)
        let produced = ManagedAtomic<Int>(0)
        let consumed = ManagedAtomic<Int>(0)
        let failures = ManagedAtomic<Int>(0)
        let count = 10

        let producer = spawnPthread {
            withOwnHandle(name, failures) { s in
                for _ in 0..<count {
                    produced.wrappingIncrement(ordering: .relaxed)
                    try s.post()
                    var ts = timespec(tv_sec: 0, tv_nsec: 1_000_000); nanosleep(&ts, nil)
                }
            }
        }
        let consumer = spawnPthread {
            withOwnHandle(name, failures) { s in
                for _ in 0..<count {
                    try s.wait()
                    consumed.wrappingIncrement(ordering: .relaxed)
                }
            }
        }

        await joinThread(producer); await joinThread(consumer)
        withExtendedLifetime(sem) {}
        let failuresValue = failures.load(ordering: .acquiring)
        #expect(failuresValue == 0)
        let producedValue = produced.load(ordering: .acquiring)
        #expect(producedValue == count)
        let consumedValue = consumed.load(ordering: .acquiring)
        #expect(consumedValue == count)
    }

    // Port of SemaphoreTest.MultipleProducersConsumers — 3×3, 5 items each
    @Test("multiple producers/consumers — 3×3, 5 items each")
    func multipleProducersConsumers() async throws {
        let name = "swift_semd_mpc_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let sem = try IpcSemaphore.open(name: name, count: 0)
        let totalProduced = ManagedAtomic<Int>(0)
        let totalConsumed = ManagedAtomic<Int>(0)
        let failures = ManagedAtomic<Int>(0)
        let itemsPer = 5
        let numProducers = 3
        let numConsumers = 3

        var threads: [pthread_t] = []
        for _ in 0..<numProducers {
            threads.append(spawnPthread {
                withOwnHandle(name, failures) { s in
                    for _ in 0..<itemsPer {
                        totalProduced.wrappingIncrement(ordering: .relaxed)
                        try s.post()
                    }
                }
            })
        }
        for _ in 0..<numConsumers {
            threads.append(spawnPthread {
                withOwnHandle(name, failures) { s in
                    for _ in 0..<itemsPer {
                        try s.wait()
                        totalConsumed.wrappingIncrement(ordering: .relaxed)
                    }
                }
            })
        }
        for t in threads { await joinThread(t) }
        withExtendedLifetime(sem) {}

        let failuresValue = failures.load(ordering: .acquiring)
        #expect(failuresValue == 0)
        let totalProducedValue = totalProduced.load(ordering: .acquiring)
        #expect(totalProducedValue == itemsPer * numProducers)
        let totalConsumedValue = totalConsumed.load(ordering: .acquiring)
        #expect(totalConsumedValue == itemsPer * numProducers)
    }

    // Port of SemaphoreTest.InitialCount — open with count 3, drain exactly 3
    @Test("initial count — drain exactly 3 then timeout")
    func initialCount() async throws {
        let name = "swift_semd_ic_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let sem = try IpcSemaphore.open(name: name, count: 3)
        for _ in 0..<3 { #expect(try await sem.wait(timeout: .milliseconds(10))) }
        #expect(!(try await sem.wait(timeout: .milliseconds(10))))
    }

    // Port of SemaphoreTest.RapidPost — post 100, consume 100
    @Test("rapid post 100 then consume 100")
    func rapidPost() async throws {
        let name = "swift_semd_rp_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let sem = try IpcSemaphore.open(name: name, count: 0)
        for _ in 0..<100 { try sem.post(count: 1) }
        var waitCount = 0
        for _ in 0..<100 {
            if try await sem.wait(timeout: .milliseconds(10)) { waitCount += 1 }
        }
        #expect(waitCount == 100)
    }

    // Port of SemaphoreTest.PostMultiple — post(10), drain 10, then empty
    @Test("post(count:10) then drain 10 then empty")
    func postMultiple() async throws {
        let name = "swift_semd_pm_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let sem = try IpcSemaphore.open(name: name, count: 0)
        try sem.post(count: 10)
        for _ in 0..<10 { #expect(try await sem.wait(timeout: .milliseconds(10))) }
        #expect(!(try await sem.wait(timeout: .milliseconds(10))))
    }

    // Port of SemaphoreTest.NamedSemaphoreSharing — two threads open same name
    @Test("named sharing — two threads open same name")
    func namedSharing() async throws {
        let name = "swift_semd_ns_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let sem = try IpcSemaphore.open(name: name, count: 0)
        let value = ManagedAtomic<Int>(0)
        let failures = ManagedAtomic<Int>(0)

        let t1 = spawnPthread {
            withOwnHandle(name, failures) { s in
                try s.wait()
                value.store(100, ordering: .releasing)
            }
        }
        let t2 = spawnPthread {
            var ts = timespec(tv_sec: 0, tv_nsec: 50_000_000); nanosleep(&ts, nil)
            withOwnHandle(name, failures) { s in try s.post() }
        }

        await joinThread(t1); await joinThread(t2)
        withExtendedLifetime(sem) {}
        let failuresValue = failures.load(ordering: .acquiring)
        #expect(failuresValue == 0)
        let valueValue = value.load(ordering: .acquiring)
        #expect(valueValue == 100)
    }

    // Port of SemaphoreTest.ConcurrentPost — 5 threads × 10 posts, then drain all
    @Test("concurrent post — 5 threads × 10 posts")
    func concurrentPost() async throws {
        let name = "swift_semd_cp_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let sem = try IpcSemaphore.open(name: name, count: 0)
        let threads = 5
        let postsPerThread = 10
        let postCount = ManagedAtomic<Int>(0)
        let failures = ManagedAtomic<Int>(0)

        let tids = (0..<threads).map { _ in
            spawnPthread {
                withOwnHandle(name, failures) { s in
                    for _ in 0..<postsPerThread {
                        try s.post()
                        postCount.wrappingIncrement(ordering: .relaxed)
                    }
                }
            }
        }
        for t in tids { await joinThread(t) }
        let failuresValue = failures.load(ordering: .acquiring)
        #expect(failuresValue == 0)
        let postCountValue = postCount.load(ordering: .acquiring)
        #expect(postCountValue == threads * postsPerThread)

        var consumed = 0
        for _ in 0..<(threads * postsPerThread) {
            if try await sem.wait(timeout: .milliseconds(10)) { consumed += 1 }
        }
        #expect(consumed == threads * postsPerThread)
    }

    // Port of SemaphoreTest.HighFrequency — 1000 post/wait pairs
    @Test("high frequency — 1000 post/wait pairs across two threads")
    func highFrequency() async throws {
        let name = "swift_semd_hf_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let sem = try IpcSemaphore.open(name: name, count: 0)
        let waited = ManagedAtomic<Int>(0)
        let failures = ManagedAtomic<Int>(0)

        let poster = spawnPthread {
            withOwnHandle(name, failures) { s in
                for _ in 0..<1000 { try s.post() }
            }
        }
        let waiter = spawnPthread {
            withOwnHandle(name, failures) { s in
                for _ in 0..<1000 {
                    try s.wait()
                    waited.wrappingIncrement(ordering: .relaxed)
                }
            }
        }

        await joinThread(poster); await joinThread(waiter)
        withExtendedLifetime(sem) {}
        let failuresValue = failures.load(ordering: .acquiring)
        #expect(failuresValue == 0)
        let waitedValue = waited.load(ordering: .acquiring)
        #expect(waitedValue == 1000)
    }
}
