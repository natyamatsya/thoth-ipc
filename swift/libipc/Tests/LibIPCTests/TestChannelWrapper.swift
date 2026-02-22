// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Channel wrapper API tests — port of rust/libipc/tests/test_chan_wrapper.rs

import Testing
@testable import LibIPC
import Darwin.POSIX

// MARK: - valid / disconnect

@Suite("Channel wrapper — valid and disconnect")
struct TestChannelWrapperValid {

    // Port of route_valid_after_connect
    @Test("route is valid after connect")
    func routeValidAfterConnect() async throws {
        let name = "swift_cw_rv_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        let r = try await Route.connect(name: name, mode: .sender)
        #expect(r.valid)
        r.disconnect()
    }

    // Port of route_valid_false_after_disconnect
    @Test("route is invalid after disconnect")
    func routeInvalidAfterDisconnect() async throws {
        let name = "swift_cw_rvd_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        let r = try await Route.connect(name: name, mode: .sender)
        #expect(r.valid)
        r.disconnect()
        #expect(!r.valid)
    }

    // Port of channel_valid_after_connect
    @Test("channel is valid after connect")
    func channelValidAfterConnect() async throws {
        let name = "swift_cw_cv_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Channel.clearStorage(name: name) } }
        let c = try await Channel.connect(name: name, mode: .sender)
        #expect(c.valid)
        c.disconnect()
    }

    // Port of channel_valid_false_after_disconnect
    @Test("channel is invalid after disconnect")
    func channelInvalidAfterDisconnect() async throws {
        let name = "swift_cw_cvd_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Channel.clearStorage(name: name) } }
        let c = try await Channel.connect(name: name, mode: .sender)
        #expect(c.valid)
        c.disconnect()
        #expect(!c.valid)
    }

    // Port of route_disconnect_receiver_frees_conn_bit
    @Test("route disconnect receiver frees connection bit")
    func routeDisconnectReceiverFreesConnBit() async throws {
        let name = "swift_cw_rdfcb_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        let r = try await Route.connect(name: name, mode: .receiver)
        #expect(r.recvCount == 1)
        r.disconnect()
        #expect(!r.valid)
        // After disconnect the bit is freed — a new receiver can connect
        let r2 = try await Route.connect(name: name, mode: .receiver)
        #expect(r2.recvCount == 1)
        r2.disconnect()
    }

    // Port of route_disconnect_idempotent
    @Test("route disconnect is idempotent")
    func routeDisconnectIdempotent() async throws {
        let name = "swift_cw_rdi_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        let r = try await Route.connect(name: name, mode: .sender)
        r.disconnect()
        r.disconnect()   // second call must not crash
        #expect(!r.valid)
    }

    // Port of channel_disconnect_receiver_frees_conn_bit
    @Test("channel disconnect receiver frees connection bit")
    func channelDisconnectReceiverFreesConnBit() async throws {
        let name = "swift_cw_cdfcb_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Channel.clearStorage(name: name) } }
        let r = try await Channel.connect(name: name, mode: .receiver)
        #expect(r.recvCount == 1)
        r.disconnect()
        #expect(!r.valid)
        let r2 = try await Channel.connect(name: name, mode: .receiver)
        #expect(r2.recvCount == 1)
        r2.disconnect()
    }
}

// MARK: - mode

@Suite("Channel wrapper — mode")
struct TestChannelWrapperMode {

    // Port of route_valid_after_connect (mode variant)
    @Test("route mode is sender after sender connect")
    func routeModeSender() async throws {
        let name = "swift_cw_rms_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        let r = try await Route.connect(name: name, mode: .sender)
        #expect(r.mode == .sender)
        r.disconnect()
    }

    @Test("route mode is receiver after receiver connect")
    func routeModeReceiver() async throws {
        let name = "swift_cw_rmr_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        let r = try await Route.connect(name: name, mode: .receiver)
        #expect(r.mode == .receiver)
        r.disconnect()
    }

    @Test("channel mode is sender after sender connect")
    func channelModeSender() async throws {
        let name = "swift_cw_cms_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Channel.clearStorage(name: name) } }
        let c = try await Channel.connect(name: name, mode: .sender)
        #expect(c.mode == .sender)
        c.disconnect()
    }

    @Test("channel mode is receiver after receiver connect")
    func channelModeReceiver() async throws {
        let name = "swift_cw_cmr_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Channel.clearStorage(name: name) } }
        let c = try await Channel.connect(name: name, mode: .receiver)
        #expect(c.mode == .receiver)
        c.disconnect()
    }
}

// MARK: - waitForRecv (instance)

@Suite("Channel wrapper — waitForRecv")
struct TestChannelWrapperWaitForRecv {

    // Port of route_wait_for_recv_on_sees_existing_receiver
    @Test("route waitForRecv returns true when receiver already connected")
    func routeWaitForRecvSeesExisting() async throws {
        let name = "swift_cw_rwfr_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        let s = try await Route.connect(name: name, mode: .sender)
        let r = try await Route.connect(name: name, mode: .receiver)
        let ok = try s.waitForRecv(count: 1, timeout: .milliseconds(500))
        #expect(ok)
        r.disconnect(); s.disconnect()
    }

