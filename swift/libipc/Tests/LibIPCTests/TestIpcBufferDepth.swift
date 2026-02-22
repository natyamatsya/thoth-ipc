// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Deeper IpcBuffer tests — port of rust/libipc/tests/test_buffer.rs (missing cases)

import Testing
@testable import LibIPC

@Suite("IpcBuffer depth")
struct TestIpcBufferDepth {

    // Port of BufferTest.ConstructorFromStr — null terminator included
    @Test("init(string:) appends null terminator and stores all bytes")
    func fromStringNullTerm() {
        let buf = IpcBuffer(string: "Hello")
        #expect(!buf.isEmpty)
        #expect(buf.count == 6)
        #expect(buf.bytes[0..<5] == [72, 101, 108, 108, 111])
        #expect(buf.bytes[5] == 0)
    }

    // Port of BufferTest.MoveConstructor (clone)
    @Test("copy produces equal independent buffer")
    func copyProducesEqual() {
        let buf1 = IpcBuffer(bytes: Array("Clone test".utf8))
        let buf2 = buf1
        #expect(buf1.bytes == buf2.bytes)
        #expect(!buf2.isEmpty)
        #expect(buf2.count == 10)
    }

    // Port of BufferTest.ToVector
    @Test("bytes array matches original data")
    func bytesMatchOriginal() {
        let data: [UInt8] = [10, 20, 30, 40, 50]
        let buf = IpcBuffer(bytes: data)
        #expect(buf.bytes == data)
        #expect(buf.count == 5)
    }

    // Port of BufferTest.EqualityOperator
    @Test("equal buffers compare equal, different buffers compare unequal")
    func equality() {
        let buf1 = IpcBuffer(bytes: [1, 2, 3, 4, 5])
        let buf2 = IpcBuffer(bytes: [1, 2, 3, 4, 5])
        let buf3 = IpcBuffer(bytes: [5, 4, 3, 2, 1])
        #expect(buf1.bytes == buf2.bytes)
        #expect(buf1.bytes != buf3.bytes)
    }

    // Port of BufferTest.EqualityWithDifferentSizes
    @Test("buffers of different sizes are not equal")
    func equalityDifferentSizes() {
        let buf1 = IpcBuffer(bytes: [1, 2, 3, 4, 5])
        let buf2 = IpcBuffer(bytes: [1, 2, 3])
        #expect(buf1.bytes != buf2.bytes)
    }

    // Port of BufferTest.EmptyBuffersComparison
    @Test("two empty buffers are equal")
    func emptyBuffersEqual() {
        let buf1 = IpcBuffer()
        let buf2 = IpcBuffer()
        #expect(buf1.bytes == buf2.bytes)
    }

    // Port of BufferTest.LargeBuffer — 1MB
    @Test("1MB buffer stores and retrieves correctly")
    func largeBuffer() {
        let largeSize = 1024 * 1024
        let data = (0..<largeSize).map { UInt8($0 % 256) }
        let buf = IpcBuffer(bytes: data)
        #expect(!buf.isEmpty)
        #expect(buf.count == largeSize)
        for i in 0..<100 {
            #expect(buf.bytes[i] == UInt8(i % 256))
        }
    }

    // Port of BufferTest.MultipleMoves — init(slice:) from a collection
    @Test("init(slice:) from a collection produces correct buffer")
    func initFromSlice() {
        let data: [UInt8] = Array("Multi-move".utf8)
        let buf = IpcBuffer(slice: data[...])
        #expect(!buf.isEmpty)
        #expect(buf.bytes == data)
    }

    // Port of BufferTest.FromString — String → IpcBuffer via init(string:)
    @Test("init(string:) from String includes null terminator")
    func fromString() {
        let buf = IpcBuffer(string: "test")
        #expect(buf.count == 5)
        #expect(Array(buf.bytes.prefix(4)) == Array("test".utf8))
        #expect(buf.bytes[4] == 0)
    }

    // Port of BufferTest.DataMut — mutate bytes in place
    @Test("bytes can be mutated via var copy")
    func mutateBytes() {
        var buf = IpcBuffer(bytes: [1, 2, 3])
        var mutableBytes = buf.bytes
        mutableBytes[0] = 99
        buf = IpcBuffer(bytes: mutableBytes)
        #expect(buf.bytes[0] == 99)
    }

    // Port of BufferTest.Default
    @Test("default init produces empty buffer")
    func defaultInit() {
        let buf = IpcBuffer()
        #expect(buf.isEmpty)
        #expect(buf.count == 0)
        #expect(buf.bytes.isEmpty)
    }

    // Port of BufferTest.FromSliceTrait — init(slice:) from ArraySlice
    @Test("init(slice:) from ArraySlice")
    func fromSliceTrait() {
        let data: [UInt8] = [1, 2, 3]
        let buf = IpcBuffer(slice: data[...])
        #expect(buf.bytes == [1, 2, 3])
    }
}
