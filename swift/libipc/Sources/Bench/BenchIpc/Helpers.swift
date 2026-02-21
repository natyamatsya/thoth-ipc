// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

import Darwin.POSIX

// MARK: - Stats

struct Stats {
    let totalMs: Double
    let count: Int
    var usPerDatum: Double { totalMs * 1000.0 / Double(count) }
}

// MARK: - LCG pseudo-random sizes (same seed as Rust)

func makeSizes(count: Int, lo: Int, hi: Int) -> [Int] {
    var rng: UInt64 = 42
    return (0..<count).map { _ in
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return lo + Int(rng >> 32) % (hi - lo + 1)
    }
}

// MARK: - Wall-clock timer

func nowMs() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
    return Double(ts.tv_sec) * 1000.0 + Double(ts.tv_nsec) / 1_000_000.0
}

func sleepMs(_ ms: Int) {
    var ts = timespec(tv_sec: 0, tv_nsec: ms * 1_000_000)
    nanosleep(&ts, nil)
}

// MARK: - Output

func printHeader(_ title: String) {
    print("\n=== \(title) ===")
}

func col(_ s: String, _ w: Int) -> String {
    String(repeating: " ", count: max(0, w - s.count)) + s
}

func printTableHeader(col1: String) {
    print("\(col(col1, 10))  \(col("total (ms)", 12))  \(col("µs/datum", 12))")
    print("\(col("----------", 10))  \(col("----------", 12))  \(col("----------", 12))")
}

func printTableRow(label: Int, stats: Stats) {
    let ms = String(format: "%.2f", stats.totalMs)
    let us = String(format: "%.3f", stats.usPerDatum)
    print("\(col("\(label)", 10))  \(col(ms, 12))  \(col(us, 12))")
}