    // Port of route_wait_for_recv_on_times_out_with_no_receiver
    @Test("route waitForRecv times out with no receiver")
    func routeWaitForRecvTimesOut() async throws {
        let name = "swift_cw_rwfr_to_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        let s = try await Route.connect(name: name, mode: .sender)
        let ok = try s.waitForRecv(count: 1, timeout: .milliseconds(50))
        #expect(!ok)
        s.disconnect()
    }

    // Port of channel_wait_for_recv_on_sees_existing_receiver
    @Test("channel waitForRecv returns true when receiver already connected")
    func channelWaitForRecvSeesExisting() async throws {
        let name = "swift_cw_cwfr_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Channel.clearStorage(name: name) } }
        let s = try await Channel.connect(name: name, mode: .sender)
        let r = try await Channel.connect(name: name, mode: .receiver)
        let ok = try s.waitForRecv(count: 1, timeout: .milliseconds(500))
        #expect(ok)
        r.disconnect(); s.disconnect()
    }

    @Test("channel waitForRecv times out when no receiver")
    func channelWaitForRecvTimesOut() async throws {
        let name = "swift_cw_cwfr_to_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Channel.clearStorage(name: name) } }
        let s = try await Channel.connect(name: name, mode: .sender)
        let ok = try s.waitForRecv(count: 1, timeout: .milliseconds(50))
        #expect(!ok)
        s.disconnect()
    }

    // Port of route_reconnect_then_send_recv — waitForRecv then send/recv
    @Test("route waitForRecv then send/recv")
    func routeWaitForRecvThenSendRecv() async throws {
        let name = "swift_cw_rwfr_sr_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        let s = try await Route.connect(name: name, mode: .sender)
        let r = try await Route.connect(name: name, mode: .receiver)
        _ = try s.waitForRecv(count: 1, timeout: .seconds(1))
        _ = try s.send(data: Array("hello".utf8), timeout: .seconds(2))
        let buf = try r.recv(timeout: .seconds(2))
        #expect(buf.bytes == Array("hello".utf8))
        s.disconnect(); r.disconnect()
    }
}

// MARK: - clear

@Suite("Channel wrapper — clear")
struct TestChannelWrapperClear {

    // Port of route_clear_disconnects_and_removes_storage
    @Test("route clear disconnects and removes storage")
    func routeClearDisconnectsAndRemovesStorage() async throws {
        let name = "swift_cw_rclr_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        let r = try await Route.connect(name: name, mode: .receiver)
        #expect(r.recvCount == 1)
        await r.clear()
        #expect(!r.valid)
        // After clear, a fresh connect should see 0 receivers (SHM was removed)
        let r2 = try await Route.connect(name: name, mode: .receiver)
        #expect(r2.recvCount == 1)
        r2.disconnect()
    }

    // Port of channel_clear_disconnects_and_removes_storage
    @Test("channel clear disconnects and removes storage")
    func channelClearDisconnectsAndRemovesStorage() async throws {
        let name = "swift_cw_cclr_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Channel.clearStorage(name: name) } }
        let c = try await Channel.connect(name: name, mode: .receiver)
        #expect(c.recvCount == 1)
        await c.clear()
        #expect(!c.valid)
        let c2 = try await Channel.connect(name: name, mode: .receiver)
        #expect(c2.recvCount == 1)
        c2.disconnect()
    }
}

// MARK: - recvCount across multiple connections

@Suite("Channel wrapper — recvCount")
struct TestChannelWrapperRecvCount {

    @Test("route recvCount increments and decrements correctly")
    func routeRecvCountIncrDecr() async throws {
        let name = "swift_cw_rrc_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Route.clearStorage(name: name) } }
        let s  = try await Route.connect(name: name, mode: .sender)
        #expect(s.recvCount == 0)
        let r1 = try await Route.connect(name: name, mode: .receiver)
        #expect(s.recvCount == 1)
        let r2 = try await Route.connect(name: name, mode: .receiver)
        #expect(s.recvCount == 2)
        r1.disconnect()
        #expect(s.recvCount == 1)
        r2.disconnect()
        #expect(s.recvCount == 0)
        s.disconnect()
    }

    @Test("channel recvCount increments and decrements correctly")
    func channelRecvCountIncrDecr() async throws {
        let name = "swift_cw_crc_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await Channel.clearStorage(name: name) } }
        let s  = try await Channel.connect(name: name, mode: .sender)
        #expect(s.recvCount == 0)
        let r1 = try await Channel.connect(name: name, mode: .receiver)
        #expect(s.recvCount == 1)
        let r2 = try await Channel.connect(name: name, mode: .receiver)
        #expect(s.recvCount == 2)
        r1.disconnect()
        #expect(s.recvCount == 1)
        r2.disconnect()
        #expect(s.recvCount == 0)
        s.disconnect()
    }
}
