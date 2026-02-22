// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Correctness tests for BumpArena and SlabPool.
// Mirrors the workloads from rust/libipc/benches/alloc.rs.

import Testing
@testable import LibIPC

// MARK: - BumpArena tests

@Suite("BumpArena")
struct TestBumpArena {

    @Test("allocate returns non-null pointer")
    func allocateNonNull() {
        let arena = BumpArena(capacity: 256)
        let ptr = arena.allocate(byteCount: 48)
        #expect(ptr != UnsafeMutableRawPointer(bitPattern: 0))
    }

    @Test("allocateZeroed fills bytes with zero")
    func allocateZeroed() {
        let arena = BumpArena(capacity: 256)
        let buf = arena.allocateZeroed(byteCount: 64)
        #expect(buf.allSatisfy { $0 == 0 })
    }

    @Test("allocateCopy stores correct bytes")
    func allocateCopy() {
        let arena = BumpArena(capacity: 256)
        let src: [UInt8] = Array("hello arena".utf8)
        let buf = arena.allocateCopy(of: src)
        #expect(Array(buf) == src)
    }

    @Test("multiple allocations are non-overlapping")
    func nonOverlapping() {
        let arena = BumpArena(capacity: 512)
        let p1 = arena.allocate(byteCount: 64)
        let p2 = arena.allocate(byteCount: 64)
        // Pointers must differ by at least 64 bytes
        let diff = abs(Int(bitPattern: p2) - Int(bitPattern: p1))
        #expect(diff >= 64)
    }

    @Test("reset reclaims memory — allocatedBytes returns to 0")
    func resetReclaims() {
        let arena = BumpArena(capacity: 256)
        arena.allocate(byteCount: 128)
        #expect(arena.allocatedBytes > 0)
        arena.reset()
        #expect(arena.allocatedBytes == 0)
    }

    @Test("allocation after reset succeeds")
    func allocateAfterReset() {
        let arena = BumpArena(capacity: 256)
        arena.allocate(byteCount: 200)
        arena.reset()
        let ptr = arena.allocate(byteCount: 200)
        #expect(ptr != UnsafeMutableRawPointer(bitPattern: 0))
    }

    @Test("alignment is respected — 8-byte aligned pointer")
    func alignmentRespected() {
        let arena = BumpArena(capacity: 512)
        arena.allocate(byteCount: 1)   // misalign cursor
        let ptr = arena.allocate(byteCount: 8, alignment: 8)
        #expect(Int(bitPattern: ptr) % 8 == 0)
    }

    @Test("grows across chunk boundary — large allocation")
    func growsAcrossChunk() {
        let arena = BumpArena(capacity: 64)
        // First allocation fits; second exceeds initial chunk, triggers growth
        arena.allocate(byteCount: 48)
        let ptr = arena.allocate(byteCount: 256)
        #expect(ptr != UnsafeMutableRawPointer(bitPattern: 0))
        #expect(arena.totalCapacity > 64)
    }

    @Test("small / medium / large workload sizes all succeed")
    func workloadSizes() {
        let sizes = [48, 256, 4096]
        for size in sizes {
            let arena = BumpArena(capacity: size * 2)
            let buf = arena.allocateZeroed(byteCount: size)
            buf.baseAddress!.storeBytes(of: UInt8(0xAB), as: UInt8.self)
            let v = buf.baseAddress!.load(as: UInt8.self)
            #expect(v == 0xAB)
            arena.reset()
        }
    }

    @Test("allocateCopy of empty slice returns zero-count buffer")
    func allocateCopyEmpty() {
        let arena = BumpArena(capacity: 64)
        let buf = arena.allocateCopy(of: [])
        #expect(buf.count == 0)
    }
}

// MARK: - SlabPool tests

@Suite("SlabPool")
struct TestSlabPool {

