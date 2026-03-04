// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

import Testing
@testable import LibIPC

private struct FakeCapnpMessage: CapnpWireMessage, Equatable {
    let value: UInt32

    init(value: UInt32) {
        self.value = value
    }

    init?(serializedBytes: [UInt8]) {
        if serializedBytes.count != MemoryLayout<UInt32>.size {
            return nil
        }
        let value = UInt32(serializedBytes[0])
            | UInt32(serializedBytes[1]) << 8
            | UInt32(serializedBytes[2]) << 16
            | UInt32(serializedBytes[3]) << 24
        self.init(value: value)
    }

    func serializedBytes() -> [UInt8] {
        let le = value.littleEndian
        return [
            UInt8(truncatingIfNeeded: le),
            UInt8(truncatingIfNeeded: le >> 8),
            UInt8(truncatingIfNeeded: le >> 16),
            UInt8(truncatingIfNeeded: le >> 24),
        ]
    }
}

@Suite("Capnp codec scaffolding")
struct TestCapnpCodec {

    @Test("codec id is capnp")
    func codecId() {
        #expect(CapnpCodec<FakeCapnpMessage>.codecId == .capnp)
    }

    @Test("builder from message serializes bytes")
    func builderFromMessage() {
        let builder = CapnpBuilder(message: FakeCapnpMessage(value: 99))
        #expect(builder.bytes == [99, 0, 0, 0])
    }

    @Test("decode valid buffer returns typed root")
    func decodeValidBuffer() {
        let message = CapnpCodec<FakeCapnpMessage>.decode(buffer: IpcBuffer(bytes: [7, 0, 0, 0]))
        #expect(message.isValid)
        #expect(message.root()?.value == 7)
        #expect(CapnpCodec<FakeCapnpMessage>.verify(message: message))
    }

    @Test("decode invalid buffer fails verification")
    func decodeInvalidBuffer() {
        let message = CapnpCodec<FakeCapnpMessage>.decode(buffer: IpcBuffer(bytes: [1, 2, 3]))
        #expect(!message.isValid)
        #expect(message.root() == nil)
        #expect(!CapnpCodec<FakeCapnpMessage>.verify(message: message))
    }

    @Test("typed route round-trip with capnp codec")
    func typedRouteRoundTrip() async throws {
        let name = "swift_capnp_rt_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await TypedRouteCapnp<FakeCapnpMessage>.clearStorage(name: name) } }

        let sender = try await TypedRouteCapnp<FakeCapnpMessage>.connect(name: name, mode: .sender)
        let receiver = try await TypedRouteCapnp<FakeCapnpMessage>.connect(name: name, mode: .receiver)

        _ = try sender.waitForRecv(count: 1, timeout: .seconds(1))
        _ = try sender.send(builder: CapnpBuilder(message: FakeCapnpMessage(value: 42)), timeout: .seconds(1))

        let message = try receiver.recv(timeout: .seconds(1))
        #expect(message.root()?.value == 42)

        sender.disconnect()
        receiver.disconnect()
    }
}
