// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Deeper typed proto tests — port of rust/libipc/tests/test_proto_typed.rs
//
// Uses the same PingMsg table defined in TestTypedChannel.swift.
// Raw-byte helpers mirror make_raw_payload / read_raw_payload from the Rust tests.

import Testing
import FlatBuffers
import Darwin.POSIX
@testable import LibIPC

// MARK: - Raw payload helpers (mirror Rust make_raw_payload / read_raw_payload)

/// Minimal 8-byte FlatBuffer: 4-byte LE root offset (=4) + 4-byte LE tag value.
private func makeRawPayload(_ tag: UInt32) -> [UInt8] {
    var v = [UInt8](repeating: 0, count: 8)
    let off = UInt32(4).littleEndian
    withUnsafeBytes(of: off)  { v[0..<4] = ArraySlice($0) }
    let val = tag.littleEndian
    withUnsafeBytes(of: val)  { v[4..<8] = ArraySlice($0) }
    return v
}

private func readRawPayload(_ data: [UInt8]) -> UInt32 {
    precondition(data.count >= 8)
    return UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24
}

// MARK: - Message tests

@Suite("Message depth")
struct TestMessageDepth {

    // Port of message_empty
    @Test("empty message is empty with zero size")
    func messageEmpty() {
        let msg = Message<PingMsg>.empty()
        #expect(msg.isEmpty)
        #expect(msg.count == 0)
    }

    // Port of message_from_buffer
    @Test("message from IpcBuffer wraps bytes correctly")
    func messageFromBuffer() {
        let payload = makeRawPayload(42)
        let buf = IpcBuffer(bytes: payload)
        let msg = Message<PingMsg>(buffer: buf)
        #expect(!msg.isEmpty)
        #expect(msg.count == 8)
        #expect(readRawPayload(msg.buffer.bytes) == 42)
    }

    // Port of message_data_roundtrip
    @Test("message bytes round-trip through IpcBuffer")
    func messageDataRoundtrip() {
        let payload = Array("hello flatbuffers".utf8)
        let buf = IpcBuffer(bytes: payload)
        let msg = Message<PingMsg>(buffer: buf)
        #expect(msg.buffer.bytes == payload)
    }
}

// MARK: - Builder tests

@Suite("Builder depth")
struct TestBuilderDepth {

    // Port of builder_default_empty
    @Test("default Builder constructs without crash")
    func builderDefault() {
        let _ = Builder()
    }

    // Port of builder_new_empty
    @Test("Builder with initial size constructs without crash")
    func builderNew() {
        let _ = Builder(initialSize: 256)
    }

    // Port of builder_clear_resets
    @Test("Builder clear resets bytes to empty")
    func builderClear() {
        var b = Builder(initialSize: 64)
        b.finish(PingMsg.createPingMsg(&b.fbb, value: 99))
        #expect(b.bytes.count > 0)
        b.clear()
        #expect(b.bytes.isEmpty)
    }

    // Port of builder_finish_with_id
    @Test("Builder finish with file identifier produces non-empty bytes")
    func builderFinishWithId() {
        var b = Builder(initialSize: 64)
        let off = PingMsg.createPingMsg(&b.fbb, value: 7)
        b.finish(off, fileId: "TEST")
        #expect(b.bytes.count > 0)
    }
}

// MARK: - TypedRoute depth tests

@Suite("TypedRoute depth")
struct TestTypedRouteDepth {

    // Port of typed_route_connect_sender
    @Test("connect sender succeeds")
    func connectSender() async throws {
        let name = "swift_trd_snd_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await TypedRoute<PingMsg>.clearStorage(name: name) } }
        let rt = try await TypedRoute<PingMsg>.connect(name: name, mode: .sender)
        rt.disconnect()
    }

    // Port of typed_route_connect_receiver
    @Test("connect receiver succeeds")
    func connectReceiver() async throws {
        let name = "swift_trd_rcv_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await TypedRoute<PingMsg>.clearStorage(name: name) } }
        let rt = try await TypedRoute<PingMsg>.connect(name: name, mode: .receiver)
        rt.disconnect()
    }

    // Port of typed_route_send_raw_bytes
    @Test("send raw bytes round-trip via TypedRoute")
    func sendRawBytes() async throws {
        let name = "swift_trd_raw_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await TypedRoute<PingMsg>.clearStorage(name: name) } }
        let sender   = try await TypedRoute<PingMsg>.connect(name: name, mode: .sender)
        let receiver = try await TypedRoute<PingMsg>.connect(name: name, mode: .receiver)

        let payload = makeRawPayload(77)
        let sendThread = spawnPthread {
            _ = try! sender.waitForRecv(count: 1, timeout: .seconds(1))
            _ = try! sender.send(data: payload, timeout: .seconds(2))
        }
        let msg = try receiver.recv(timeout: .seconds(3))
        await joinThread(sendThread)

        #expect(!msg.isEmpty)
        #expect(readRawPayload(msg.buffer.bytes) == 77)
        sender.disconnect(); receiver.disconnect()
    }

