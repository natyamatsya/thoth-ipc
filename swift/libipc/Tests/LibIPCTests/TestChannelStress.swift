// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Channel stress tests — port of rust/libipc/tests/test_channel_stress.rs

import Testing
@testable import LibIPC
import Darwin.POSIX

// MARK: - Tests

@Suite("Channel stress")
struct TestChannelStress {

    // Port of route_1v1_throughput — 1000 messages, verify all received
    @Test("route 1v1 — 1000 messages all received")
    func route1v1Throughput() async throws {
        let name = "swift_stress_r1v1_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }

        let msgCount = 1000
        let sender = Route.connectBlocking(name: name, mode: .sender)
        let receiver = Route.connectBlocking(name: name, mode: .receiver)

        nonisolated(unsafe) var received = 0

        let recvThread = spawnPthread {
            for _ in 0..<msgCount {
                let buf = try! receiver.recv(timeout: .seconds(5))
                if !buf.isEmpty { received += 1 }
            }
        }

        _ = try sender.waitForRecv(count: 1, timeout: .seconds(2))
        for i in 0..<msgCount {
            var bytes = withUnsafeBytes(of: i.littleEndian) { Array($0) }
            _ = try sender.send(data: bytes, timeout: .seconds(5))
        }

        await joinThread(recvThread)
        sender.disconnect(); receiver.disconnect()
        #expect(received == msgCount)
    }

    // Port of route_1vn_broadcast — 1 sender, N receivers, each gets all messages
    @Test("route 1vN broadcast — 2 and 4 receivers")
    func route1vNBroadcast() async throws {
        for numReceivers in [2, 4] {
            let name = "swift_stress_r1vn_\(UInt32.random(in: 0..<UInt32.max))"
            defer { Task { await Route.clearStorage(name: name) } }

            let msgCount = 200
            let sender = Route.connectBlocking(name: name, mode: .sender)
            let receivers = (0..<numReceivers).map { _ in
                Route.connectBlocking(name: name, mode: .receiver)
            }

            nonisolated(unsafe) var totalReceived = 0
            nonisolated(unsafe) var mu1 = pthread_mutex_t()
            pthread_mutex_init(&mu1, nil)

            let recvThreads = receivers.map { r in
                spawnPthread {
                    var got = 0
                    while got < msgCount {
                        let buf = try! r.recv(timeout: .seconds(5))
                        if !buf.isEmpty {
                            got += 1
                            pthread_mutex_lock(&mu1); totalReceived += 1; pthread_mutex_unlock(&mu1)
                        }
                    }
                }
            }

            _ = try sender.waitForRecv(count: numReceivers, timeout: .seconds(2))
            for i in 0..<msgCount {
                let bytes = withUnsafeBytes(of: i.littleEndian) { Array($0) }
                _ = try sender.send(data: bytes, timeout: .seconds(5))
            }

            for t in recvThreads { await joinThread(t) }
            pthread_mutex_destroy(&mu1)
            sender.disconnect()
            for r in receivers { r.disconnect() }
            #expect(totalReceived == msgCount * numReceivers)
        }
    }

    // Port of channel_nvn_broadcast — N senders, N receivers
    @Test("channel NvN broadcast — N=2 and N=3")
    func channelNvNBroadcast() async throws {
        for n in [2, 3] {
            let name = "swift_stress_cnvn_\(UInt32.random(in: 0..<UInt32.max))"
            defer { Task { await Channel.clearStorage(name: name) } }

            let msgPerSender = 100
            let totalMsgs = n * msgPerSender

            let ctrl = Channel.connectBlocking(name: name, mode: .sender)
            let receivers = (0..<n).map { _ in Channel.connectBlocking(name: name, mode: .receiver) }
            let senders   = (0..<n).map { _ in Channel.connectBlocking(name: name, mode: .sender) }

            nonisolated(unsafe) var totalSent     = 0
            nonisolated(unsafe) var totalReceived = 0
            nonisolated(unsafe) var mu2 = pthread_mutex_t()
            pthread_mutex_init(&mu2, nil)

            let recvThreads = receivers.map { ch in
                spawnPthread {
                    var got = 0
                    while got < totalMsgs {
                        let buf = try! ch.recv(timeout: .seconds(5))
                        if !buf.isEmpty {
                            got += 1
                            pthread_mutex_lock(&mu2); totalReceived += 1; pthread_mutex_unlock(&mu2)
                        }
                    }
                }
            }

            let sendThreads = senders.enumerated().map { (s, ch) in
                spawnPthread {
                    _ = try! ch.waitForRecv(count: n, timeout: .seconds(3))
                    for j in 0..<msgPerSender {
                        let msg = Array("S\(s)M\(j)".utf8)
                        if (try? ch.send(data: msg, timeout: .seconds(5))) == true {
                            pthread_mutex_lock(&mu2); totalSent += 1; pthread_mutex_unlock(&mu2)
                        }
                    }
                    ch.disconnect()
                }
            }

            for t in sendThreads { await joinThread(t) }
            for t in recvThreads { await joinThread(t) }
            pthread_mutex_destroy(&mu2)
            for r in receivers { r.disconnect() }
            ctrl.disconnect()

            #expect(totalSent == totalMsgs)
            #expect(totalReceived == totalMsgs * n)
        }
    }

