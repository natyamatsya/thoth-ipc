// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Integration tests — port of rust/libipc/tests/interop.rs

import Testing
@testable import LibIPC

@Suite("Interop")
struct TestInterop {

    // Port of shm_create_write_read
    @Test("SHM create, write, read back")
    func shmCreateWriteRead() throws {
        let name = "swift_interop_shm_rw_\(UInt32.random(in: 0..<UInt32.max))"
        defer { ShmHandle.clearStorage(name: name) }

        let shm = try ShmHandle.acquire(name: name, size: 4096, mode: .createOrOpen)
        #expect(shm.mappedSize >= 4096)
        #expect(shm.refCount >= 1)

        let data: [UInt8] = Array("hello from swift".utf8)
        shm.ptr.copyMemory(from: data, byteCount: data.count)
        let readBack = Array(UnsafeRawBufferPointer(start: shm.ptr, count: data.count))
        #expect(readBack == data)
    }

    // Port of shm_ref_counting
    @Test("SHM ref counting — two handles, sequential drops")
    func shmRefCounting() throws {
        let name = "swift_interop_shm_ref_\(UInt32.random(in: 0..<UInt32.max))"
        defer { ShmHandle.clearStorage(name: name) }

        let shm1 = try ShmHandle.acquire(name: name, size: 1024, mode: .createOrOpen)
        #expect(shm1.refCount == 1)

        do {
            let shm2 = try ShmHandle.acquire(name: name, size: 1024, mode: .createOrOpen)
            #expect(shm2.refCount == 2)
            #expect(shm1.refCount == 2)
            // shm2 drops here
        }
        #expect(shm1.refCount == 1)
    }

    // Port of mutex_lock_unlock
    @Test("IpcMutex lock and unlock")
    func mutexLockUnlock() async throws {
        let name = "swift_interop_mtx_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await IpcMutex.clearStorage(name: name) } }
        await IpcMutex.clearStorage(name: name)

        let mtx = try await IpcMutex.open(name: name)
        try mtx.lock()
        try mtx.unlock()
    }

    // Port of scoped_access_write_read — write to SHM under mutex, read back
    @Test("ScopedAccess — write to SHM under mutex, read back")
    func scopedAccessWriteRead() async throws {
        let shmName = "swift_interop_sa_shm_\(UInt32.random(in: 0..<UInt32.max))"
        let mtxName = "swift_interop_sa_mtx_\(UInt32.random(in: 0..<UInt32.max))"
        defer {
            ShmHandle.clearStorage(name: shmName)
            Task { await IpcMutex.clearStorage(name: mtxName) }
        }
        await IpcMutex.clearStorage(name: mtxName)

        let shm     = try ShmHandle.acquire(name: shmName, size: 4096, mode: .createOrOpen)
        let payload: [UInt8] = Array("scoped write test".utf8)

        // Write under lock
        let mtx1 = try await IpcMutex.open(name: mtxName)
        try mtx1.lock()
        shm.ptr.copyMemory(from: payload, byteCount: payload.count)
        try mtx1.unlock()

        // Read under lock
        let mtx2 = try await IpcMutex.open(name: mtxName)
        try mtx2.lock()
        let readBack = Array(UnsafeRawBufferPointer(start: shm.ptr, count: payload.count))
        try mtx2.unlock()

        #expect(readBack == payload)
    }

    // Port of shm_name_fnv1a_matches_cpp — known FNV-1a test vectors
    @Test("SHM name FNV-1a matches C++ and Rust known vectors")
    func shmNameFnv1aMatchesCpp() {
        // FNV-1a of "" = 0xcbf29ce484222325
        #expect(fnv1a64([]) == 0xcbf2_9ce4_8422_2325)

        // FNV-1a of "a" = 0xaf63dc4c8601ec8c
        #expect(fnv1a64(Array("a".utf8)) == 0xaf63_dc4c_8601_ec8c)

        // makeShmName prepends '/' if missing
        #expect(makeShmName("foo").hasPrefix("/"))

        // makeShmName leaves existing '/' alone
        let withSlash = makeShmName("/bar")
        #expect(withSlash.hasPrefix("/"))
        #expect(withSlash.contains("bar"))
    }
}
