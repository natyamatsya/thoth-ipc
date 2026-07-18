// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Cross-language bounded buffer — the classic producer/consumer problem solved
// with the byte-exact named IPC primitives.
//
// Usage (run the consumer first, then one or more producers):
//   demo-bounded-buffer consume <total>
//   demo-bounded-buffer produce <id> <count>
//
// A fixed-capacity ring lives in a shared-memory segment; access is coordinated
// by a named IpcMutex (so multiple producers can contend for `head`) and two
// counting IpcSemaphores — `empty` (free slots, starts at CAP) and `full`
// (filled slots, starts at 0). Producers and the consumer can be *different
// languages*: the shm layout, the mutex and both semaphores are byte-exact
// across the C++, Rust, Swift and Zig ports.

import LibIPC
import Darwin.POSIX

private let SHM = "__BBUF__"
private let MUTEX = "bbuf_m"
private let EMPTY = "bbuf_e"
private let FULL = "bbuf_f"
private let CAP: UInt32 = 4
private let SLOT = 48
private let SHM_SIZE = 8 + Int(CAP) * 48

private func eprint(_ s: String) { fputs(s + "\n", stderr) }

// Raw ring accessors over the shm mapping: head(u32)@0, tail(u32)@4, slots@8.
private func head(_ p: UnsafeMutableRawPointer) -> UInt32 { p.load(fromByteOffset: 0, as: UInt32.self) }
private func tail(_ p: UnsafeMutableRawPointer) -> UInt32 { p.load(fromByteOffset: 4, as: UInt32.self) }
private func setHead(_ p: UnsafeMutableRawPointer, _ v: UInt32) { p.storeBytes(of: v, toByteOffset: 0, as: UInt32.self) }
private func setTail(_ p: UnsafeMutableRawPointer, _ v: UInt32) { p.storeBytes(of: v, toByteOffset: 4, as: UInt32.self) }
private func slot(_ p: UnsafeMutableRawPointer, _ idx: UInt32) -> UnsafeMutableRawPointer { p.advanced(by: 8 + Int(idx) * SLOT) }

private func produce(id: String, count: Int) {
    let shm = try! ShmHandle.acquire(name: SHM, size: SHM_SIZE, mode: .createOrOpen)
    let base = shm.ptr
    if shm.refCount <= 1 { setHead(base, 0); setTail(base, 0) }
    let mtx = try! IpcMutex.openSync(name: MUTEX)
    let empty = try! IpcSemaphore.open(name: EMPTY, count: CAP)
    let full = try! IpcSemaphore.open(name: FULL, count: 0)

    for k in 0..<count {
        try! empty.wait()                     // wait for a free slot (launcher gives exact counts)
        try! mtx.lock()
        let idx = head(base)
        setHead(base, (idx + 1) % CAP)
        var bytes = Array("\(id) #\(k)".utf8)
        let n = min(bytes.count, SLOT - 1)
        let s = slot(base, idx)
        bytes.withUnsafeBytes { s.copyMemory(from: $0.baseAddress!, byteCount: n) }
        s.storeBytes(of: UInt8(0), toByteOffset: n, as: UInt8.self)
        try! mtx.unlock()
        try! full.post(count: 1)
    }
    eprint("[producer \(id)] produced \(count) items")
}

private func consume(total: Int) {
    let shm = try! ShmHandle.acquire(name: SHM, size: SHM_SIZE, mode: .createOrOpen)
    let base = shm.ptr
    if shm.refCount <= 1 { setHead(base, 0); setTail(base, 0) }
    let mtx = try! IpcMutex.openSync(name: MUTEX)
    let empty = try! IpcSemaphore.open(name: EMPTY, count: CAP)
    let full = try! IpcSemaphore.open(name: FULL, count: 0)
    print("[consumer] ready — draining \(total) items through a \(CAP)-slot ring")

    var tally: [String: Int] = [:]
    for i in 0..<total {
        try! full.wait()                      // wait for a filled slot
        try! mtx.lock()
        let idx = tail(base)
        setTail(base, (idx + 1) % CAP)
        let s = slot(base, idx)
        var b: [UInt8] = []
        var j = 0
        while j < SLOT { let c = s.load(fromByteOffset: j, as: UInt8.self); if c == 0 { break }; b.append(c); j += 1 }
        try! mtx.unlock()
        try! empty.post(count: 1)             // free the slot
        let msg = String(decoding: b, as: UTF8.self)
        tally[String(msg.prefix(while: { $0 != " " })), default: 0] += 1
        print("[consumer] \(i + 1)/\(total)  \(msg)")
    }

    print("\n[consumer] summary — \(tally.values.reduce(0, +)) items from \(tally.count) producer(s):")
    for p in tally.keys.sorted() { print("    \(p)  \(tally[p]!)") }
}

// MARK: - Entry point

let a = CommandLine.arguments
switch (a.count >= 2 ? a[1] : "") {
case "consume" where a.count >= 3: consume(total: Int(a[2]) ?? 0)
case "produce" where a.count >= 4: produce(id: a[2], count: Int(a[3]) ?? 0)
default:
    eprint("usage:\n  demo-bounded-buffer consume <total>\n  demo-bounded-buffer produce <id> <count>")
    exit(1)
}
