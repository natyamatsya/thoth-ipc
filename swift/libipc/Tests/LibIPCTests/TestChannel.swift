// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

import Testing
@testable import LibIPC

// MARK: - Route tests

@Suite("Route")
struct TestRoute {

    @Test("sender connects without error")
    func senderConnects() async throws {
        let r = try await Route.connect(name: "test_route_sender", mode: .sender)
        r.disconnect()
        await Route.clearStorage(name: "test_route_sender")
    }

    @Test("receiver connects without error")
    func receiverConnects() async throws {
        let r = try await Route.connect(name: "test_route_recv", mode: .receiver)
        r.disconnect()
        await Route.clearStorage(name: "test_route_recv")
    }

    @Test("recvCount reflects connected receivers")
    func recvCount() async throws {
        let tx = try await Route.connect(name: "test_route_count", mode: .sender)
        #expect(tx.recvCount == 0)
        let rx = try await Route.connect(name: "test_route_count", mode: .receiver)
        #expect(tx.recvCount == 1)
        rx.disconnect()
        #expect(tx.recvCount == 0)
        tx.disconnect()
        await Route.clearStorage(name: "test_route_count")
    }

    @Test("send returns false when no receivers")
    func sendNoReceivers() async throws {
        let tx = try await Route.connect(name: "test_route_norecv", mode: .sender)
        let sent = try tx.send(data: [1, 2, 3])
        #expect(sent == false)
        tx.disconnect()
        await Route.clearStorage(name: "test_route_norecv")
    }

    @Test("single send/recv round-trip")
    func roundTrip() async throws {
        let tx = try await Route.connect(name: "test_route_rt", mode: .sender)
        let rx = try await Route.connect(name: "test_route_rt", mode: .receiver)

        let payload: [UInt8] = [10, 20, 30, 40]
        let sent = try tx.send(data: payload, timeout: .seconds(1))
        #expect(sent == true)

        let buf = try rx.recv(timeout: .seconds(1))
        #expect(buf.bytes == payload)

        tx.disconnect()
        rx.disconnect()
        await Route.clearStorage(name: "test_route_rt")
    }

    @Test("send empty data returns false")
    func sendEmpty() async throws {
        let tx = try await Route.connect(name: "test_route_empty", mode: .sender)
        let rx = try await Route.connect(name: "test_route_empty", mode: .receiver)
        let sent = try tx.send(data: [])
        #expect(sent == false)
        tx.disconnect()
        rx.disconnect()
        await Route.clearStorage(name: "test_route_empty")
    }

    @Test("recv times out when no data")
    func recvTimeout() async throws {
        let rx = try await Route.connect(name: "test_route_recvtimeout", mode: .receiver)
        let buf = try rx.recv(timeout: .milliseconds(50))
        #expect(buf.isEmpty)
        rx.disconnect()
        await Route.clearStorage(name: "test_route_recvtimeout")
    }

    @Test("multiple small messages in sequence")
    func multipleMessages() async throws {
        let tx = try await Route.connect(name: "test_route_multi", mode: .sender)
        let rx = try await Route.connect(name: "test_route_multi", mode: .receiver)

        for i in 0..<5 {
            let payload = [UInt8(i)]
            _ = try tx.send(data: payload, timeout: .seconds(1))
            let buf = try rx.recv(timeout: .seconds(1))
            #expect(buf.bytes == payload)
        }

        tx.disconnect()
        rx.disconnect()
        await Route.clearStorage(name: "test_route_multi")
    }

    @Test("message larger than slot size (large-message path)")
    func largeMessage() async throws {
        let tx = try await Route.connect(name: "test_route_large", mode: .sender)
        let rx = try await Route.connect(name: "test_route_large", mode: .receiver)

        let payload = [UInt8](repeating: 0xAB, count: 512)
        let sent = try tx.send(data: payload, timeout: .seconds(2))
        #expect(sent == true)

        let buf = try rx.recv(timeout: .seconds(2))
        #expect(buf.bytes == payload)

        tx.disconnect()
        rx.disconnect()
        await Route.clearStorage(name: "test_route_large")
    }

