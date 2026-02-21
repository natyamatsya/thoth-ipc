// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Tests for SpinLock — mirrors rust/libipc/tests/test_spin_lock.rs

import Testing
@testable import LibIPC

@Suite("SpinLock")
struct TestSpinLock {

    @Test("lock and unlock")
    func lockUnlock() async {
        let sl = SpinLock()
        await sl.lock()
        sl.unlock()
    }

    @Test("sequential lock/unlock multiple times")
    func sequential() async {
        let sl = SpinLock()
        for _ in 0..<10 {
            await sl.lock()
            sl.unlock()
        }
    }

    @Test("concurrent tasks serialise through the lock")
    func concurrent() async {
        let sl = SpinLock()
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await sl.lock()
                    await counter.increment()
                    sl.unlock()
                }
            }
        }
        await #expect(counter.value == 100)
    }
}
