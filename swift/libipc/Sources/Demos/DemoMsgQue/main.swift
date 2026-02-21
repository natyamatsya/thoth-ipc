// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of demo/msg_que/main.cpp and Rust demo_msg_que.
//
// Usage:
//   demo-msg-que s    (sender — measures throughput)
//   demo-msg-que r    (receiver — measures throughput)
//
// Uses Route (single-producer, multi-consumer broadcast).
// The sender sends random-sized messages (128 B – 16 KB) as fast as
// possible and prints throughput every second.  The receiver does the same.

import LibIPC
import Darwin.POSIX
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
        fputs("send: connect failed\n", stderr); return
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
        fputs("recv: connect failed\n", stderr); return
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

// MARK: - Entry point

installSignalHandlers()

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: demo-msg-que s|r\n", stderr)
    exit(1)
}

switch args[1] {
case "s": await doSend()
case "r": await doRecv()
default:
    fputs("unknown mode: \(args[1])  (use 's' or 'r')\n", stderr)
    exit(1)
}
