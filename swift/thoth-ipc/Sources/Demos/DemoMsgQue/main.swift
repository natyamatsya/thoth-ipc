// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of demo/msg_que/main.cpp and Rust demo_msg_que.
//
// Usage:
//   demo-msg-que s    (sender — measures throughput)
//   demo-msg-que r    (receiver — measures throughput)
//   demo-msg-que s <count>   (sender — count mode, see below)
//   demo-msg-que r <count>   (receiver — count mode, see below)
//   demo-msg-que clear       (remove the route's IPC objects)
//
// Uses Route (single-producer, multi-consumer broadcast).
// The sender sends random-sized messages (128 B – 16 KB) as fast as
// possible and prints throughput every second.  The receiver does the same.
//
// Count mode is bounded and verifiable (wire- and output-identical across the
// C++/Rust/Swift/Zig ports): the sender waits up to 5 s for a receiver (else
// exit 2), then sends <count> messages, the k-th being size_k bytes all equal to
// k % 251, size_k = 128 + (k * 7919) % 16257 (2 s send timeout, else exit 4),
// and prints `do_send: sent <count> messages, <bytes> bytes`. The receiver
// prints `do_recv: ready`, checks every message (10 s recv timeout: exit 5;
// wrong size or bytes: exit 6) and prints
// `do_recv: received <count> messages, <bytes> bytes`.

import ThothIPC
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Atomics

private let channelName = "ipc-msg-que"
private let minSz = 128
private let maxSz = 1024 * 16

nonisolated(unsafe) private var gQuit: Bool = false

private func installSignalHandlers() {
    signal(SIGINT)  { _ in gQuit = true }
    signal(SIGTERM) { _ in gQuit = true }
    signal(SIGHUP)  { _ in gQuit = true }
}

// MARK: - Formatting

private func strOfSize(_ sz: Int) -> String {
    if sz > 1024 * 1024 { return "\(sz / (1024 * 1024)) MB" }
    if sz > 1024         { return "\(sz / 1024) KB" }
    return "\(sz) bytes"
}

private func speedOf(_ sz: Int) -> String { "\(strOfSize(sz))/s" }

// MARK: - Throughput reporter

private func countingLoop(counter: ManagedAtomic<Int>) async {
    var i = 0
    while !gQuit {
        var ts = timespec(tv_sec: 0, tv_nsec: 100_000_000)
        nanosleep(&ts, nil)
        i += 1
        guard i % 10 == 0 else { continue }
        i = 0
        let bytes = counter.exchange(0, ordering: .relaxed)
        print(speedOf(bytes))
    }
}

// MARK: - Sender

private func doSend() async {
    print("do_send: start [\(strOfSize(minSz)) - \(strOfSize(maxSz))]...")
    await Route.clearStorage(name: channelName)
    guard let route = try? await Route.connect(name: channelName, mode: .sender) else {
        fputs("send: connect failed\n", stderrStream); return
    }
    print("do_send: waiting for receiver...")
    _ = try? route.waitForRecv(count: 1, timeout: nil)
    print("do_send: receiver connected, starting")

    let counter = ManagedAtomic<Int>(0)
    let reporter = Task.detached { await countingLoop(counter: counter) }
    defer { reporter.cancel() }

    let buf = [UInt8](repeating: 0, count: maxSz)
    var rng: UInt64 = 0xdeadbeef_cafebabe
    while !gQuit {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        let sz = minSz + Int(rng >> 32) % (maxSz - minSz + 1)
        _ = try? route.send(data: Array(buf[..<sz]))
        counter.wrappingIncrement(by: sz, ordering: .relaxed)
        sched_yield()
    }

    route.disconnect()
    print("do_send: quit...")
}

// MARK: - Receiver

