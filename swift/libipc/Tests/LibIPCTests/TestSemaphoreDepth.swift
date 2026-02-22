// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Deeper IpcSemaphore tests — port of rust/libipc/tests/test_semaphore.rs (missing cases)
//
// Note: IpcSemaphore.deinit calls sem_unlink, so pthread-based tests that need
// multiple threads to share a semaphore use raw sem_open/sem_wait/sem_post
// directly to avoid the unlink-on-deinit issue.

import Testing
@testable import LibIPC
import Darwin.POSIX

// MARK: - raw semaphore helpers for pthread tests

private func semOpen(_ posixName: String, count: UInt32 = 0) -> UnsafeMutablePointer<sem_t> {
    let h = posixName.withCString { sem_open($0, O_CREAT, mode_t(0o666), count) }
    precondition(h != nil && h != SEM_FAILED, "sem_open failed: \(errno)")
    return h.unsafelyUnwrapped
}

private func semClose(_ h: UnsafeMutablePointer<sem_t>) { sem_close(h) }
private func semUnlink(_ posixName: String) { _ = posixName.withCString { sem_unlink($0) } }
private func semWait(_ h: UnsafeMutablePointer<sem_t>) { sem_wait(h) }
private func semPost(_ h: UnsafeMutablePointer<sem_t>) { sem_post(h) }

