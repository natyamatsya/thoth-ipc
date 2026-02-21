// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

import Testing
@testable import LibIPC

@Suite("IpcBuffer")
struct TestIpcBuffer {

    @Test("empty buffer")
    func emptyBuffer() {
        let buf = IpcBuffer()
        #expect(buf.isEmpty)
        #expect(buf.count == 0)
    }

    @Test("from bytes")
    func fromBytes() {
        let buf = IpcBuffer(bytes: [1, 2, 3])
        #expect(!buf.isEmpty)
        #expect(buf.count == 3)
        #expect(buf.bytes == [1, 2, 3])
    }

    @Test("from slice")
    func fromSlice() {
        let src: [UInt8] = [10, 20, 30, 40]
        let buf = IpcBuffer(slice: src)
        #expect(buf.bytes == src)
    }

    @Test("from string appends null terminator")
    func fromString() {
        let buf = IpcBuffer(string: "hi")
        #expect(buf.bytes == [UInt8(ascii: "h"), UInt8(ascii: "i"), 0])
    }

    @Test("equality")
    func equality() {
        let a = IpcBuffer(bytes: [1, 2, 3])
        let b = IpcBuffer(bytes: [1, 2, 3])
        let c = IpcBuffer(bytes: [1, 2])
        #expect(a == b)
        #expect(a != c)
    }

    @Test("swap")
    func swap() {
        var a = IpcBuffer(bytes: [1, 2])
        var b = IpcBuffer(bytes: [3, 4, 5])
        a.swap(with: &b)
        #expect(a.bytes == [3, 4, 5])
        #expect(b.bytes == [1, 2])
    }
}
