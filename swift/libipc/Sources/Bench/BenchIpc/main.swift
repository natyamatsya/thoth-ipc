// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of Rust bench_ipc.rs
//
// Usage:  bench-ipc [max_threads]   (default: 8)
//
// Runs four benchmark suites in-process:
//   1. ipc::route  — 1 sender, N receivers
//   2. ipc::channel 1-N
//   3. ipc::channel N-1
//   4. ipc::channel N-N

import LibIPC
import Darwin.POSIX
import Atomics

// MARK: - Stats

private struct Stats {
    let totalMs: Double
    let count: Int
    var usPerDatum: Double { totalMs * 1000.0 / Double(count) }
}

// MARK: - LCG pseudo-random sizes

private func makeSizes(count: Int, lo: Int, hi: Int) -> [Int] {
    var rng: UInt64 = 42
    return (0..<count).map { _ in
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return lo + Int(rng >> 32) % (hi - lo + 1)
    }
}

// MARK: - Wall-clock timer

private func nowMs() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
    return Double(ts.tv_sec) * 1000.0 + Double(ts.tv_nsec) / 1_000_000.0
}

// MARK: - bench_route: 1 sender, N receivers

private func benchRoute(nReceivers: Int, count: Int, msgLo: Int, msgHi: Int) async -> Stats {
    let name = "bench_route"
    let sizes = makeSizes(count: count, lo: msgLo, hi: msgHi)
    let payload = [UInt8](repeating: UInt8(ascii: "X"), count: msgHi)

    await Route.clearStorage(name: name)
    let sender = try! await Route.connect(name: name, mode: .sender)

    let ready = ManagedAtomic<Bool>(false)
    let done  = ManagedAtomic<Bool>(false)

    // Spawn receiver tasks
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

    // Let receivers connect
    var ts = timespec(tv_sec: 0, tv_nsec: 100_000_000)
    nanosleep(&ts, nil)
    ready.store(true, ordering: .releasing)

    let t0 = nowMs()
    for size in sizes {
        _ = try? sender.send(data: Array(payload[..<size]))
    }
    let totalMs = nowMs() - t0

    done.store(true, ordering: .releasing)
    sender.disconnect()
    for t in recvTasks { await t.value }

    return Stats(totalMs: totalMs, count: count)
}

// MARK: - bench_channel: pattern 1-N / N-1 / N-N

private func benchChannel(pattern: String, n: Int, count: Int, msgLo: Int, msgHi: Int) async -> Stats {
    let name = "bench_chan"
    let nSenders   = (pattern == "N-1" || pattern == "N-N") ? n : 1
    let nReceivers = (pattern == "1-N" || pattern == "N-N") ? n : 1
    let perSender  = count / nSenders

    let sizes   = makeSizes(count: count, lo: msgLo, hi: msgHi)
    let payload = [UInt8](repeating: UInt8(ascii: "X"), count: msgHi)

    await Channel.clearStorage(name: name)
    // Control sender keeps SHM alive and is used to unblock receivers on teardown.
    let ctrl = try! await Channel.connect(name: name, mode: .sender)

    let ready = ManagedAtomic<Bool>(false)
    let done  = ManagedAtomic<Bool>(false)

    // Receivers
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

    var ts = timespec(tv_sec: 0, tv_nsec: 100_000_000)
    nanosleep(&ts, nil)
    ready.store(true, ordering: .releasing)

    let t0 = nowMs()

    // Senders
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

// MARK: - Formatting helpers

private func printHeader(_ title: String) {
    print("\n=== \(title) ===")
}

private func col(_ s: String, _ w: Int) -> String {
    String(repeating: " ", count: max(0, w - s.count)) + s
}

// MARK: - Entry point

let args = CommandLine.arguments
let maxThreads = args.count > 1 ? (Int(args[1]) ?? 8) : 8

print("cpp-ipc benchmark (Swift port)")
let nCPU = Int(sysconf(_SC_NPROCESSORS_ONLN))
print("Platform: macOS, \(nCPU) hardware threads\n")

private func printTableHeader(col1: String) {
    print("\(col(col1, 10))  \(col("total (ms)", 12))  \(col("µs/datum", 12))")
    print("\(col("----------", 10))  \(col("----------", 12))  \(col("----------", 12))")
}

private func printTableRow(label: Int, stats: Stats) {
    let ms  = String(format: "%.2f",  stats.totalMs)
    let us  = String(format: "%.3f",  stats.usPerDatum)
    print("\(col("\(label)", 10))  \(col(ms, 12))  \(col(us, 12))")
}

// ── ipc::route 1-N ──────────────────────────────────────────────────────────
printHeader("ipc::route — 1 sender, N receivers (random 2–256 bytes × 100 000)")
printTableHeader(col1: "Receivers")
var n = 1
while n <= maxThreads {
    let s = await benchRoute(nReceivers: n, count: 100_000, msgLo: 2, msgHi: 256)
    printTableRow(label: n, stats: s)
    n *= 2
}

// ── ipc::channel 1-N ────────────────────────────────────────────────────────
printHeader("ipc::channel — 1-N (random 2–256 bytes × 100 000)")
printTableHeader(col1: "Receivers")
n = 1
while n <= maxThreads {
    let s = await benchChannel(pattern: "1-N", n: n, count: 100_000, msgLo: 2, msgHi: 256)
    printTableRow(label: n, stats: s)
    n *= 2
}

// ── ipc::channel N-1 ────────────────────────────────────────────────────────
printHeader("ipc::channel — N-1 (random 2–256 bytes × 100 000)")
printTableHeader(col1: "Senders")
n = 1
while n <= maxThreads {
    let s = await benchChannel(pattern: "N-1", n: n, count: 100_000, msgLo: 2, msgHi: 256)
    printTableRow(label: n, stats: s)
    n *= 2
}

// ── ipc::channel N-N ────────────────────────────────────────────────────────
printHeader("ipc::channel — N-N (random 2–256 bytes × 100 000)")
printTableHeader(col1: "Threads")
n = 1
while n <= maxThreads {
    let s = await benchChannel(pattern: "N-N", n: n, count: 100_000, msgLo: 2, msgHi: 256)
    printTableRow(label: n, stats: s)
    n *= 2
}

print("\nDone.")
