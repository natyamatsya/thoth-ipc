// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Deeper ShmHandle tests — port of rust/libipc/tests/test_shm.rs (missing cases)

import Testing
@testable import LibIPC

@Suite("ShmHandle depth")
struct TestShmDepth {

    // Port of ShmTest.GetMemory — write bytes and read them back
    @Test("write bytes and read back via same handle")
    func writeReadBytes() throws {
        let name = "swift_shmd_rw_\(UInt32.random(in: 0..<UInt32.max))"
        defer { ShmHandle.clearStorage(name: name) }
        let shm = try ShmHandle.acquire(name: name, size: 512, mode: .create)
        #expect(shm.ptr != UnsafeMutableRawPointer(bitPattern: 0))
        #expect(shm.mappedSize >= 512)

        let testData: [UInt8] = Array("Shared memory test data".utf8)
        shm.ptr.copyMemory(from: testData, byteCount: testData.count)
        let readBack = Array(UnsafeRawBufferPointer(start: shm.ptr, count: testData.count))
        #expect(readBack == testData)
    }

    // Port of ShmTest.ReleaseMemory — ref count is 1 after first acquire
    @Test("ref count is 1 after first acquire")
    func releaseRefCount() throws {
        let name = "swift_shmd_rel_\(UInt32.random(in: 0..<UInt32.max))"
        defer { ShmHandle.clearStorage(name: name) }
        let shm = try ShmHandle.acquire(name: name, size: 128, mode: .create)
        #expect(shm.refCount == 1)
    }

    // Port of ShmTest.ReferenceCount — open/drop cycle updates ref count
    @Test("ref count increments and decrements across open/drop")
    func referenceCount() throws {
        let name = "swift_shmd_rc_\(UInt32.random(in: 0..<UInt32.max))"
        defer { ShmHandle.clearStorage(name: name) }

        let shm1 = try ShmHandle.acquire(name: name, size: 512, mode: .createOrOpen)
        #expect(shm1.refCount == 1)

        do {
            let shm2 = try ShmHandle.acquire(name: name, size: 512, mode: .createOrOpen)
            #expect(shm1.refCount == 2)
            #expect(shm2.refCount == 2)
            // shm2 drops at end of do-block
        }
        #expect(shm1.refCount == 1)
    }

    // Port of ShmTest.HandleGet — write and read via createOrOpen
    @Test("write and read via createOrOpen handle")
    func handleGetWriteRead() throws {
        let name = "swift_shmd_get_\(UInt32.random(in: 0..<UInt32.max))"
        defer { ShmHandle.clearStorage(name: name) }
        let shm = try ShmHandle.acquire(name: name, size: 512, mode: .createOrOpen)

        let testStr: [UInt8] = Array("Handle get test".utf8)
        shm.ptr.copyMemory(from: testStr, byteCount: testStr.count)
        let readBack = Array(UnsafeRawBufferPointer(start: shm.ptr, count: testStr.count))
        #expect(readBack == testStr)
    }

    // Port of ShmTest.WriteReadData — struct written via h1, read via h2
    @Test("struct written via first handle is visible via second handle")
    func writeReadStruct() throws {
        let name = "swift_shmd_struct_\(UInt32.random(in: 0..<UInt32.max))"
        defer { ShmHandle.clearStorage(name: name) }

        let shm1 = try ShmHandle.acquire(name: name, size: 1024, mode: .createOrOpen)
        // Write: Int32(42) followed by "Shared memory data"
        shm1.ptr.storeBytes(of: Int32(42), as: Int32.self)
        let msg: [UInt8] = Array("Shared memory data".utf8)
        shm1.ptr.advanced(by: 4).copyMemory(from: msg, byteCount: msg.count)

        let shm2 = try ShmHandle.acquire(name: name, size: 1024, mode: .createOrOpen)
        let value = shm2.ptr.load(as: Int32.self)
        let readMsg = Array(UnsafeRawBufferPointer(start: shm2.ptr.advanced(by: 4), count: msg.count))
        #expect(value == 42)
        #expect(readMsg == msg)
    }

    // Port of ShmTest.HandleModes — create, open, createOrOpen all succeed
    @Test("create / open / createOrOpen modes all work on same segment")
    func handleModes() throws {
        let name = "swift_shmd_modes_\(UInt32.random(in: 0..<UInt32.max))"
        defer { ShmHandle.clearStorage(name: name) }

        let h1 = try ShmHandle.acquire(name: name, size: 256, mode: .create)
        #expect(h1.mappedSize >= 256)

        let h2 = try ShmHandle.acquire(name: name, size: 256, mode: .open)
        #expect(h2.mappedSize >= 256)

        let h3 = try ShmHandle.acquire(name: name, size: 256, mode: .createOrOpen)
        #expect(h3.mappedSize >= 256)
        withExtendedLifetime(h1) {}; withExtendedLifetime(h2) {}; withExtendedLifetime(h3) {}
    }

