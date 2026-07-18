// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Polyglot pipeline stage — one hop of a multi-language Route pipeline.
//
// Usage:
//   demo-pipeline source <out> <count> <tag>
//   demo-pipeline stage  <in> <out> <count> <tag>
//   demo-pipeline sink   <in> <count> <tag>
//
// A pipeline is a chain of single-writer→single-reader Route hops, each hop a
// separate process — and, because the wire format is byte-exact across the C++,
// Rust, Swift and Zig ports, each stage can be a *different language*. The source
// seeds items, every stage appends its tag, and the sink prints the fully-
// transformed item. See demo/pipeline/run.sh and the repo README.

import LibIPC
import Darwin.POSIX

private func eprint(_ s: String) { fputs(s + "\n", stderr) }

private func decode(_ buf: IpcBuffer) -> String {
    var b = buf.bytes
    if b.last == 0 { b.removeLast() }
    return String(decoding: b, as: UTF8.self)
}

private func source(out: String, count: Int, tag: String) {
    let tx = Route.connectBlocking(name: out, mode: .sender)
    guard (try? tx.waitForRecv(count: 1, timeout: .seconds(5))) == true else {
        eprint("[source \(tag)] no downstream on '\(out)' within 5s"); exit(2)
    }
    for k in 0..<count {
        while (try? tx.send(string: "item-\(k) [\(tag)]", timeout: .seconds(2))) != true {}
    }
    eprint("[source \(tag)] emitted \(count) items → '\(out)'")
}

private func stage(in inName: String, out: String, count: Int, tag: String) {
    let rx = Route.connectBlocking(name: inName, mode: .receiver)
    let tx = Route.connectBlocking(name: out, mode: .sender)
    guard (try? tx.waitForRecv(count: 1, timeout: .seconds(5))) == true else {
        eprint("[stage \(tag)] no downstream on '\(out)' within 5s"); exit(2)
    }
    for _ in 0..<count {
        guard let buf = try? rx.recv(timeout: .seconds(10)), !buf.isEmpty else {
            eprint("[stage \(tag)] upstream stalled"); exit(5)
        }
        let msg = "\(decode(buf)) -> \(tag)"
        while (try? tx.send(string: msg, timeout: .seconds(2))) != true {}
    }
    eprint("[stage \(tag)] forwarded \(count) items '\(inName)' → '\(out)'")
}

private func sink(in inName: String, count: Int, tag: String) {
    let rx = Route.connectBlocking(name: inName, mode: .receiver)
    eprint("[sink \(tag)] ready on '\(inName)', expecting \(count) items")
    for i in 0..<count {
        guard let buf = try? rx.recv(timeout: .seconds(10)), !buf.isEmpty else {
            eprint("[sink \(tag)] upstream stalled after \(i)/\(count)"); break
        }
        print("\(decode(buf)) -> [\(tag) sink]")
    }
}

// MARK: - Entry point

let a = CommandLine.arguments
func num(_ i: Int) -> Int { i < a.count ? (Int(a[i]) ?? 0) : 0 }
switch (a.count >= 2 ? a[1] : "") {
case "source" where a.count >= 5: source(out: a[2], count: num(3), tag: a[4])
case "stage"  where a.count >= 6: stage(in: a[2], out: a[3], count: num(4), tag: a[5])
case "sink"   where a.count >= 5: sink(in: a[2], count: num(3), tag: a[4])
default:
    eprint("usage:\n  demo-pipeline source <out> <count> <tag>\n  demo-pipeline stage <in> <out> <count> <tag>\n  demo-pipeline sink <in> <count> <tag>")
    exit(1)
}