    // Port of typed_route_send_builder_bytes
    @Test("send Builder bytes round-trip via TypedRoute")
    func sendBuilderBytes() async throws {
        let name = "swift_trd_bldr_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await TypedRoute<PingMsg>.clearStorage(name: name) } }
        let sender   = try await TypedRoute<PingMsg>.connect(name: name, mode: .sender)
        let receiver = try await TypedRoute<PingMsg>.connect(name: name, mode: .receiver)

        let sendThread = spawnPthread {
            _ = try! sender.waitForRecv(count: 1, timeout: .seconds(1))
            var b = Builder(initialSize: 64)
            b.finish(PingMsg.createPingMsg(&b.fbb, value: 55))
            _ = try! sender.send(builder: b, timeout: .seconds(2))
        }
        let msg = try receiver.recv(timeout: .seconds(3))
        await joinThread(sendThread)

        #expect(!msg.isEmpty)
        #expect(msg.root()?.value == 55)
        sender.disconnect(); receiver.disconnect()
    }

    // Port of typed_route_clear_storage
    @Test("clearStorage does not crash")
    func clearStorage() async {
        let name = "swift_trd_clr_\(UInt32.random(in: 0..<UInt32.max))"
        await TypedRoute<PingMsg>.clearStorage(name: name)
    }
}

// MARK: - TypedChannel depth tests

@Suite("TypedChannel depth")
struct TestTypedChannelDepth {

    // Port of typed_channel_connect_sender
    @Test("connect sender succeeds")
    func connectSender() async throws {
        let name = "swift_tcd_snd_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await TypedChannel<PingMsg>.clearStorage(name: name) } }
        let ch = try await TypedChannel<PingMsg>.connect(name: name, mode: .sender)
        ch.disconnect()
    }

    // Port of typed_channel_connect_receiver
    @Test("connect receiver succeeds")
    func connectReceiver() async throws {
        let name = "swift_tcd_rcv_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await TypedChannel<PingMsg>.clearStorage(name: name) } }
        let ch = try await TypedChannel<PingMsg>.connect(name: name, mode: .receiver)
        ch.disconnect()
    }

    // Port of typed_channel_send_raw_bytes
    @Test("send raw bytes round-trip via TypedChannel")
    func sendRawBytes() async throws {
        let name = "swift_tcd_raw_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await TypedChannel<PingMsg>.clearStorage(name: name) } }
        let sender   = try await TypedChannel<PingMsg>.connect(name: name, mode: .sender)
        let receiver = try await TypedChannel<PingMsg>.connect(name: name, mode: .receiver)

        let payload = makeRawPayload(99)
        let sendThread = spawnPthread {
            _ = try! sender.waitForRecv(count: 1, timeout: .seconds(1))
            _ = try! sender.send(data: payload, timeout: .seconds(2))
        }
        let msg = try receiver.recv(timeout: .seconds(3))
        await joinThread(sendThread)

        #expect(!msg.isEmpty)
        #expect(readRawPayload(msg.buffer.bytes) == 99)
        sender.disconnect(); receiver.disconnect()
    }

    // Port of typed_channel_multiple_receivers — 3 receivers all get the broadcast
    @Test("broadcast to 3 receivers — all receive the message")
    func multipleReceivers() async throws {
        let name = "swift_tcd_multi_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await TypedChannel<PingMsg>.clearStorage(name: name) } }

        let nReceivers = 3
        let receivers = try await (0..<nReceivers).asyncMap { _ in
            try await TypedChannel<PingMsg>.connect(name: name, mode: .receiver)
        }

        final class State: @unchecked Sendable { var results: [UInt32] = []; var mu = pthread_mutex_t(); init() { pthread_mutex_init(&mu, nil) }; deinit { pthread_mutex_destroy(&mu) } }
        let state = State()

        let recvThreads = receivers.map { ch in
            spawnPthread {
                let msg = try! ch.recv(timeout: .seconds(3))
                let val = readRawPayload(msg.buffer.bytes)
                pthread_mutex_lock(&state.mu); state.results.append(val); pthread_mutex_unlock(&state.mu)
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        let sender = try await TypedChannel<PingMsg>.connect(name: name, mode: .sender)
        let payload = makeRawPayload(33)
        let sendThread = spawnPthread {
            _ = try! sender.waitForRecv(count: nReceivers, timeout: .seconds(1))
            _ = try! sender.send(data: payload, timeout: .seconds(2))
        }

        await joinThread(sendThread)
        for t in recvThreads { await joinThread(t) }
        for r in receivers { r.disconnect() }
        sender.disconnect()

        #expect(state.results.count == nReceivers)
        #expect(state.results.allSatisfy { $0 == 33 })
    }

    // Port of typed_channel_clear_storage
    @Test("clearStorage does not crash")
    func clearStorage() async {
        let name = "swift_tcd_clr_\(UInt32.random(in: 0..<UInt32.max))"
        await TypedChannel<PingMsg>.clearStorage(name: name)
    }
}

// MARK: - async map helper (local to this file)

private extension Range<Int> {
    func asyncMap<T>(_ transform: (Int) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for i in self { try await results.append(transform(i)) }
        return results
    }
}