private func doRecv() async {
    print("do_recv: start [\(strOfSize(minSz)) - \(strOfSize(maxSz))]...")
    guard let route = try? await Route.connect(name: channelName, mode: .receiver) else {
        fputs("recv: connect failed\n", stderrStream); return
    }

    let counter = ManagedAtomic<Int>(0)
    let reporter = Task.detached { await countingLoop(counter: counter) }
    defer { reporter.cancel() }

    while !gQuit {
        guard let buf = try? route.recv(timeout: .milliseconds(200)) else { continue }
        if buf.isEmpty { continue }
        counter.wrappingIncrement(by: buf.count, ordering: .relaxed)
    }

    route.disconnect()
    print("do_recv: quit...")
}

// MARK: - Count mode (deterministic, verifiable; used by the cross-language runner)

/// Size of the k-th count-mode message: 128 B .. 16 KB, spread by a prime stride.
private func sizeOf(_ k: Int) -> Int { minSz + (k * 7919) % (maxSz - minSz + 1) }

/// Fill byte of the k-th count-mode message.
private func byteOf(_ k: Int) -> UInt8 { UInt8(k % 251) }

private func doSendCount(_ count: Int) async -> Int32 {
    guard let route = try? await Route.connect(name: channelName, mode: .sender) else {
        fputs("do_send: connect failed.\n", stderrStream); return 3
    }
    defer { route.disconnect() }
    guard (try? route.waitForRecv(count: 1, timeout: .milliseconds(5000))) == true else {
        fputs("do_send: no receiver within 5 s.\n", stderrStream); return 2
    }
    var total = 0
    for k in 0..<count {
        let sz = sizeOf(k)
        let payload = [UInt8](repeating: byteOf(k), count: sz)
        guard (try? route.send(data: payload, timeout: .milliseconds(2000))) == true else {
            fputs("do_send: send of message \(k) failed.\n", stderrStream); return 4
        }
        total += sz
    }
    print("do_send: sent \(count) messages, \(total) bytes")
    return 0
}

private func doRecvCount(_ count: Int) async -> Int32 {
    guard let route = try? await Route.connect(name: channelName, mode: .receiver) else {
        fputs("do_recv: connect failed.\n", stderrStream); return 3
    }
    defer { route.disconnect() }
    print("do_recv: ready")
    var total = 0
    for k in 0..<count {
        guard let buf = try? route.recv(timeout: .milliseconds(10_000)), !buf.isEmpty else {
            fputs("do_recv: timed out after \(k)/\(count) messages.\n", stderrStream); return 5
        }
        let b = buf.bytes
        let ok = (minSz...maxSz).contains(b.count)
            && b.count == sizeOf(k)
            && b[0] == byteOf(k)
            && b.allSatisfy { $0 == b[0] }
        guard ok else {
            fputs("do_recv: message \(k) is corrupt (\(b.count) bytes, expected \(sizeOf(k)) bytes of \(byteOf(k))).\n", stderrStream)
            return 6
        }
        total += b.count
    }
    print("do_recv: received \(count) messages, \(total) bytes")
    return 0
}

// MARK: - Entry point

// Line-buffer stdout so each status line shows up immediately when piped.
setvbuf(stdoutStream, nil, _IOLBF, 0)

installSignalHandlers()

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: demo-msg-que s|r [<count>] | clear\n", stderrStream)
    exit(1)
}

if args[1] == "clear" {
    await Route.clearStorage(name: channelName)
    exit(0)
}
if args.count >= 3, args[1] == "s" || args[1] == "r" {
    guard let count = Int(args[2]), count >= 0 else {
        fputs("invalid count: \(args[2])\n", stderrStream)
        exit(1)
    }
    let code: Int32
    if args[1] == "s" { code = await doSendCount(count) } else { code = await doRecvCount(count) }
    exit(code)
}

switch args[1] {
case "s": await doSend()
case "r": await doRecv()
default:
    fputs("unknown mode: \(args[1])  (use 's' or 'r')\n", stderrStream)
    exit(1)
}