    // Port of ShmTest.MultipleHandles — write via h1, read via h2
    @Test("multiple handles share the same memory")
    func multipleHandlesSharedData() throws {
        let name = "swift_shmd_multi_\(UInt32.random(in: 0..<UInt32.max))"
        defer { ShmHandle.clearStorage(name: name) }

        let h1 = try ShmHandle.acquire(name: name, size: 512, mode: .createOrOpen)
        let h2 = try ShmHandle.acquire(name: name, size: 512, mode: .createOrOpen)

        h1.ptr.storeBytes(of: Int32(12345), as: Int32.self)
        let readVal = h2.ptr.load(as: Int32.self)
        #expect(readVal == 12345)
        withExtendedLifetime(h1) {}; withExtendedLifetime(h2) {}
    }

    // Port of ShmTest.LargeSegment — 10MB, write/verify pattern
    @Test("10MB segment — write and verify 1024-byte pattern")
    func largeSegment() throws {
        let name = "swift_shmd_large_\(UInt32.random(in: 0..<UInt32.max))"
        defer { ShmHandle.clearStorage(name: name) }

        let size = 10 * 1024 * 1024
        let shm = try ShmHandle.acquire(name: name, size: size, mode: .createOrOpen)
        #expect(shm.mappedSize >= size)

        for i in 0..<1024 { shm.ptr.storeBytes(of: UInt8(i % 256), toByteOffset: i, as: UInt8.self) }
        for i in 0..<1024 {
            let v = shm.ptr.load(fromByteOffset: i, as: UInt8.self)
            #expect(v == UInt8(i % 256))
        }
    }

    // Port of ShmTest.HandleClearStorage — after last handle drops, open fails
    @Test("after last handle is released, open-only fails")
    func handleClearStorage() throws {
        let name = "swift_shmd_clr_\(UInt32.random(in: 0..<UInt32.max))"
        do {
            let shm = try ShmHandle.acquire(name: name, size: 256, mode: .createOrOpen)
            withExtendedLifetime(shm) {}
            // shm dropped here — ref count was 1, segment unlinked
        }
        #expect(throws: IpcError.self) {
            _ = try ShmHandle.acquire(name: name, size: 256, mode: .open)
        }
    }

    // Port of open_after_unlink_fails — explicit unlink then open fails
    @Test("open fails after explicit unlink")
    func openAfterUnlinkFails() throws {
        let name = "swift_shmd_unlink_\(UInt32.random(in: 0..<UInt32.max))"
        let shm = try ShmHandle.acquire(name: name, size: 256, mode: .createOrOpen)
        shm.unlink()
        withExtendedLifetime(shm) {}
        #expect(throws: IpcError.self) {
            _ = try ShmHandle.acquire(name: name, size: 256, mode: .open)
        }
    }

    // Port of ref_count_three_handles — 3 opens, sequential drops
    @Test("ref count across 3 handles — sequential drops")
    func refCountThreeHandles() throws {
        let name = "swift_shmd_rc3_\(UInt32.random(in: 0..<UInt32.max))"
        defer { ShmHandle.clearStorage(name: name) }

        let h1 = try ShmHandle.acquire(name: name, size: 512, mode: .createOrOpen)
        #expect(h1.refCount == 1)

        do {
            let h2 = try ShmHandle.acquire(name: name, size: 512, mode: .createOrOpen)
            #expect(h1.refCount == 2)
            do {
                let h3 = try ShmHandle.acquire(name: name, size: 512, mode: .createOrOpen)
                #expect(h1.refCount == 3)
                withExtendedLifetime(h3) {}
            }
            #expect(h1.refCount == 2)
            withExtendedLifetime(h2) {}
        }
        #expect(h1.refCount == 1)
    }

    // Port of data_persistence — data survives handle close while another is open
    @Test("data persists while at least one handle remains open")
    func dataPersistence() throws {
        let name = "swift_shmd_persist_\(UInt32.random(in: 0..<UInt32.max))"
        defer { ShmHandle.clearStorage(name: name) }

        let payload: [UInt8] = Array("persistent payload 123456789".utf8)

        let shm2 = try ShmHandle.acquire(name: name, size: 4096, mode: .createOrOpen)
        do {
            let shm1 = try ShmHandle.acquire(name: name, size: 4096, mode: .createOrOpen)
            shm1.ptr.copyMemory(from: payload, byteCount: payload.count)
            // shm1 drops here; shm2 keeps segment alive
        }
        let shm3 = try ShmHandle.acquire(name: name, size: 4096, mode: .createOrOpen)
        let readBack = Array(UnsafeRawBufferPointer(start: shm3.ptr, count: payload.count))
        #expect(readBack == payload)
        withExtendedLifetime(shm2) {}; withExtendedLifetime(shm3) {}
    }

    // Port of various_sizes — a range of sizes all succeed
    @Test("various sizes from 1 byte to 64KB all map successfully")
    func variousSizes() throws {
        let sizes = [1, 4, 7, 15, 16, 17, 31, 32, 33, 63, 64, 65,
                     127, 128, 255, 256, 512, 1023, 1024, 4096, 8192, 65536]
        for size in sizes {
            let name = "swift_shmd_sz\(size)_\(UInt32.random(in: 0..<UInt32.max))"
            defer { ShmHandle.clearStorage(name: name) }
            let shm = try ShmHandle.acquire(name: name, size: size, mode: .createOrOpen)
            #expect(shm.mappedSize >= size, "size \(size): mappedSize \(shm.mappedSize) < requested")
        }
    }
}
