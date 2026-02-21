// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Tests for ShmHandle — mirrors rust/libipc/tests/test_shm.rs

import Testing
@testable import LibIPC

@Suite("ShmHandle")
struct TestShm {

    @Test("acquire createOrOpen creates a new segment")
    func acquireCreatesSegment() throws {
        let name = "swift_test_shm_create_\(UInt32.random(in: 0..<UInt32.max))"
        defer { ShmHandle.clearStorage(name: name) }
        let shm = try ShmHandle.acquire(name: name, size: 64, mode: .createOrOpen)
        #expect(shm.userSize == 64)
        #expect(shm.mappedSize >= 64)
        #expect(shm.ptr != UnsafeMutableRawPointer(bitPattern: 0))
    }

    @Test("acquire create fails if already exists")
    func acquireCreateFailsIfExists() throws {
        let name = "swift_test_shm_excl_\(UInt32.random(in: 0..<UInt32.max))"
        defer { ShmHandle.clearStorage(name: name) }
        let first = try ShmHandle.acquire(name: name, size: 64, mode: .create)
        #expect(throws: IpcError.self) {
            _ = try ShmHandle.acquire(name: name, size: 64, mode: .create)
        }
        withExtendedLifetime(first) {}
    }

    @Test("acquire open fails if not exists")
    func acquireOpenFailsIfMissing() {
        let name = "swift_test_shm_missing_\(UInt32.random(in: 0..<UInt32.max))"
        #expect(throws: IpcError.self) {
            let _ = try ShmHandle.acquire(name: name, size: 64, mode: .open)
        }
    }

    @Test("ref count starts at 1 after first acquire")
    func refCountStartsAtOne() throws {
        let name = "swift_test_shm_refcount_\(UInt32.random(in: 0..<UInt32.max))"
        defer { ShmHandle.clearStorage(name: name) }
        let shm = try ShmHandle.acquire(name: name, size: 64, mode: .createOrOpen)
        #expect(shm.refCount == 1)
        #expect(shm.previousRefCount == 0)
    }

    @Test("two opens of same name increment ref count")
    func twoOpensIncrementRefCount() throws {
        let name = "swift_test_shm_twoopen_\(UInt32.random(in: 0..<UInt32.max))"
        defer { ShmHandle.clearStorage(name: name) }
        let shm1 = try ShmHandle.acquire(name: name, size: 64, mode: .createOrOpen)
        let shm2 = try ShmHandle.acquire(name: name, size: 64, mode: .createOrOpen)
        #expect(shm1.refCount == 2)
        #expect(shm2.refCount == 2)
        #expect(shm2.previousRefCount == 1)
    }

    @Test("written data is visible via second handle")
    func writtenDataVisible() throws {
        let name = "swift_test_shm_rw_\(UInt32.random(in: 0..<UInt32.max))"
        defer { ShmHandle.clearStorage(name: name) }
        let shm1 = try ShmHandle.acquire(name: name, size: 64, mode: .createOrOpen)
        shm1.ptr.storeBytes(of: UInt64(0xDEADBEEF_CAFEBABE), as: UInt64.self)
        let shm2 = try ShmHandle.acquire(name: name, size: 64, mode: .open)
        let value = shm2.ptr.load(as: UInt64.self)
        #expect(value == 0xDEADBEEF_CAFEBABE)
    }

    @Test("empty name throws invalidArgument")
    func emptyNameThrows() {
        #expect(throws: IpcError.self) {
            let _ = try ShmHandle.acquire(name: "", size: 64, mode: .createOrOpen)
        }
    }

    @Test("zero size throws invalidArgument")
    func zeroSizeThrows() {
        #expect(throws: IpcError.self) {
            let _ = try ShmHandle.acquire(name: "test", size: 0, mode: .createOrOpen)
        }
    }

    @Test("calcSize aligns and adds ref-counter space")
    func calcSizeAligns() {
        #expect(calcSize(1) == 8)    // aligned to 4, + 4 for ref counter
        #expect(calcSize(4) == 8)
        #expect(calcSize(5) == 12)
        #expect(calcSize(64) == 68)
    }
}
