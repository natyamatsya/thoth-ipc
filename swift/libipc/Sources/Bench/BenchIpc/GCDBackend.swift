// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Benchmark backend using Grand Central Dispatch (DispatchQueue / DispatchGroup).
// GCD uses a thread pool managed by the OS, similar to Rust's thread::spawn
// but with work-stealing and automatic pool sizing.

import LibIPC
import Darwin.POSIX
import Dispatch

// MARK: - Route 1-N (GCD)

func gcdBenchRoute(nReceivers: Int, count: Int, msgLo: Int, msgHi: Int) -> Stats {
    let name      = "bench_route"
    let sizes     = makeSizes(count: count, lo: msgLo, hi: msgHi)
    let payload   = [UInt8](repeating: UInt8(ascii: "X"), count: msgHi)

    Route.clearStorageBlocking(name: name)
    let sender    = Route.connectBlocking(name: name, mode: .sender)
    let receivers = (0..<nReceivers).map { _ in Route.connectBlocking(name: name, mode: .receiver) }

    var doneFlag: Bool = false
    let done = DispatchSemaphore(value: 0)

    for r in receivers {
        DispatchQueue.global().async {
            while !doneFlag { _ = try? r.recv(timeout: .milliseconds(1)) }
            r.disconnect()
            done.signal()
        }
    }

    let t0 = nowMs()
    for size in sizes { _ = try? sender.send(data: Array(payload[..<size])) }
    let totalMs = nowMs() - t0

    doneFlag = true
    sender.disconnect()
    for _ in 0..<nReceivers { done.wait() }

    return Stats(totalMs: totalMs, count: count)
}

// MARK: - Channel pattern (GCD)

func gcdBenchChannel(pattern: String, n: Int, count: Int, msgLo: Int, msgHi: Int) -> Stats {
    let name       = "bench_chan"
    let nSenders   = (pattern == "N-1" || pattern == "N-N") ? n : 1
    let nReceivers = (pattern == "1-N" || pattern == "N-N") ? n : 1
    let perSender  = count / nSenders
    let sizes      = makeSizes(count: count, lo: msgLo, hi: msgHi)
    let payload    = [UInt8](repeating: UInt8(ascii: "X"), count: msgHi)

    Channel.clearStorageBlocking(name: name)
    let ctrl      = Channel.connectBlocking(name: name, mode: .sender)
    let receivers = (0..<nReceivers).map { _ in Channel.connectBlocking(name: name, mode: .receiver) }
    let senders   = (0..<nSenders).map   { _ in Channel.connectBlocking(name: name, mode: .sender) }

    var doneFlag: Bool = false
    let recvDone = DispatchSemaphore(value: 0)
    let sendDone = DispatchSemaphore(value: 0)

    for ch in receivers {
        DispatchQueue.global().async {
            while !doneFlag { _ = try? ch.recv(timeout: .milliseconds(1)) }
            ch.disconnect()
            recvDone.signal()
        }
    }

    let t0 = nowMs()

    for (s, ch) in senders.enumerated() {
        let base = s * perSender
        DispatchQueue.global().async {
            for i in 0..<perSender {
                _ = try? ch.send(data: Array(payload[..<sizes[base + i]]))
            }
            ch.disconnect()
            sendDone.signal()
        }
    }
    for _ in 0..<nSenders { sendDone.wait() }

    let totalMs = nowMs() - t0

    doneFlag = true
    ctrl.disconnect()
    for _ in 0..<nReceivers { recvDone.wait() }

    return Stats(totalMs: totalMs, count: count)
}
