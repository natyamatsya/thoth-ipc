// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of rust/libipc/benches/alloc.rs
//
// Compares three allocation strategies at three message sizes:
//   small  —  48 bytes  (fits inline in a ring slot, DATA_LENGTH = 64)
//   medium — 256 bytes  (just over one slot, triggers fragmentation)
//   large  — 4096 bytes (large-message path, chunk storage)
//
// Strategies:
//   global  — Array<UInt8> via Swift's global allocator (baseline)
//   bump    — BumpArena (monotonic arena, reset between iterations)
//   slab    — SlabPool  (fixed-size block pool, remove between iterations)
//
// Invoked from main.swift when --alloc is passed.

import Darwin.POSIX
import LibIPC

// MARK: - Workload sizes

private let sizes: [(label: String, bytes: Int)] = [
    ("small_48",    48),
    ("medium_256",  256),
    ("large_4096",  4096),
]

private let iterations = 1_000_000

// MARK: - Timing helper

/// Returns elapsed nanoseconds for `iterations` calls to `body`.
private func measure(iterations: Int, body: () -> Void) -> UInt64 {
    var ts0 = timespec(), ts1 = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts0)
    for _ in 0..<iterations { body() }
    clock_gettime(CLOCK_MONOTONIC, &ts1)
    let ns0 = UInt64(ts0.tv_sec) * 1_000_000_000 + UInt64(ts0.tv_nsec)
    let ns1 = UInt64(ts1.tv_sec) * 1_000_000_000 + UInt64(ts1.tv_nsec)
    return ns1 - ns0
}

private func nsPerOp(_ total: UInt64) -> Double { Double(total) / Double(iterations) }

// MARK: - Benchmark runners

/// global allocator baseline — Array<UInt8> alloc + fill + release
private func benchGlobal(bytes: Int) -> Double {
    let ns = measure(iterations: iterations) {
        var v = [UInt8](repeating: 0xAB, count: bytes)
        // prevent optimizer from eliding the allocation
        withUnsafeBytes(of: &v) { _ = $0.first }
    }
    return nsPerOp(ns)
}

/// BumpArena — allocate, fill first byte, reset
private func benchBump(bytes: Int) -> Double {
    let arena = BumpArena(capacity: bytes * 2)
    let ns = measure(iterations: iterations) {
        let buf = arena.allocateZeroed(byteCount: bytes)
        buf.baseAddress!.storeBytes(of: UInt8(0xAB), as: UInt8.self)
        _ = buf.baseAddress!.load(as: UInt8.self)
        arena.reset()
    }
    return nsPerOp(ns)
}

/// SlabPool — insert zeroed, write first byte, remove
private func benchSlab(bytes: Int) -> Double {
    let pool = SlabPool(blockSize: bytes, capacity: 32)
    let ns = measure(iterations: iterations) {
        let key = pool.insertZeroed()
        pool.getMut(key)!.baseAddress!.storeBytes(of: UInt8(0xAB), as: UInt8.self)
        _ = pool.get(key)!.first
        pool.remove(key)
    }
    return nsPerOp(ns)
}

// MARK: - Public entry point

func runAllocBench() {
    print("\n\n╔══════════════════════════════════════════════════════╗")
    print(  "║  Allocation strategy comparison                      ║")
    print(  "╠══════════════════════════════════════════════════════╣")
    print(  "║  Iterations per cell: \(iterations)                    ║")
    print(  "╚══════════════════════════════════════════════════════╝")

    func pad(_ s: String, _ w: Int) -> String { s + String(repeating: " ", count: max(0, w - s.count)) }
    func rpad(_ s: String, _ w: Int) -> String { String(repeating: " ", count: max(0, w - s.count)) + s }

    let colW = 12
    let header = pad("size", 14) + rpad("global(ns)", colW) + rpad("bump(ns)", colW) + rpad("slab(ns)", colW)
    print("\n" + header)
    print(String(repeating: "-", count: header.count))

    for (label, bytes) in sizes {
        let g = benchGlobal(bytes: bytes)
        let b = benchBump(bytes: bytes)
        let s = benchSlab(bytes: bytes)
        let row = pad(label, 14)
            + rpad(String(format: "%.2f", g), colW)
            + rpad(String(format: "%.2f", b), colW)
            + rpad(String(format: "%.2f", s), colW)
        print(row)
    }

    // Extra: slab vs global at 64 bytes (inline slot size)
    print("\n--- global vs slab at 64 bytes (inline slot size) ---")
    let g64 = benchGlobal(bytes: 64)
    let s64 = benchSlab(bytes: 64)
    print(String(format: "  global: %.2f ns/op", g64))
    print(String(format: "  slab:   %.2f ns/op  (%.1fx vs global)", s64, g64 / s64))
}
