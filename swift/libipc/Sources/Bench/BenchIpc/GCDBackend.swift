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
    let name    = "bench_route"
    let sizes   = makeSizes(count: count, lo: msgLo, hi: msgHi)
    let payload = [UInt8](repeating: UInt8(ascii: "X"), count: msgHi)

    Route.clearStorageBlocking(name: name)
    let sender = Route.connectBlocking(name: name, mode: .sender)

    let ready = DispatchSemaphore(value: 0)
    let done  = DispatchSemaphore(value: 0)
    // Use an atomic flag for the hot loop — semaphore only for start/stop sync.
    var doneFlag: Bool = false

    let group = DispatchGroup()
    for _ in 0..<nReceivers {
        DispatchQueue.global().async(group: group) {
            let r = Route.connectBlocking(name: name, mode: .receiver)
            ready.signal()
            while !doneFlag { _ = try? r.recv(timeout: .milliseconds(100)) }
            r.disconnect()
            done.signal()
        }
    }

    // Wait for all receivers to connect.
    for _ in 0..<nReceivers { ready.wait() }

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
    let ctrl = Channel.connectBlocking(name: name, mode: .sender)

    let recvReady = DispatchSemaphore(value: 0)
    let recvDone  = DispatchSemaphore(value: 0)
    var doneFlag: Bool = false

    let recvGroup = DispatchGroup()
    for _ in 0..<nReceivers {
        DispatchQueue.global().async(group: recvGroup) {
            let ch = Channel.connectBlocking(name: name, mode: .receiver)
            recvReady.signal()
            while !doneFlag { _ = try? ch.recv(timeout: .milliseconds(100)) }
            ch.disconnect()
            recvDone.signal()
        }
    }

    for _ in 0..<nReceivers { recvReady.wait() }

    let t0 = nowMs()

    let sendGroup = DispatchGroup()
    let sendDone  = DispatchSemaphore(value: 0)
    for s in 0..<nSenders {
        let base = s * perSender
        DispatchQueue.global().async(group: sendGroup) {
            let ch = Channel.connectBlocking(name: name, mode: .sender)
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
