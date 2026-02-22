// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Deeper SpinLock tests — port of rust/libipc/tests/test_spin_lock.rs (missing cases)
//
// SpinLock is process-local, so all tests use Swift async/Task groups.

import Testing
@testable import LibIPC
import Atomics

@Suite("SpinLock depth")
struct TestSpinLockDepth {

    // Port of SpinLockTest.CriticalSection — 2 tasks × 1000 ops, atomic counter
    @Test("critical section — 2 tasks × 1000 ops")
    func criticalSection() async {
        let lock = SpinLock()
        let counter = ManagedAtomic<Int>(0)
        let iterations = 1000

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    for _ in 0..<iterations {
                        await lock.lock()
                        counter.wrappingIncrement(ordering: .relaxed)
                        lock.unlock()
                    }
                }
            }
        }
        let total = counter.load(ordering: .relaxed)
        #expect(total == iterations * 2)
    }

    // Port of SpinLockTest.MutualExclusion — 2 tasks, no simultaneous CS entry
    @Test("mutual exclusion — 2 tasks, no simultaneous critical section entry")
    func mutualExclusion() async {
        let lock      = SpinLock()
        let t1InCS    = ManagedAtomic<Bool>(false)
        let t2InCS    = ManagedAtomic<Bool>(false)
        let violation = ManagedAtomic<Bool>(false)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<100 {
                    await lock.lock()
                    t1InCS.store(true, ordering: .sequentiallyConsistent)
                    if t2InCS.load(ordering: .sequentiallyConsistent) {
                        violation.store(true, ordering: .sequentiallyConsistent)
                    }
                    try? await Task.sleep(nanoseconds: 10_000)
                    t1InCS.store(false, ordering: .sequentiallyConsistent)
                    lock.unlock()
                    await Task.yield()
                }
            }
            group.addTask {
                for _ in 0..<100 {
                    await lock.lock()
                    t2InCS.store(true, ordering: .sequentiallyConsistent)
                    if t1InCS.load(ordering: .sequentiallyConsistent) {
                        violation.store(true, ordering: .sequentiallyConsistent)
                    }
                    try? await Task.sleep(nanoseconds: 10_000)
                    t2InCS.store(false, ordering: .sequentiallyConsistent)
                    lock.unlock()
                    await Task.yield()
                }
            }
        }
        let v = violation.load(ordering: .sequentiallyConsistent)
        #expect(!v)
    }

    // Port of SpinLockTest.ConcurrentAccess — 4 tasks, non-atomic load-store under lock
    @Test("concurrent access — 4 tasks × 100 ops, non-atomic load-store under lock")
    func concurrentAccess() async {
        let lock       = SpinLock()
        let sharedData = ManagedAtomic<Int>(0)
        let numTasks   = 4
        let opsPerTask = 100

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<numTasks {
                group.addTask {
                    for _ in 0..<opsPerTask {
                        await lock.lock()
                        let temp = sharedData.load(ordering: .relaxed)
                        await Task.yield()
                        sharedData.store(temp + 1, ordering: .relaxed)
                        lock.unlock()
                    }
                }
            }
        }
        let total = sharedData.load(ordering: .relaxed)
        #expect(total == numTasks * opsPerTask)
    }

    // Port of SpinLockTest.RapidLockUnlock — 2 tasks × 10000 ops
    @Test("rapid lock/unlock — 2 tasks × 10000 ops")
    func rapidLockUnlock() async {
        let lock = SpinLock()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    for _ in 0..<10000 { await lock.lock(); lock.unlock() }
                }
            }
        }
    }

    // Port of SpinLockTest.Contention — 8 tasks × 50 ops with sleep
    @Test("contention — 8 tasks × 50 ops")
    func contention() async {
        let lock     = SpinLock()
        let workDone = ManagedAtomic<Int>(0)
        let numTasks = 8

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<numTasks {
                group.addTask {
                    for _ in 0..<50 {
                        await lock.lock()
                        workDone.wrappingIncrement(ordering: .relaxed)
                        try? await Task.sleep(nanoseconds: 100_000)
                        lock.unlock()
                        await Task.yield()
                    }
                }
            }
        }
        let total = workDone.load(ordering: .relaxed)
        #expect(total == numTasks * 50)
    }
}
