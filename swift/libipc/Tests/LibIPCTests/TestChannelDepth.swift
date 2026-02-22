// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Deeper Route/Channel tests — port of rust/libipc/tests/test_channel.rs (missing cases)

import Testing
@testable import LibIPC
import Darwin.POSIX

@Suite("Route depth")
struct TestRouteDepth {

    // Port of RouteTest.ConstructionWithPrefix
    @Test("connect with prefix — name matches")
    func connectWithPrefix() async throws {
        let name = "swift_rd_pfx_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(prefix: "my_prefix", name: name) } }
        let r = try await Route.connect(prefix: "my_prefix", name: name, mode: .sender)
        #expect(r.name == name)
        r.disconnect()
    }

    // Port of RouteTest.ClearStorageWithPrefix
    @Test("clearStorage with prefix does not crash")
    func clearStorageWithPrefix() async throws {
        let name = "swift_rd_clrpfx_\(UInt32.random(in: 0..<UInt32.max))"
        await Route.clearStorage(prefix: "test", name: name)
        let r = try await Route.connect(prefix: "test", name: name, mode: .sender)
        r.disconnect()
        await Route.clearStorage(prefix: "test", name: name)
    }

    // Port of RouteTest.TrySendWithoutReceiver
    @Test("trySend returns false when no receivers")
    func trySendNoReceiver() async throws {
        let name = "swift_rd_trysnd_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        let r = try await Route.connect(name: name, mode: .sender)
        let sent = try r.trySend(data: Array("test".utf8))
        #expect(!sent)
        r.disconnect()
    }

    // Port of RouteTest.SendReceiveString — send(string:) round-trip
    @Test("send(string:) round-trip")
    func sendReceiveString() async throws {
        let name = "swift_rd_str_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        let sender   = try await Route.connect(name: name, mode: .sender)
        let receiver = try await Route.connect(name: name, mode: .receiver)

        let sendThread = spawnPthread {
            _ = try! sender.waitForRecv(count: 1, timeout: .seconds(1))
            _ = try! sender.send(string: "Test String", timeout: .seconds(2))
        }
        let buf = try receiver.recv(timeout: .seconds(2))
        await joinThread(sendThread)
        // send(string:) null-terminates — check prefix
        #expect(Array(buf.bytes.prefix(11)) == Array("Test String".utf8))
        sender.disconnect(); receiver.disconnect()
    }

    // Port of RouteTest.SendReceiveRawData
    @Test("send(data:) raw bytes round-trip")
    func sendReceiveRaw() async throws {
        let name = "swift_rd_raw_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        let sender   = try await Route.connect(name: name, mode: .sender)
        let receiver = try await Route.connect(name: name, mode: .receiver)

        let payload = Array("Raw Data Test".utf8)
        let sendThread = spawnPthread {
            _ = try! sender.waitForRecv(count: 1, timeout: .seconds(1))
            _ = try! sender.send(data: payload, timeout: .seconds(2))
        }
        let buf = try receiver.recv(timeout: .seconds(2))
        await joinThread(sendThread)
        #expect(buf.bytes == payload)
        sender.disconnect(); receiver.disconnect()
    }

    // Port of RouteTest.WaitForRecv — receiver connects after sender starts waiting
    @Test("waitForRecv unblocked by late receiver")
    func waitForRecvLateReceiver() async throws {
        let name = "swift_rd_wfr_late_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        let sender = try await Route.connect(name: name, mode: .sender)

        // Connect receiver after a short delay in a separate task
        let recvTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let r = try! await Route.connect(name: name, mode: .receiver)
            try? await Task.sleep(nanoseconds: 200_000_000)
            r.disconnect()
        }