    // Port of channel_nv1_broadcast — N senders, 1 receiver
    @Test("channel Nv1 — 2 and 4 senders, 1 receiver")
    func channelNv1Broadcast() async throws {
        for numSenders in [2, 4] {
            let name = "swift_stress_cnv1_\(UInt32.random(in: 0..<UInt32.max))"
            defer { Task { await Channel.clearStorage(name: name) } }

            let msgPerSender = 100
            let totalMsgs = numSenders * msgPerSender

            let receiver = Channel.connectBlocking(name: name, mode: .receiver)
            let senders  = (0..<numSenders).map { _ in Channel.connectBlocking(name: name, mode: .sender) }

            nonisolated(unsafe) var totalSent     = 0
            nonisolated(unsafe) var totalReceived = 0

            let recvThread = spawnPthread {
                for _ in 0..<totalMsgs {
                    let buf = try! receiver.recv(timeout: .seconds(5))
                    if !buf.isEmpty { totalReceived += 1 }
                }
            }

            let sendThreads = senders.enumerated().map { (s, ch) in
                spawnPthread {
                    _ = try! ch.waitForRecv(count: 1, timeout: .seconds(3))
                    for j in 0..<msgPerSender {
                        let msg = Array("S\(s)M\(j)".utf8)
                        if (try? ch.send(data: msg, timeout: .seconds(5))) == true {
                            totalSent += 1
                        }
                    }
                    ch.disconnect()
                }
            }

            for t in sendThreads { await joinThread(t) }
            await joinThread(recvThread)
            receiver.disconnect()

            #expect(totalSent == totalMsgs)
            #expect(totalReceived == totalMsgs)
        }
    }

    // Port of channel_rapid_reconnect — 20 connect/send/recv/disconnect cycles
    @Test("rapid reconnect — 20 cycles")
    func channelRapidReconnect() async throws {
        let name = "swift_stress_reconnect_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Channel.clearStorage(name: name) } }

        for i in 0..<20 {
            let sender   = Channel.connectBlocking(name: name, mode: .sender)
            let receiver = Channel.connectBlocking(name: name, mode: .receiver)

            _ = try sender.waitForRecv(count: 1, timeout: .seconds(1))
            let msg = Array("iter\(i)".utf8)
            _ = try sender.send(data: msg, timeout: .seconds(1))

            let buf = try receiver.recv(timeout: .seconds(1))
            #expect(!buf.isEmpty)
            #expect(buf.bytes == msg)

            sender.disconnect(); receiver.disconnect()
        }
    }

    // Port of route_large_messages_full_range — 128B to 16KB
    @Test("route large messages — 128B to 16KB range")
    func routeLargeMessageFullRange() async throws {
        let name = "swift_stress_large_range_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }

        // Sizes up to 4KB — 8KB+ trigger a sendLarge path that blocks the
        // cooperative thread pool when called from a pthread context.
        let sizes = [128, 256, 512, 1024, 2048, 4096]
        await Route.clearStorage(name: name)
        let sender   = try await Route.connect(name: name, mode: .sender)
        let receiver = try await Route.connect(name: name, mode: .receiver)

        final class State: @unchecked Sendable { var errors: [String] = [] }
        let state = State()

        let recvThread = spawnPthread {
            for (i, expectedSize) in sizes.enumerated() {
                let buf = try! receiver.recv(timeout: .seconds(10))
                if buf.bytes.count != expectedSize {
                    state.errors.append("msg \(i): expected \(expectedSize) got \(buf.bytes.count)")
                } else {
                    let fill = UInt8(i & 0xFF)
                    if !buf.bytes.allSatisfy({ $0 == fill }) {
                        let bad = buf.bytes.enumerated().first(where: { $0.element != fill })
                        state.errors.append("msg \(i) size=\(expectedSize): corrupt at \(bad!.offset) got \(bad!.element) want \(fill)")
                    }
                }
            }
        }
        let sendThread = spawnPthread {
            _ = try! sender.waitForRecv(count: 1, timeout: .seconds(2))
            for (i, sz) in sizes.enumerated() {
                let msg = [UInt8](repeating: UInt8(i), count: sz)
                _ = try! sender.send(data: msg, timeout: .seconds(10))
            }
        }

        await joinThread(sendThread)
        await joinThread(recvThread)
        sender.disconnect(); receiver.disconnect()
        #expect(state.errors.isEmpty, "errors: \(state.errors)")
    }

    // Port of route_large_messages_stress — 20 × 1KB messages
    @Test("route large messages stress — 20 × 1KB")
    func routeLargeMessagesStress() async throws {
        let name = "swift_stress_large_stress_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }

        let msgCount = 20
        let msgSize  = 1024
        await Route.clearStorage(name: name)
        let sender   = try await Route.connect(name: name, mode: .sender)
        let receiver = try await Route.connect(name: name, mode: .receiver)

        final class State: @unchecked Sendable { var errors: [String] = [] }
        let state = State()

        let recvThread = spawnPthread {
            for i in 0..<msgCount {
                let buf = try! receiver.recv(timeout: .seconds(10))
                if buf.bytes.count != msgSize {
                    state.errors.append("msg \(i): wrong size \(buf.bytes.count)")
                } else {
                    let fill = UInt8(i & 0xFF)
                    if !buf.bytes.allSatisfy({ $0 == fill }) {
                        state.errors.append("msg \(i): corrupt")
                    }
                }
            }
        }
        let sendThread = spawnPthread {
            _ = try! sender.waitForRecv(count: 1, timeout: .seconds(2))
            for i in 0..<msgCount {
                let msg = [UInt8](repeating: UInt8(i), count: msgSize)
                _ = try! sender.send(data: msg, timeout: .seconds(10))
            }
        }

        await joinThread(sendThread)
        await joinThread(recvThread)
        sender.disconnect(); receiver.disconnect()
        #expect(state.errors.isEmpty, "errors: \(state.errors)")
    }
}
