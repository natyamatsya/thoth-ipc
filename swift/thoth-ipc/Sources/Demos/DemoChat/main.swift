// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of demo/chat/main.cpp and Rust demo_chat.
//
// Usage:
//   demo-chat                      interactive (run several in separate terminals)
//   demo-chat bot <lines> <peers>  scripted: wait for <peers> chatters (itself
//                                  included), send "cN> line-<i>" <lines> times
//                                  and exit once it has <lines> lines from every
//                                  other one
//   demo-chat clear                remove the channel and the id counter
//
// Each instance allocates a unique ID from a shared SHM counter, then
// simultaneously sends and receives messages on the "ipc-chat" channel.
// Type a message and press Enter to broadcast it.  Type "q" to quit.

import ThothIPC
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Atomics

private let channelName = "ipc-chat"
private let quit = "q"
private let accStorage = "__CHAT_ACC_STORAGE__"

private func eprint(_ s: String) { fputs(s + "\n", stderrStream) }

// MARK: - Unique ID via SHM atomic counter

// Like the C++ demo's `static` handle, the counter segment must stay mapped
// for the process lifetime, or it is unlinked on release and the next
// instance restarts numbering at 0. (Non-optional like the C++ original —
// a failed acquire aborts the demo.)
private let idCounterShm = try! ShmHandle.acquire(
    name: accStorage,
    size: MemoryLayout<UnsafeAtomic<UInt64>.Storage>.size,
    mode: .createOrOpen
)

private func calcUniqueId() -> UInt64 {
    let ptr = idCounterShm.ptr.assumingMemoryBound(to: UnsafeAtomic<UInt64>.Storage.self)
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

// MARK: - Scripted bot

/// Rendezvous with `peers` receivers, send `lines` lines, then read until
/// every other chatter's `lines` lines have arrived. Returns the exit code.
private func bot(lines: Int, peers: Int) async throws -> Int32 {
    let id = "c\(calcUniqueId())"
    let sender   = try await Channel.connect(name: channelName, mode: .sender)
    let receiver = try await Channel.connect(name: channelName, mode: .receiver)
    print("\(id) is ready.")

    guard (try? sender.waitForRecv(count: peers, timeout: .seconds(10))) == true else {
        eprint("\(id): \(peers) chatters did not show up within 10s")
        return 2
    }
    for i in 0..<lines {
        // send(string:) appends the null terminator a C++ receiver expects.
        guard (try? sender.send(string: "\(id)> line-\(i)", timeout: .seconds(2))) == true else {
            eprint("\(id): send failed")
            return 4
        }
    }

    var got: [String: Int] = [:]   // foreign id -> lines received
    var done = 0                   // foreign ids with all `lines` lines
    while lines > 0 && done + 1 < peers {
        guard let buf = try? receiver.recv(timeout: .seconds(10)), !buf.isEmpty else {
            eprint("\(id): timed out waiting for chat lines")
            return 5
        }
        let text = String(bytes: buf.bytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
        if let sep = text.range(of: "> ") {
            let fromId = String(text[..<sep.lowerBound])
            let msg = String(text[sep.upperBound...])
            if fromId == id || msg == quit { continue }
            got[fromId, default: 0] += 1
            if got[fromId] == lines { done += 1 }
        }
        print(text)
    }
    sender.disconnect()
    receiver.disconnect()
    return 0
}

// MARK: - Entry point

// Line-buffer stdout so each status line shows up immediately when piped.
setvbuf(stdoutStream, nil, _IOLBF, 0)

let args = CommandLine.arguments
if args.count >= 2 {
    switch args[1] {
    case "bot" where args.count >= 4:
        exit(try await bot(lines: Int(args[2]) ?? 0, peers: Int(args[3]) ?? 0))
    case "clear":
        await Channel.clearStorage(name: channelName)
        ShmHandle.clearStorage(name: accStorage)
        exit(0)
    default:
        eprint("usage:\n  demo-chat\n  demo-chat bot <lines> <peers>\n  demo-chat clear")
        exit(1)
    }
}

let id = "c\(calcUniqueId())"

let sender   = try await Channel.connect(name: channelName, mode: .sender)
let receiver = try await Channel.connect(name: channelName, mode: .receiver)

let recvTask = Task { await recvLoop(id: id, ch: receiver) }

while true {
    print("> ", terminator: "")
    fflush(stdoutStream)
    guard let line = readLine(strippingNewline: true), !line.isEmpty else { break }
    if line == quit { break }
    // send(string:) appends the null terminator a C++ receiver expects.
    _ = try? sender.send(string: "\(id)> \(line)")
}

_ = try? sender.send(string: "\(id)> \(quit)")
sender.disconnect()

await recvTask.value
print("\(id) sender is quit...")