    @Test("broadcast to two receivers")
    func broadcastTwoReceivers() async throws {
        let tx  = try await Route.connect(name: "test_route_bcast", mode: .sender)
        let rx1 = try await Route.connect(name: "test_route_bcast", mode: .receiver)
        let rx2 = try await Route.connect(name: "test_route_bcast", mode: .receiver)

        let payload: [UInt8] = [7, 8, 9]
        _ = try tx.send(data: payload, timeout: .seconds(1))

        let b1 = try rx1.recv(timeout: .seconds(1))
        let b2 = try rx2.recv(timeout: .seconds(1))
        #expect(b1.bytes == payload)
        #expect(b2.bytes == payload)

        tx.disconnect(); rx1.disconnect(); rx2.disconnect()
        await Route.clearStorage(name: "test_route_bcast")
    }

    @Test("sender does not receive its own messages")
    func senderDoesNotReceiveOwn() async throws {
        let tx = try await Route.connect(name: "test_route_own", mode: .sender)
        let rx = try await Route.connect(name: "test_route_own", mode: .receiver)

        _ = try tx.send(data: [1, 2, 3], timeout: .seconds(1))
        let buf = try rx.recv(timeout: .seconds(1))
        #expect(buf.bytes == [1, 2, 3])

        tx.disconnect(); rx.disconnect()
        await Route.clearStorage(name: "test_route_own")
    }

    @Test("waitForRecv blocks until receiver connects")
    func waitForRecv() async throws {
        let tx = try await Route.connect(name: "test_route_wfr", mode: .sender)

        let connectTask = Task {
            try await Task.sleep(for: .milliseconds(30))
            return try await Route.connect(name: "test_route_wfr", mode: .receiver)
        }

        let ok = try tx.waitForRecv(count: 1, timeout: .seconds(2))
        #expect(ok == true)

        let rx = try await connectTask.value
        rx.disconnect(); tx.disconnect()
        await Route.clearStorage(name: "test_route_wfr")
    }
}

// MARK: - Channel tests

@Suite("Channel")
struct TestChannel {

    @Test("connect sender and receiver")
    func connectBoth() async throws {
        let tx = try await Channel.connect(name: "test_chan_connect", mode: .sender)
        let rx = try await Channel.connect(name: "test_chan_connect", mode: .receiver)
        tx.disconnect(); rx.disconnect()
        await Channel.clearStorage(name: "test_chan_connect")
    }

    @Test("round-trip small message")
    func roundTrip() async throws {
        let tx = try await Channel.connect(name: "test_chan_rt", mode: .sender)
        let rx = try await Channel.connect(name: "test_chan_rt", mode: .receiver)

        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        _ = try tx.send(data: payload, timeout: .seconds(1))
        let buf = try rx.recv(timeout: .seconds(1))
        #expect(buf.bytes == payload)

        tx.disconnect(); rx.disconnect()
        await Channel.clearStorage(name: "test_chan_rt")
    }

    @Test("concurrent send from two senders")
    func twoSenders() async throws {
        let tx1 = try await Channel.connect(name: "test_chan_2tx", mode: .sender)
        let tx2 = try await Channel.connect(name: "test_chan_2tx", mode: .sender)
        let rx  = try await Channel.connect(name: "test_chan_2tx", mode: .receiver)

        _ = try tx1.send(data: [1], timeout: .seconds(1))
        _ = try tx2.send(data: [2], timeout: .seconds(1))

        var received: [[UInt8]] = []
        for _ in 0..<2 {
            let buf = try rx.recv(timeout: .seconds(1))
            if !buf.isEmpty { received.append(buf.bytes) }
        }
        #expect(received.count == 2)
        #expect(received.contains([1]))
        #expect(received.contains([2]))

        tx1.disconnect(); tx2.disconnect(); rx.disconnect()
        await Channel.clearStorage(name: "test_chan_2tx")
    }

    @Test("tryRecv returns empty when no data")
    func tryRecvEmpty() async throws {
        let rx = try await Channel.connect(name: "test_chan_tryrecv", mode: .receiver)
        let buf = try rx.tryRecv()
        #expect(buf.isEmpty)
        rx.disconnect()
        await Channel.clearStorage(name: "test_chan_tryrecv")
    }
}
