// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Tests for TypedRoute<T> and TypedChannel<T>.
// Uses a minimal hand-written FlatBuffers table `PingMsg` with a single
// UInt32 `value` field, matching what flatc would generate.

import Testing
import FlatBuffers
@testable import LibIPC

// MARK: - Minimal FlatBuffers table: PingMsg { value: uint32 }
//
// FlatBuffers table layout:
//   offset 0: vtable offset (int32, negative)
//   vtable: [vtable_size, object_size, field0_offset]
//   field0 at inline offset 4 from object start (after vtable ref)

struct PingMsg: FlatBufferTable, Verifiable {
    private var _accessor: Table
    public var __buffer: ByteBuffer! { _accessor.bb }

    public init(_ bb: ByteBuffer, o: Int32) { _accessor = Table(bb: bb, position: o) }

    var value: UInt32 {
        let o = _accessor.offset(4)
        return o == 0 ? 0 : _accessor.readBuffer(of: UInt32.self, at: o)
    }

    static func verify<T>(_ verifier: inout Verifier, at position: Int, of type: T.Type) throws where T: Verifiable {
        var v = try verifier.visitTable(at: position)
        try v.visit(field: 4, fieldName: "value", required: false, type: UInt32.self)
        v.finish()
    }

    static func createPingMsg(_ fbb: inout FlatBufferBuilder, value: UInt32) -> Offset {
        let start = fbb.startTable(with: 1)
        fbb.add(element: value, def: UInt32(0), at: 4)
        return Offset(offset: fbb.endTable(at: start))
    }
}

// MARK: - TypedRoute tests

@Suite("TypedRoute")
struct TestTypedRoute {

    @Test("connect sender and receiver")
    func connectBoth() async throws {
        let tx = try await TypedRoute<PingMsg>.connect(name: "test_tr_connect", mode: .sender)
        let rx = try await TypedRoute<PingMsg>.connect(name: "test_tr_connect", mode: .receiver)
        tx.disconnect(); rx.disconnect()
        await TypedRoute<PingMsg>.clearStorage(name: "test_tr_connect")
    }

    @Test("send and recv typed message")
    func roundTrip() async throws {
        let tx = try await TypedRoute<PingMsg>.connect(name: "test_tr_rt", mode: .sender)
        let rx = try await TypedRoute<PingMsg>.connect(name: "test_tr_rt", mode: .receiver)

        var b = Builder(initialSize: 64)
        let root = PingMsg.createPingMsg(&b.fbb, value: 42)
        b.finish(root)

        let sent = try tx.send(builder: b, timeout: .seconds(1))
        #expect(sent == true)

        let msg = try rx.recv(timeout: .seconds(1))
        #expect(!msg.isEmpty)
        #expect(msg.root()?.value == 42)

        tx.disconnect(); rx.disconnect()
        await TypedRoute<PingMsg>.clearStorage(name: "test_tr_rt")
    }

    @Test("tryRecv returns empty when no data")
    func tryRecvEmpty() async throws {
        let rx = try await TypedRoute<PingMsg>.connect(name: "test_tr_tryrecv", mode: .receiver)
        let msg = try rx.tryRecv()
        #expect(msg.isEmpty)
        rx.disconnect()
        await TypedRoute<PingMsg>.clearStorage(name: "test_tr_tryrecv")
    }

    @Test("recv times out when no data")
    func recvTimeout() async throws {
        let rx = try await TypedRoute<PingMsg>.connect(name: "test_tr_timeout", mode: .receiver)
        let msg = try rx.recv(timeout: .milliseconds(50))
        #expect(msg.isEmpty)
        rx.disconnect()
        await TypedRoute<PingMsg>.clearStorage(name: "test_tr_timeout")
    }

    @Test("multiple messages in sequence")
    func multipleMessages() async throws {
        let tx = try await TypedRoute<PingMsg>.connect(name: "test_tr_multi", mode: .sender)
        let rx = try await TypedRoute<PingMsg>.connect(name: "test_tr_multi", mode: .receiver)

        for i: UInt32 in 0..<4 {
            var b = Builder(initialSize: 64)
            b.finish(PingMsg.createPingMsg(&b.fbb, value: i))
            _ = try tx.send(builder: b, timeout: .seconds(1))
            let msg = try rx.recv(timeout: .seconds(1))
            #expect(msg.root()?.value == i)
        }

        tx.disconnect(); rx.disconnect()
        await TypedRoute<PingMsg>.clearStorage(name: "test_tr_multi")
    }
}

// MARK: - TypedChannel tests

@Suite("TypedChannel")
struct TestTypedChannel {

    @Test("round-trip typed message")
    func roundTrip() async throws {
        let tx = try await TypedChannel<PingMsg>.connect(name: "test_tc_rt", mode: .sender)
        let rx = try await TypedChannel<PingMsg>.connect(name: "test_tc_rt", mode: .receiver)

        var b = Builder(initialSize: 64)
        b.finish(PingMsg.createPingMsg(&b.fbb, value: 99))

        _ = try tx.send(builder: b, timeout: .seconds(1))
        let msg = try rx.recv(timeout: .seconds(1))
        #expect(msg.root()?.value == 99)

        tx.disconnect(); rx.disconnect()
        await TypedChannel<PingMsg>.clearStorage(name: "test_tc_rt")
    }

    @Test("verify passes on valid buffer")
    func verifyValid() async throws {
        let tx = try await TypedChannel<PingMsg>.connect(name: "test_tc_verify", mode: .sender)
        let rx = try await TypedChannel<PingMsg>.connect(name: "test_tc_verify", mode: .receiver)

        var b = Builder(initialSize: 64)
        b.finish(PingMsg.createPingMsg(&b.fbb, value: 7))
        _ = try tx.send(builder: b, timeout: .seconds(1))

        let msg = try rx.recv(timeout: .seconds(1))
        #expect(msg.verify() == true)

        tx.disconnect(); rx.disconnect()
        await TypedChannel<PingMsg>.clearStorage(name: "test_tc_verify")
    }

    @Test("empty message verify returns false")
    func verifyEmpty() {
        let msg = Message<PingMsg>.empty()
        #expect(msg.verify() == false)
        #expect(msg.root() == nil)
    }
}
