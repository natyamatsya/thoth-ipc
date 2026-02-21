// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Benchmark backend using Swift structured concurrency (Task.detached).

import LibIPC
import Atomics
import Darwin.POSIX

// MARK: - Route 1-N

func asyncBenchRoute(nReceivers: Int, count: Int, msgLo: Int, msgHi: Int) async -> Stats {
    let name = "bench_route"
    let sizes   = makeSizes(count: count, lo: msgLo, hi: msgHi)
    let payload = [UInt8](repeating: UInt8(ascii: "X"), count: msgHi)

    await Route.clearStorage(name: name)
    let sender = try! await Route.connect(name: name, mode: .sender)

    let ready = ManagedAtomic<Bool>(false)
    let done  = ManagedAtomic<Bool>(false)

    var recvTasks: [Task<Void, Never>] = []
    for _ in 0..<nReceivers {
        recvTasks.append(Task.detached {
            let r = try! await Route.connect(name: name, mode: .receiver)
            while !ready.load(ordering: .acquiring) { sched_yield() }
            while !done.load(ordering: .acquiring) {
                _ = try? r.recv(timeout: .milliseconds(100))
            }
            r.disconnect()
        })
    }

    sleepMs(100)
    ready.store(true, ordering: .releasing)

    let t0 = nowMs()
    for size in sizes { _ = try? sender.send(data: Array(payload[..<size])) }
    let totalMs = nowMs() - t0

    done.store(true, ordering: .releasing)
    sender.disconnect()
    for t in recvTasks { await t.value }

    return Stats(totalMs: totalMs, count: count)
}

// MARK: - Channel pattern

func asyncBenchChannel(pattern: String, n: Int, count: Int, msgLo: Int, msgHi: Int) async -> Stats {
    let name       = "bench_chan"
    let nSenders   = (pattern == "N-1" || pattern == "N-N") ? n : 1
    let nReceivers = (pattern == "1-N" || pattern == "N-N") ? n : 1
    let perSender  = count / nSenders
    let sizes      = makeSizes(count: count, lo: msgLo, hi: msgHi)
    let payload    = [UInt8](repeating: UInt8(ascii: "X"), count: msgHi)

    await Channel.clearStorage(name: name)
    let ctrl = try! await Channel.connect(name: name, mode: .sender)

    let ready = ManagedAtomic<Bool>(false)
    let done  = ManagedAtomic<Bool>(false)

    var recvTasks: [Task<Void, Never>] = []
    for _ in 0..<nReceivers {
        recvTasks.append(Task.detached {
            let ch = try! await Channel.connect(name: name, mode: .receiver)
            while !ready.load(ordering: .acquiring) { sched_yield() }
            while !done.load(ordering: .acquiring) {
                _ = try? ch.recv(timeout: .milliseconds(100))
            }
            ch.disconnect()
        })
    }

    sleepMs(100)
    ready.store(true, ordering: .releasing)

    let t0 = nowMs()

    var sendTasks: [Task<Void, Never>] = []
    for s in 0..<nSenders {
        let base = s * perSender
        sendTasks.append(Task.detached {
            let ch = try! await Channel.connect(name: name, mode: .sender)
            for i in 0..<perSender {
                _ = try? ch.send(data: Array(payload[..<sizes[base + i]]))
            }
            ch.disconnect()
        })
    }
    for t in sendTasks { await t.value }

    let totalMs = nowMs() - t0

    done.store(true, ordering: .releasing)
    ctrl.disconnect()
    for t in recvTasks { await t.value }

    return Stats(totalMs: totalMs, count: count)
}
