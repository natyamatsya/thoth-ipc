// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

import Testing
import SwiftProtobuf
import LibIPC
@testable import LibIPCProtobuf

extension Google_Protobuf_StringValue: ProtobufWireMessage {}

@Suite("SwiftProtobuf runtime adapter")
struct TestSwiftProtobufCodec {

    @Test("codec id is protobuf")
    func codecId() {
        #expect(SwiftProtobufCodec<Google_Protobuf_StringValue>.codecId == .protobuf)
    }

    @Test("encode/decode round-trip")
    func encodeDecode() {
        var value = Google_Protobuf_StringValue()
        value.value = "hello-swift-protobuf"

        let bytes = SwiftProtobufCodec<Google_Protobuf_StringValue>.encode(builder: value)
        let decoded = SwiftProtobufCodec<Google_Protobuf_StringValue>.decode(buffer: IpcBuffer(bytes: bytes))

        #expect(decoded.isValid)
        #expect(decoded.root()?.value == value.value)
    }

    @Test("typed route round-trip")
    func typedRouteRoundTrip() async throws {
        let name = "swift_spb_route_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await TypedRouteSwiftProtobuf<Google_Protobuf_StringValue>.clearStorage(name: name) } }

        let sender = try await TypedRouteSwiftProtobuf<Google_Protobuf_StringValue>.connect(name: name, mode: .sender)
        let receiver = try await TypedRouteSwiftProtobuf<Google_Protobuf_StringValue>.connect(name: name, mode: .receiver)

        var outgoing = Google_Protobuf_StringValue()
        outgoing.value = "route-payload"

        _ = try sender.waitForRecv(count: 1, timeout: .seconds(1))
        _ = try sender.send(builder: outgoing, timeout: .seconds(1))

        let message = try receiver.recv(timeout: .seconds(1))
        #expect(message.isValid)
        #expect(message.root()?.value == outgoing.value)

        sender.disconnect()
        receiver.disconnect()
    }
}