        let waited = try sender.waitForRecv(count: 1, timeout: .seconds(1))
        #expect(waited)
        recvTask.cancel()
        sender.disconnect()
    }

    // Port of RouteTest.LargeMessage — 200-byte message (multi-slot)
    @Test("large message — 200 bytes round-trip")
    func largeMessage() async throws {
        let name = "swift_rd_large_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        await Route.clearStorage(name: name)
        let sender   = try await Route.connect(name: name, mode: .sender)
        let receiver = try await Route.connect(name: name, mode: .receiver)

        let payload = (0..<200).map { UInt8($0 % 256) }
        let sendThread = spawnPthread {
            _ = try! sender.waitForRecv(count: 1, timeout: .seconds(1))
            _ = try! sender.send(data: payload, timeout: .seconds(2))
        }
        let buf = try receiver.recv(timeout: .seconds(2))
        await joinThread(sendThread)
        #expect(buf.bytes == payload)
        sender.disconnect(); receiver.disconnect()
    }

    // Port of RouteTest.MultipleMessages — 10 sequential messages
    @Test("10 sequential messages with content verification")
    func multipleMessages() async throws {
        let name = "swift_rd_multi_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        let sender   = try await Route.connect(name: name, mode: .sender)
        let receiver = try await Route.connect(name: name, mode: .receiver)

        let count = 10
        final class State: @unchecked Sendable { var received: [[UInt8]] = [] }
        let state = State()

        let recvThread = spawnPthread {
            for _ in 0..<count {
                let buf = try! receiver.recv(timeout: .seconds(2))
                state.received.append(buf.bytes)
            }
        }
        let sendThread = spawnPthread {
            _ = try! sender.waitForRecv(count: 1, timeout: .seconds(1))
            for i in 0..<count {
                _ = try! sender.send(data: Array("msg_\(i)".utf8), timeout: .seconds(2))
                var ts = timespec(tv_sec: 0, tv_nsec: 5_000_000); nanosleep(&ts, nil)
            }
        }

        await joinThread(sendThread)
        await joinThread(recvThread)
        sender.disconnect(); receiver.disconnect()

        #expect(state.received.count == count)
        for (i, bytes) in state.received.enumerated() {
            #expect(bytes == Array("msg_\(i)".utf8), "message \(i) mismatch")
        }
    }

    // Port of RouteTest.BufferSendRecv — send(buffer:) round-trip
    @Test("send(buffer:) round-trip")
    func bufferSendRecv() async throws {
        let name = "swift_rd_buf_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        let sender   = try await Route.connect(name: name, mode: .sender)
        let receiver = try await Route.connect(name: name, mode: .receiver)

        let payload = Array("Buffer Test".utf8)
        let buf = IpcBuffer(bytes: payload)
        let sendThread = spawnPthread {
            _ = try! sender.waitForRecv(count: 1, timeout: .seconds(1))
            _ = try! sender.send(buffer: buf, timeout: .seconds(2))
        }
        let recvBuf = try receiver.recv(timeout: .seconds(2))
        await joinThread(sendThread)
        #expect(recvBuf.bytes == payload)
        sender.disconnect(); receiver.disconnect()
    }
}

@Suite("Channel depth")
struct TestChannelDepth {

    // Port of ChannelTest.ClearStorage
    @Test("clearStorage does not crash")
    func clearStorage() async throws {
        let name = "swift_cd_clr_\(UInt32.random(in: 0..<UInt32.max))"
        await Channel.clearStorage(name: name)
        let ch = try await Channel.connect(name: name, mode: .sender)
        ch.disconnect()
        await Channel.clearStorage(name: name)
    }

    // Port of ChannelTest.SendReceive — send(string:) round-trip
    @Test("send(string:) round-trip")
    func sendReceiveString() async throws {
        let name = "swift_cd_str_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Channel.clearStorage(name: name) } }
        let sender   = try await Channel.connect(name: name, mode: .sender)
        let receiver = try await Channel.connect(name: name, mode: .receiver)

        let sendThread = spawnPthread {
            _ = try! sender.waitForRecv(count: 1, timeout: .seconds(1))
            _ = try! sender.send(string: "Channel Test", timeout: .seconds(2))
        }
        let buf = try receiver.recv(timeout: .seconds(2))
        await joinThread(sendThread)
        #expect(Array(buf.bytes.prefix(12)) == Array("Channel Test".utf8))
        sender.disconnect(); receiver.disconnect()
    }