    @Test("insertZeroed returns valid key and zeroed block")
    func insertZeroed() {
        let pool = SlabPool(blockSize: 64)
        let key = pool.insertZeroed()
        let buf = pool.get(key)
        #expect(buf != nil)
        #expect(buf!.allSatisfy { $0 == 0 })
    }

    @Test("insert from slice stores correct bytes (truncated to blockSize)")
    func insertFromSlice() {
        let pool = SlabPool(blockSize: 64)
        let src: [UInt8] = Array(repeating: 0xCD, count: 48)
        let key = pool.insert(from: src)
        let buf = pool.get(key)!
        #expect(Array(buf.prefix(48)) == src)
        #expect(Array(buf.suffix(16)).allSatisfy { $0 == 0 })
    }

    @Test("getMut allows mutation")
    func getMut() {
        let pool = SlabPool(blockSize: 64)
        let key = pool.insertZeroed()
        pool.getMut(key)!.baseAddress!.storeBytes(of: UInt8(0xAB), as: UInt8.self)
        #expect(pool.get(key)!.first == 0xAB)
    }

    @Test("remove returns slot to free list — count decrements")
    func removeDecrementsCount() {
        let pool = SlabPool(blockSize: 64)
        let key = pool.insertZeroed()
        #expect(pool.count == 1)
        pool.remove(key)
        #expect(pool.count == 0)
        #expect(pool.isEmpty)
    }

    @Test("removed key is reused on next insert")
    func removedKeyReused() {
        let pool = SlabPool(blockSize: 64)
        let k1 = pool.insertZeroed()
        pool.remove(k1)
        let k2 = pool.insertZeroed()
        #expect(k2 == k1)
    }

    @Test("get returns nil for removed key")
    func getAfterRemove() {
        let pool = SlabPool(blockSize: 64)
        let key = pool.insertZeroed()
        pool.remove(key)
        #expect(pool.get(key) == nil)
    }

    @Test("pool grows automatically beyond initial capacity")
    func autoGrow() {
        let pool = SlabPool(blockSize: 64, capacity: 4)
        var keys: [Int] = []
        for _ in 0..<16 { keys.append(pool.insertZeroed()) }
        #expect(pool.count == 16)
        #expect(pool.totalCapacity >= 16)
        for k in keys { pool.remove(k) }
        #expect(pool.isEmpty)
    }

    @Test("insert_remove cycle — 64-byte blocks (inline slot size)")
    func insertRemoveCycle64() {
        let pool = SlabPool(blockSize: 64, capacity: 32)
        for _ in 0..<1000 {
            let key = pool.insertZeroed()
            pool.getMut(key)!.baseAddress!.storeBytes(of: UInt8(0xAB), as: UInt8.self)
            pool.remove(key)
        }
        #expect(pool.isEmpty)
    }

    @Test("insert_remove cycle — 1024-byte blocks (chunk-align size)")
    func insertRemoveCycle1024() {
        let pool = SlabPool(blockSize: 1024, capacity: 32)
        let src = [UInt8](repeating: 0xCD, count: 256)
        for _ in 0..<500 {
            let key = pool.insert(from: src)
            #expect(pool.get(key)!.first == 0xCD)
            pool.remove(key)
        }
        #expect(pool.isEmpty)
    }

    @Test("multiple concurrent keys are independent")
    func multipleKeysIndependent() {
        let pool = SlabPool(blockSize: 64, capacity: 8)
        let k1 = pool.insert(from: [UInt8](repeating: 0x11, count: 64))
        let k2 = pool.insert(from: [UInt8](repeating: 0x22, count: 64))
        let k3 = pool.insert(from: [UInt8](repeating: 0x33, count: 64))
        #expect(pool.get(k1)!.first == 0x11)
        #expect(pool.get(k2)!.first == 0x22)
        #expect(pool.get(k3)!.first == 0x33)
        pool.remove(k2)
        #expect(pool.get(k1)!.first == 0x11)
        #expect(pool.get(k3)!.first == 0x33)
    }
}
