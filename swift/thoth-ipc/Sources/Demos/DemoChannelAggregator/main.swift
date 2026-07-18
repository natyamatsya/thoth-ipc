// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Multi-writer thoth::channel fan-in aggregator.
//
// Usage (run the collector first, then one or more producers):
//   demo-channel-aggregator collect <total>
//   demo-channel-aggregator produce <id> <count>
//
// N producer processes each send into ONE shared Channel; a single collector
// recvs the merged, correctly-reassembled stream and tallies it by producer.
// This is the pattern a single-writer Route cannot express — a Channel has
// multiple committing writers. The wire format is byte-exact across the C++,
// Rust, Swift and Zig ports, so producers and the collector can be any mix of
// languages (see the repo README).

import ThothIPC
import Darwin.POSIX

private let channelName = "ipc-aggregator"

private func eprint(_ s: String) { fputs(s + "\n", stderr) }

private func decode(_ buf: IpcBuffer) -> String {
    var b = buf.bytes
    if b.last == 0 { b.removeLast() }          // strip the trailing NUL
    return String(decoding: b, as: UTF8.self)
}

/// The single reader: drains `total` messages from every producer and tallies.
private func collect(total: Int) {
    let ch = Channel.connectBlocking(name: channelName, mode: .receiver)
    print("[collector] ready on '\(channelName)', expecting \(total) messages from any number of producers")

    var tally: [String: Int] = [:]
    var got = 0
    while got < total {
        guard let buf = try? ch.recv(timeout: .seconds(10)), !buf.isEmpty else {
            eprint("[collector] timed out with \(got)/\(total) received")
            break
        }
        let msg = decode(buf)
        let producer = String(msg.prefix(while: { $0 != " " }))  // "<id> #<k>" → "<id>"
        tally[producer, default: 0] += 1
        got += 1
        print("[collector] \(got)/\(total)  \(msg)")
    }

    print("\n[collector] summary — \(got) messages from \(tally.count) producer(s):")
    for p in tally.keys.sorted() {
        print("    \(p)  \(tally[p]!)")
    }
}

/// One of N concurrent writers: sends `count` tagged messages into the channel.
private func produce(id: String, count: Int) {
    let ch = Channel.connectBlocking(name: channelName, mode: .sender)
    // A channel send reaches no one without a receiver — wait for the collector.
    guard (try? ch.waitForRecv(count: 1, timeout: .seconds(5))) == true else {
        eprint("[producer \(id)] no collector within 5s — start the collector first")
        exit(2)
    }
    for k in 0..<count {
        // send returns false only if the ring is momentarily full; retry.
        while (try? ch.send(string: "\(id) #\(k)", timeout: .seconds(2))) != true {}
    }
    print("[producer \(id)] sent \(count) messages into '\(channelName)'")
    ch.disconnect()
}

// MARK: - Entry point

let args = CommandLine.arguments
switch (args.count >= 2 ? args[1] : "") {
case "collect" where args.count >= 3:
    collect(total: Int(args[2]) ?? 0)
case "produce" where args.count >= 4:
    produce(id: args[2], count: Int(args[3]) ?? 0)
default:
    eprint("usage:\n  demo-channel-aggregator collect <total>\n  demo-channel-aggregator produce <id> <count>")
    exit(1)
}