private func semPosixName(_ name: String) -> String {
    // Mirror IpcSemaphore's naming: makeShmName("\(name)_s")
    // makeShmName prepends "/" and replaces invalid chars with "_"
    let raw = "\(name)_s"
    let sanitized = raw.map { c -> Character in
        c.isLetter || c.isNumber || c == "_" || c == "-" ? c : "_"
    }
    return "/" + String(sanitized)
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
        let pname = semPosixName("swift_semd_iw_\(UInt32.random(in: 0..<UInt32.max))")
        defer { semUnlink(pname) }

        let h = semOpen(pname, count: 0)
        defer { semClose(h) }

        nonisolated(unsafe) var succeeded = false

        let waiter = spawnPthread {
            let wh = semOpen(pname, count: 0)
            defer { semClose(wh) }
            semWait(wh)
            succeeded = true
        }

        var ts = timespec(tv_sec: 0, tv_nsec: 50_000_000); nanosleep(&ts, nil)
        semPost(h)
        await joinThread(waiter)
        #expect(succeeded)
    }

    // Port of SemaphoreTest.ProducerConsumer — 10 items, 1 producer, 1 consumer
    @Test("producer/consumer — 10 items")
    func producerConsumer() async throws {
        let pname = semPosixName("swift_semd_pc2_\(UInt32.random(in: 0..<UInt32.max))")
        defer { semUnlink(pname) }

        let h = semOpen(pname, count: 0)
        defer { semClose(h) }

        nonisolated(unsafe) var produced = 0
        nonisolated(unsafe) var consumed = 0
        let count = 10

        let producer = spawnPthread {
            let ph = semOpen(pname, count: 0)
            defer { semClose(ph) }
            for _ in 0..<count {
                produced += 1
                semPost(ph)
                var ts = timespec(tv_sec: 0, tv_nsec: 1_000_000); nanosleep(&ts, nil)
            }
        }
        let consumer = spawnPthread {
            let ch = semOpen(pname, count: 0)
            defer { semClose(ch) }
            for _ in 0..<count {
                semWait(ch)
                consumed += 1
            }
        }

        await joinThread(producer); await joinThread(consumer)
        #expect(produced == count)
        #expect(consumed == count)
    }

    // Port of SemaphoreTest.MultipleProducersConsumers — 3×3, 5 items each
    @Test("multiple producers/consumers — 3×3, 5 items each")
    func multipleProducersConsumers() async throws {
        let pname = semPosixName("swift_semd_mpc_\(UInt32.random(in: 0..<UInt32.max))")
        defer { semUnlink(pname) }

        let h = semOpen(pname, count: 0)
        defer { semClose(h) }

        nonisolated(unsafe) var totalProduced = 0
        nonisolated(unsafe) var totalConsumed = 0
        let itemsPer = 5
        let numProducers = 3
        let numConsumers = 3

        var threads: [pthread_t] = []
        for _ in 0..<numProducers {
            threads.append(spawnPthread {
                let ph = semOpen(pname, count: 0)
                defer { semClose(ph) }
                for _ in 0..<itemsPer { totalProduced += 1; semPost(ph) }
            })
        }
        for _ in 0..<numConsumers {
            threads.append(spawnPthread {
                let ch = semOpen(pname, count: 0)
                defer { semClose(ch) }
                for _ in 0..<itemsPer { semWait(ch); totalConsumed += 1 }
            })
        }
        for t in threads { await joinThread(t) }

        #expect(totalProduced == itemsPer * numProducers)
        #expect(totalConsumed == itemsPer * numProducers)
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
        let pname = semPosixName("swift_semd_ns_\(UInt32.random(in: 0..<UInt32.max))")
        defer { semUnlink(pname) }

        let h = semOpen(pname, count: 0)
        defer { semClose(h) }

        nonisolated(unsafe) var value = 0

        let t1 = spawnPthread {
            let sh = semOpen(pname, count: 0)
            defer { semClose(sh) }
            semWait(sh)
            value = 100
        }
        let t2 = spawnPthread {
            var ts = timespec(tv_sec: 0, tv_nsec: 50_000_000); nanosleep(&ts, nil)
            let sh = semOpen(pname, count: 0)
            defer { semClose(sh) }
            semPost(sh)
        }

        await joinThread(t1); await joinThread(t2)
        #expect(value == 100)
    }

    // Port of SemaphoreTest.ConcurrentPost — 5 threads × 10 posts, then drain all
    @Test("concurrent post — 5 threads × 10 posts")
    func concurrentPost() async throws {
        let name = "swift_semd_cp_\(UInt32.random(in: 0..<UInt32.max))"
        defer { IpcSemaphore.clearStorage(name: name) }
        let sem = try IpcSemaphore.open(name: name, count: 0)
        let pname = semPosixName("\(name)")

        let threads = 5
        let postsPerThread = 10
        // Use a mutex-protected counter to avoid data race
        nonisolated(unsafe) var postCount = 0
        nonisolated(unsafe) var mu = pthread_mutex_t()
        pthread_mutex_init(&mu, nil)

        let tids = (0..<threads).map { _ in
            spawnPthread {
                let sh = semOpen(pname, count: 0)
                defer { semClose(sh) }
                for _ in 0..<postsPerThread {
                    semPost(sh)
                    pthread_mutex_lock(&mu); postCount += 1; pthread_mutex_unlock(&mu)
                }
            }
        }
        for t in tids { await joinThread(t) }
        pthread_mutex_destroy(&mu)
        #expect(postCount == threads * postsPerThread)

        var consumed = 0
        for _ in 0..<(threads * postsPerThread) {
            if try await sem.wait(timeout: .milliseconds(10)) { consumed += 1 }
        }
        #expect(consumed == threads * postsPerThread)
    }

    // Port of SemaphoreTest.HighFrequency — 1000 post/wait pairs
    @Test("high frequency — 1000 post/wait pairs across two threads")
    func highFrequency() async throws {
        let pname = semPosixName("swift_semd_hf_\(UInt32.random(in: 0..<UInt32.max))")
        defer { semUnlink(pname) }

        let h = semOpen(pname, count: 0)
        defer { semClose(h) }

        let poster = spawnPthread {
            let ph = semOpen(pname, count: 0)
            defer { semClose(ph) }
            for _ in 0..<1000 { semPost(ph) }
        }
        let waiter = spawnPthread {
            let wh = semOpen(pname, count: 0)
            defer { semClose(wh) }
            for _ in 0..<1000 { semWait(wh) }
        }

        await joinThread(poster); await joinThread(waiter)
        // Completes without deadlock
    }
}
