// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

import Testing
@testable import LibIPC

@Suite("ShmRing")
struct TestShmRing {

    @Test("openOrCreate succeeds")
    func openOrCreate() throws {
        let ring = ShmRing<UInt32>(name: "test_shmring_open", capacity: 8)
        try ring.openOrCreate()
        #expect(ring.valid)
        ring.destroy()
    }

    @Test("write and read round-trip")
    func writeRead() throws {
        let ring = ShmRing<UInt32>(name: "test_shmring_rw", capacity: 8)
        try ring.openOrCreate()

        #expect(ring.write(42))
        var out: UInt32 = 0
        #expect(ring.read(into: &out))
        #expect(out == 42)

        ring.destroy()
    }

    @Test("read returns false when empty")
    func readEmpty() throws {
        let ring = ShmRing<UInt32>(name: "test_shmring_empty", capacity: 4)
        try ring.openOrCreate()
        var out: UInt32 = 0
        #expect(!ring.read(into: &out))
        ring.destroy()
    }

    @Test("write returns false when full")
    func writeFull() throws {
        let ring = ShmRing<UInt32>(name: "test_shmring_full", capacity: 4)
        try ring.openOrCreate()
        for i: UInt32 in 0..<4 { #expect(ring.write(i)) }
        #expect(!ring.write(99))
        ring.destroy()
    }

    @Test("writeOverwrite replaces oldest when full")
    func writeOverwrite() throws {
        let ring = ShmRing<UInt32>(name: "test_shmring_overwrite", capacity: 4)
        try ring.openOrCreate()
        for i: UInt32 in 0..<4 { ring.write(i) }
        ring.writeOverwrite(99)
        var out: UInt32 = 0
        #expect(ring.read(into: &out))
        #expect(out == 1)
        ring.destroy()
    }

    @Test("available and isEmpty")
    func availability() throws {
        let ring = ShmRing<UInt32>(name: "test_shmring_avail", capacity: 4)
        try ring.openOrCreate()
        #expect(ring.isEmpty)
        #expect(ring.available == 0)
        ring.write(1)
        ring.write(2)
        #expect(ring.available == 2)
        #expect(!ring.isEmpty)
        ring.destroy()
    }

    @Test("FIFO ordering across multiple items")
    func fifoOrder() throws {
        let ring = ShmRing<UInt32>(name: "test_shmring_fifo", capacity: 8)
        try ring.openOrCreate()
        for i: UInt32 in 0..<5 { ring.write(i) }
        for i: UInt32 in 0..<5 {
            var out: UInt32 = 0
            #expect(ring.read(into: &out))
            #expect(out == i)
        }
        ring.destroy()
    }

    @Test("close and reopen sees existing data")
    func closeReopen() throws {
        let name = "test_shmring_reopen"
        let ring1 = ShmRing<UInt32>(name: name, capacity: 8)
        try ring1.openOrCreate()
        ring1.write(77)
        ring1.close()

        let ring2 = ShmRing<UInt32>(name: name, capacity: 8)
        try ring2.openOrCreate()
        var out: UInt32 = 0
        #expect(ring2.read(into: &out))
        #expect(out == 77)
        ring2.destroy()
    }
}