    // Port of ChannelTest.MultipleSenders — 3 senders, 1 receiver gets all 3
    @Test("multiple senders — 3 senders, receiver gets all 3 messages")
    func multipleSenders() async throws {
        let name = "swift_cd_msnd_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Channel.clearStorage(name: name) } }
        let numSenders = 3
        let receiver = try await Channel.connect(name: name, mode: .receiver)

        final class State: @unchecked Sendable {
            var receivedCount = 0
            var mu = pthread_mutex_t()
            init() { pthread_mutex_init(&mu, nil) }
            deinit { pthread_mutex_destroy(&mu) }
        }
        let state = State()

        let recvThread = spawnPthread {
            for _ in 0..<numSenders {
                let buf = try! receiver.recv(timeout: .seconds(2))
                if !buf.isEmpty {
                    pthread_mutex_lock(&state.mu); state.receivedCount += 1; pthread_mutex_unlock(&state.mu)
                }
            }
        }

        // Small delay so receiver is ready
        try? await Task.sleep(nanoseconds: 50_000_000)

        var sendThreads: [pthread_t] = []
        for i in 0..<numSenders {
            let ch = try await Channel.connect(name: name, mode: .sender)
            sendThreads.append(spawnPthread {
                _ = try! ch.waitForRecv(count: 1, timeout: .seconds(1))
                _ = try! ch.send(data: Array("Sender\(i)".utf8), timeout: .seconds(2))
                ch.disconnect()
            })
        }

        for t in sendThreads { await joinThread(t) }
        await joinThread(recvThread)
        receiver.disconnect()
        #expect(state.receivedCount == numSenders)
    }

    // Port of ChannelTest.TrySendTryRecv
    @Test("trySend/tryRecv round-trip")
    func trySendTryRecv() async throws {
        let name = "swift_cd_try_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Channel.clearStorage(name: name) } }
        let sender   = try await Channel.connect(name: name, mode: .sender)
        let receiver = try await Channel.connect(name: name, mode: .receiver)

        let sent = try sender.send(data: Array("Try Test".utf8), timeout: .milliseconds(100))
        if sent {
            try? await Task.sleep(nanoseconds: 10_000_000)
            let buf = try receiver.tryRecv()
            #expect(!buf.isEmpty)
            #expect(buf.bytes == Array("Try Test".utf8))
        }
        sender.disconnect(); receiver.disconnect()
    }

    // Port of ChannelTest.SendTimeout — send with no receiver times out immediately
    @Test("send with no receiver and zero timeout returns false")
    func sendTimeout() async throws {
        let name = "swift_cd_timeout_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Channel.clearStorage(name: name) } }
        let ch = try await Channel.connect(name: name, mode: .sender)
        let sent = try ch.send(data: Array("Timeout Test".utf8), timeout: .milliseconds(1))
        #expect(!sent)
        ch.disconnect()
    }

    // Port of ChannelTest.MultipleSendersReceivers — 2 senders × 3 msgs, 2 receivers each get all 6
    @Test("multiple senders and receivers — 2×3 msgs, 2 receivers each get all 6")
    func multipleSendersReceivers() async throws {
        let name = "swift_cd_msndrec_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Channel.clearStorage(name: name) } }

        let numSenders   = 2
        let numReceivers = 2
        let msgsPerSender = 3
        let totalMsgs = numSenders * msgsPerSender

        let receivers = try await (0..<numReceivers).asyncMap { _ in
            try await Channel.connect(name: name, mode: .receiver)
        }

        final class State: @unchecked Sendable {
            var receivedCount = 0
            var mu = pthread_mutex_t()
            init() { pthread_mutex_init(&mu, nil) }
            deinit { pthread_mutex_destroy(&mu) }
        }
        let state = State()

        let recvThreads = receivers.map { ch in
            spawnPthread {
                var got = 0
                while got < totalMsgs {
                    let buf = try! ch.recv(timeout: .seconds(3))
                    if !buf.isEmpty {
                        got += 1
                        pthread_mutex_lock(&state.mu); state.receivedCount += 1; pthread_mutex_unlock(&state.mu)
                    }
                }
            }
        }

        // Small delay so receivers are ready
        try? await Task.sleep(nanoseconds: 200_000_000)

        var sendThreads: [pthread_t] = []
        for i in 0..<numSenders {
            let ch = try await Channel.connect(name: name, mode: .sender)
            sendThreads.append(spawnPthread {
                _ = try! ch.waitForRecv(count: numReceivers, timeout: .seconds(2))
                for j in 0..<msgsPerSender {
                    _ = try! ch.send(data: Array("S\(i)M\(j)".utf8), timeout: .seconds(2))
                    var ts = timespec(tv_sec: 0, tv_nsec: 20_000_000); nanosleep(&ts, nil)
                }
                ch.disconnect()
            })
        }

        for t in sendThreads { await joinThread(t) }
        for t in recvThreads { await joinThread(t) }
        for r in receivers { r.disconnect() }

        #expect(state.receivedCount == totalMsgs * numReceivers)
    }
}

// MARK: - async map helper

private extension RandomAccessCollection {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)
        for element in self { try await results.append(transform(element)) }
        return results
    }
}
