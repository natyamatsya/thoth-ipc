// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of demo/chat/main.cpp and Rust demo_chat.
//
// Usage: demo-chat   (run multiple instances in separate terminals)
//
// Each instance allocates a unique ID from a shared SHM counter, then
// simultaneously sends and receives messages on the "ipc-chat" channel.
// Type a message and press Enter to broadcast it.  Type "q" to quit.

import LibIPC
import Darwin.POSIX
import Atomics

private let channelName = "ipc-chat"
private let quit = "q"

// MARK: - Unique ID via SHM atomic counter

// Like the C++ demo's `static` handle, the counter segment must stay mapped
// for the process lifetime, or it is unlinked on release and the next
// instance restarts numbering at 0. (Non-optional like the C++ original —
// a failed acquire aborts the demo.)
private let idCounterShm = try! ShmHandle.acquire(
    name: "__CHAT_ACC_STORAGE__",
    size: MemoryLayout<UInt64.AtomicRepresentation>.size,
    mode: .createOrOpen
)

private func calcUniqueId() -> UInt64 {
    let ptr = idCounterShm.ptr.assumingMemoryBound(to: UInt64.AtomicRepresentation.self)
    let atomic = UnsafeAtomic<UInt64>(at: ptr.withMemoryRebound(
        to: UnsafeAtomic<UInt64>.Storage.self, capacity: 1) { $0 })
    return atomic.loadThenWrappingIncrement(ordering: .relaxed)
}

// MARK: - Receiver task

private func recvLoop(id: String, ch: Channel) async {
    print("\(id) is ready.")
    while true {
        guard let buf = try? ch.recv(timeout: nil) else { break }
        if buf.isEmpty { break }
        let text = String(bytes: buf.bytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
        if let sep = text.firstIndex(of: ">") {
            let fromId = String(text[text.startIndex..<sep])
            let msg = String(text[text.index(after: text.index(after: sep))...])
            if fromId == id {
                if msg == quit { break }
                continue
            }
        }
        print(text)
    }
    print("\(id) receiver is quit...")
}

// MARK: - Entry point

let id = "c\(calcUniqueId())"

let sender   = try await Channel.connect(name: channelName, mode: .sender)
let receiver = try await Channel.connect(name: channelName, mode: .receiver)

let recvTask = Task { await recvLoop(id: id, ch: receiver) }

while true {
    print("> ", terminator: "")
    fflush(stdout)
    guard let line = readLine(strippingNewline: true), !line.isEmpty else { break }
    if line == quit { break }
    // send(string:) appends the null terminator a C++ receiver expects.
    _ = try? sender.send(string: "\(id)> \(line)")
}

_ = try? sender.send(string: "\(id)> \(quit)")
sender.disconnect()

await recvTask.value
print("\(id) sender is quit...")
