// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of demo/send_recv/main.cpp and Rust demo_send_recv.
//
// Usage:
//   demo-send-recv send <size> <interval_ms> [count]
//   demo-send-recv recv <interval_ms> [count]
//   demo-send-recv clear
//
// Two processes share a channel named "ipc".
// The sender fills a buffer of <size> bytes with 'A' and sends it every
// <interval_ms> milliseconds.  The receiver polls with a <interval_ms>
// timeout and prints the received size.
//
// Without <count> both run until a signal. With <count> the run is bounded:
// the receiver prints "recv ready" and exits 0 after <count> messages (exit 5
// if one does not arrive within 10 s); the sender waits up to 5 s for a
// receiver (else exit 2), sends <count> messages with a 2 s send timeout
// (exit 4 on failure) and exits 0. `clear` removes the channel's storage.

import ThothIPC
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
        // Wait in short slices so a signal can still end the wait.
        while try !ch.waitForRecv(count: 1, timeout: .milliseconds(200)) {
            if gQuit { ch.disconnect(); return }
        }
        print("send: receiver connected, starting")
        let buffer = [UInt8](repeating: UInt8(ascii: "A"), count: size)
        while !gQuit {
            print("send size: \(buffer.count)")
            _ = try ch.send(data: buffer)
            sleepMs(intervalMs)
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

// MARK: - Bounded (count) modes

private func sleepMs(_ ms: UInt64) {
    var ts = timespec(tv_sec: Int(ms / 1000), tv_nsec: Int(ms % 1000) * 1_000_000)
    nanosleep(&ts, nil)
}

/// Wait for a receiver, then send `count` messages of `size` bytes.
private func doSendCount(size: Int, intervalMs: UInt64, count: Int) async -> Int32 {
    guard let ch = try? await Channel.connect(name: "ipc", mode: .sender) else {
        fputs("send: connect failed\n", stderr)
        return 3
    }
    defer { ch.disconnect() }
    guard (try? ch.waitForRecv(count: 1, timeout: .milliseconds(5000))) == true else {
        fputs("send: no receiver within 5s -- start the receiver first\n", stderr)
        return 2
    }
    let buffer = [UInt8](repeating: UInt8(ascii: "A"), count: size)
    for k in 0..<count {
        print("send size: \(buffer.count)")
        guard (try? ch.send(data: buffer, timeout: .milliseconds(2000))) == true else {
            fputs("send: failed to send message \(k)\n", stderr)
            return 4
        }
        sleepMs(intervalMs)
    }
    return 0
}

/// Receive `count` messages, each within 10 s.
private func doRecvCount(count: Int) async -> Int32 {
    guard let ch = try? await Channel.connect(name: "ipc", mode: .receiver) else {
        fputs("recv: connect failed\n", stderr)
        return 3
    }
    defer { ch.disconnect() }
    print("recv ready")
    for k in 0..<count {
        guard let buf = try? ch.recv(timeout: .seconds(10)), !buf.isEmpty else {
            fputs("recv: timed out waiting for message \(k)\n", stderr)
            return 5
        }
        print("recv size: \(buf.count)")
    }
    return 0
}

// MARK: - Entry point

// Line-buffer stdout so each status line shows up immediately when piped.
setvbuf(stdout, nil, _IOLBF, 0)

installSignalHandlers()

let args = CommandLine.arguments
if args.count >= 2 && args[1] == "clear" {
    await Channel.clearStorage(name: "ipc")
    exit(0)
}
guard args.count >= 3 else {
    fputs("usage: demo-send-recv send <size> <interval_ms> [count]\n", stderr)
    fputs("       demo-send-recv recv <interval_ms> [count]\n", stderr)
    fputs("       demo-send-recv clear\n", stderr)
    exit(1)
}

switch args[1] {
case "send":
    guard args.count >= 4, let size = Int(args[2]), let interval = UInt64(args[3]) else {
        fputs("usage: demo-send-recv send <size> <interval_ms> [count]\n", stderr)
        exit(1)
    }
    if args.count >= 5 {
        guard let count = Int(args[4]) else {
            fputs("usage: demo-send-recv send <size> <interval_ms> [count]\n", stderr)
            exit(1)
        }
        exit(await doSendCount(size: size, intervalMs: interval, count: count))
    }
    await doSend(size: size, intervalMs: interval)

case "recv":
    guard let interval = UInt64(args[2]) else {
        fputs("usage: demo-send-recv recv <interval_ms> [count]\n", stderr)
        exit(1)
    }
    if args.count >= 4 {
        guard let count = Int(args[3]) else {
            fputs("usage: demo-send-recv recv <interval_ms> [count]\n", stderr)
            exit(1)
        }
        exit(await doRecvCount(count: count))
    }
    await doRecv(intervalMs: interval)

default:
    fputs("unknown mode: \(args[1])\n", stderr)
    exit(1)
}
