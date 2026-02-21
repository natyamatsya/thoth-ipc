// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of demo/send_recv/main.cpp and Rust demo_send_recv.
//
// Usage:
//   demo-send-recv send <size> <interval_ms>
//   demo-send-recv recv <interval_ms>
//
// Two processes share a channel named "ipc".
// The sender fills a buffer of <size> bytes with 'A' and sends it every
// <interval_ms> milliseconds.  The receiver polls with a <interval_ms>
// timeout and prints the received size.

import LibIPC
import Darwin.POSIX

// MARK: - Signal handling

nonisolated(unsafe) private var gQuit: Bool = false

private func installSignalHandlers() {
    signal(SIGINT)  { _ in gQuit = true }
    signal(SIGTERM) { _ in gQuit = true }
    signal(SIGHUP)  { _ in gQuit = true }
}

// MARK: - Sender

private func doSend(size: Int, intervalMs: UInt64) async {
    do {
        let ch = try await Channel.connect(name: "ipc", mode: .sender)
        print("send: waiting for receiver...")
        _ = try ch.waitForRecv(count: 1, timeout: nil)
        print("send: receiver connected, starting")
        let buffer = [UInt8](repeating: UInt8(ascii: "A"), count: size)
        while !gQuit {
            print("send size: \(buffer.count)")
            _ = try ch.send(data: buffer)
            var ts = timespec(tv_sec: 0, tv_nsec: Int(intervalMs) * 1_000_000)
            nanosleep(&ts, nil)
        }
        ch.disconnect()
    } catch {
        fputs("send error: \(error)\n", stderr)
    }
}

// MARK: - Receiver

private func doRecv(intervalMs: UInt64) async {
    do {
        let ch = try await Channel.connect(name: "ipc", mode: .receiver)
        var k = 1
        while !gQuit {
            print("recv waiting... \(k)")
            let buf = try ch.recv(timeout: .milliseconds(Int64(intervalMs)))
            if gQuit { break }
            if buf.isEmpty { k += 1; continue }
            print("recv size: \(buf.count)")
            k = 1
        }
        ch.disconnect()
    } catch {
        fputs("recv error: \(error)\n", stderr)
    }
}

// MARK: - Entry point

installSignalHandlers()

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("usage: demo-send-recv send <size> <interval_ms>\n", stderr)
    fputs("       demo-send-recv recv <interval_ms>\n", stderr)
    exit(1)
}

switch args[1] {
case "send":
    guard args.count >= 4, let size = Int(args[2]), let interval = UInt64(args[3]) else {
        fputs("usage: demo-send-recv send <size> <interval_ms>\n", stderr)
        exit(1)
    }
    await Channel.clearStorage(name: "ipc")
    await doSend(size: size, intervalMs: interval)

case "recv":
    guard let interval = UInt64(args[2]) else {
        fputs("usage: demo-send-recv recv <interval_ms>\n", stderr)
        exit(1)
    }
    await doRecv(intervalMs: interval)

default:
    fputs("unknown mode: \(args[1])\n", stderr)
    exit(1)
}
