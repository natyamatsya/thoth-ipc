// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Tests for RwLock — mirrors rust/thoth-ipc/tests/test_rw_lock.rs

import Testing
@testable import ThothIPC

@Suite("RwLock")
struct TestRwLock {

    @Test("write lock and unlock")
    func writeLockUnlock() async {
        let rw = RwLock()
        await rw.lock()
        rw.unlock()
    }

    @Test("read lock and unlock")
    func readLockUnlock() async {
        let rw = RwLock()
        await rw.lockShared()
        rw.unlockShared()
    }

    @Test("multiple concurrent readers")
    func multipleReaders() async {
        let rw = RwLock()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await rw.lockShared()
                    rw.unlockShared()
                }
            }
        }
    }

    @Test("write lock excludes other writers")
    func writeExcludesWrite() async {
        let rw = RwLock()
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await rw.lock()
                    await counter.increment()
                    rw.unlock()
                }
            }
        }
        await #expect(counter.value == 50)
    }

    @Test("sequential write then read")
    func writeRead() async {
        let rw = RwLock()
        await rw.lock()
        rw.unlock()
        await rw.lockShared()
        rw.unlockShared()
    }
}
