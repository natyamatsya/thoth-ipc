// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Deeper RwLock tests — port of rust/libipc/tests/test_rw_lock.rs (missing cases)
//
// RwLock is process-local (no SHM), so all tests use Swift async/Task groups.

import Testing
@testable import LibIPC
import Atomics

@Suite("RwLock depth")
struct TestRwLockDepth {

    // Port of RWLockTest.MultipleWriteCycles
    @Test("100 write lock/unlock cycles on one task")
    func multipleWriteCycles() async {
        let rw = RwLock()
        for _ in 0..<100 { await rw.lock(); rw.unlock() }
    }

    // Port of RWLockTest.MultipleReadCycles
    @Test("100 read lock/unlock cycles on one task")
    func multipleReadCycles() async {
        let rw = RwLock()
        for _ in 0..<100 { await rw.lockShared(); rw.unlockShared() }
    }

    // Port of RWLockTest.WriteLockProtection — 2 tasks × 500 write ops
    @Test("write lock protects counter — 2 tasks × 500 ops")
    func writeLockProtection() async {
        let rw = RwLock()
        let data = ManagedAtomic<Int>(0)
        let iterations = 500
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    for _ in 0..<iterations {
                        await rw.lock()
                        data.wrappingIncrement(ordering: .relaxed)
                        rw.unlock()
                    }
                }
            }
        }
        let total = data.load(ordering: .relaxed)
        #expect(total == iterations * 2)
    }

    // Port of RWLockTest.ConcurrentReaders — 5 tasks, verify >1 concurrent reader
    @Test("concurrent readers — 5 tasks, max concurrent > 1")
    func concurrentReaders() async {
        let rw = RwLock()
        let concurrentReaders = ManagedAtomic<Int>(0)
        let maxConcurrent    = ManagedAtomic<Int>(0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    for _ in 0..<20 {
                        await rw.lockShared()
                        let cur = concurrentReaders.loadThenWrappingIncrement(ordering: .sequentiallyConsistent) + 1
                        var prev = maxConcurrent.load(ordering: .relaxed)
                        while cur > prev {
                            let (ok, actual) = maxConcurrent.weakCompareExchange(
                                expected: prev, desired: cur,
                                successOrdering: .relaxed, failureOrdering: .relaxed)
                            if ok { break }
                            prev = actual
                        }
                        try? await Task.sleep(nanoseconds: 100_000)
                        concurrentReaders.wrappingDecrement(ordering: .sequentiallyConsistent)
                        rw.unlockShared()
                        await Task.yield()
                    }
                }
            }
        }
        let mc = maxConcurrent.load(ordering: .relaxed)
        #expect(mc > 1)
    }

    // Port of RWLockTest.WriterExclusiveAccess — 2 writers, no overlap
    @Test("writer exclusive access — 2 writers, no simultaneous entry")
    func writerExclusiveAccess() async {
        let rw = RwLock()
        let writerInCS = ManagedAtomic<Bool>(false)
        let violation  = ManagedAtomic<Bool>(false)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    for _ in 0..<50 {
                        await rw.lock()
                        if writerInCS.exchange(true, ordering: .sequentiallyConsistent) {
                            violation.store(true, ordering: .sequentiallyConsistent)
                        }
                        try? await Task.sleep(nanoseconds: 50_000)
                        writerInCS.store(false, ordering: .sequentiallyConsistent)
                        rw.unlock()
                        await Task.yield()
                    }
                }
            }
        }
        let v1 = violation.load(ordering: .sequentiallyConsistent)
        #expect(!v1)
    }

    // Port of RWLockTest.ReadersWritersNoOverlap — 2 readers + 1 writer, no overlap
    @Test("readers and writer never overlap")
    func readersWritersNoOverlap() async {
        let rw           = RwLock()
        let readers      = ManagedAtomic<Int>(0)
        let writerActive = ManagedAtomic<Bool>(false)
        let violation    = ManagedAtomic<Bool>(false)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    for _ in 0..<30 {
                        await rw.lockShared()
                        readers.wrappingIncrement(ordering: .sequentiallyConsistent)
                        if writerActive.load(ordering: .sequentiallyConsistent) {
                            violation.store(true, ordering: .sequentiallyConsistent)
                        }
                        try? await Task.sleep(nanoseconds: 50_000)
                        readers.wrappingDecrement(ordering: .sequentiallyConsistent)
                        rw.unlockShared()
                        await Task.yield()
                    }
                }
            }
            group.addTask {
                for _ in 0..<15 {
                    await rw.lock()
                    writerActive.store(true, ordering: .sequentiallyConsistent)
                    if readers.load(ordering: .sequentiallyConsistent) > 0 {
                        violation.store(true, ordering: .sequentiallyConsistent)
                    }
                    try? await Task.sleep(nanoseconds: 50_000)
                    writerActive.store(false, ordering: .sequentiallyConsistent)
                    rw.unlock()
                    await Task.yield()
                }
            }
        }
        let v2 = violation.load(ordering: .sequentiallyConsistent)
        #expect(!v2)
    }

    // Port of RWLockTest.ReadWriteReadPattern — 2 tasks, each does write then read 20×
    @Test("read-write-read pattern — 2 tasks × 20 iterations")
    func readWriteReadPattern() async {
        let rw   = RwLock()
        let data = ManagedAtomic<Int>(0)

        await withTaskGroup(of: Void.self) { group in
            for id in 1...2 {
                group.addTask {
                    for _ in 0..<20 {
                        await rw.lock()
                        data.wrappingIncrement(by: id, ordering: .relaxed)
                        rw.unlock()
                        await Task.yield()
                        await rw.lockShared()
                        #expect(data.load(ordering: .relaxed) >= 0)
                        rw.unlockShared()
                        await Task.yield()
                    }
                }
            }
        }
        // id=1 × 20 + id=2 × 20 = 60
        let d1 = data.load(ordering: .relaxed)
        #expect(d1 == 60)
    }

    // Port of RWLockTest.ManyReadersOneWriter — 10 readers + 1 writer
    @Test("many readers one writer — 10 readers × 50 reads, 1 writer × 100 writes")
    func manyReadersOneWriter() async {
        let rw        = RwLock()
        let data      = ManagedAtomic<Int>(0)
        let readCount = ManagedAtomic<Int>(0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    for _ in 0..<50 {
                        await rw.lockShared()
                        _ = data.load(ordering: .relaxed)
                        readCount.wrappingIncrement(ordering: .relaxed)
                        rw.unlockShared()
                        await Task.yield()
                    }
                }
            }
            group.addTask {
                for _ in 0..<100 {
                    await rw.lock()
                    data.wrappingIncrement(ordering: .relaxed)
                    rw.unlock()
                    await Task.yield()
                }
            }
        }
        let d2 = data.load(ordering: .relaxed)
        let rc = readCount.load(ordering: .relaxed)
        #expect(d2 == 100)
        #expect(rc == 500)
    }

    // Port of RWLockTest.RapidReadLocks — 3 tasks × 5000 read lock/unlock
    @Test("rapid read locks — 3 tasks × 5000 ops")
    func rapidReadLocks() async {
        let rw = RwLock()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    for _ in 0..<5000 { await rw.lockShared(); rw.unlockShared() }
                }
            }
        }
    }

    // Port of RWLockTest.RapidWriteLocks — 2 tasks × 2000 write lock/unlock
    @Test("rapid write locks — 2 tasks × 2000 ops")
    func rapidWriteLocks() async {
        let rw = RwLock()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    for _ in 0..<2000 { await rw.lock(); rw.unlock() }
                }
            }
        }
    }

    // Port of RWLockTest.MixedRapidOperations — 2 readers × 1000 + 1 writer × 500
    @Test("mixed rapid operations — 2 readers × 1000, 1 writer × 500")
    func mixedRapidOperations() async {
        let rw = RwLock()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    for _ in 0..<1000 { await rw.lockShared(); rw.unlockShared() }
                }
            }
            group.addTask {
                for _ in 0..<500 { await rw.lock(); rw.unlock() }
            }
        }
    }

    // Port of RWLockTest.WriteLockBlocksReaders — writer holds lock, reader must wait
    @Test("write lock blocks readers until released")
    func writeLockBlocksReaders() async {
        let rw          = RwLock()
        let writeLocked = ManagedAtomic<Bool>(false)
        let violation   = ManagedAtomic<Bool>(false)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await rw.lock()
                writeLocked.store(true, ordering: .sequentiallyConsistent)
                try? await Task.sleep(nanoseconds: 100_000_000)
                writeLocked.store(false, ordering: .sequentiallyConsistent)
                rw.unlock()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 20_000_000)
                await rw.lockShared()
                if writeLocked.load(ordering: .sequentiallyConsistent) {
                    violation.store(true, ordering: .sequentiallyConsistent)
                }
                rw.unlockShared()
            }
        }
        let v3 = violation.load(ordering: .sequentiallyConsistent)
        #expect(!v3)
    }

    // Port of RWLockTest.MultipleWriteLockPattern — single task, read-then-write 100×
    @Test("read-then-write pattern — 100 cycles on one task")
    func multipleWriteLockPattern() async {
        let rw = RwLock()
        var data = 0
        for _ in 0..<100 {
            await rw.lockShared()
            let temp = data
            rw.unlockShared()
            await rw.lock()
            data = temp + 1
            rw.unlock()
        }
        #expect(data == 100)
    }

    // Port of RWLockTest.ConcurrentMixedOperations — 4 tasks, 2/3 reads 1/3 writes
    @Test("concurrent mixed operations — 4 tasks, 2/3 reads 1/3 writes")
    func concurrentMixedOperations() async {
        let rw     = RwLock()
        let data   = ManagedAtomic<Int>(0)
        let reads  = ManagedAtomic<Int>(0)
        let writes = ManagedAtomic<Int>(0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    for i in 0..<50 {
                        if i % 3 == 0 {
                            await rw.lock()
                            data.wrappingIncrement(ordering: .relaxed)
                            writes.wrappingIncrement(ordering: .relaxed)
                            rw.unlock()
                        } else {
                            await rw.lockShared()
                            _ = data.load(ordering: .relaxed)
                            reads.wrappingIncrement(ordering: .relaxed)
                            rw.unlockShared()
                        }
                        await Task.yield()
                    }
                }
            }
        }
        let r = reads.load(ordering: .relaxed)
        let w = writes.load(ordering: .relaxed)
        #expect(r > 0)
        #expect(w > 0)
    }
}
