// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Cross-language round-trip harness (Swift endpoint). Shares the CLI contract
// of the C++ (xlang_ipc) and Rust (xlang) harnesses so tools/xlang_matrix.py
// can pair any writer language with any reader language on the ipc::route wire.
//
//   xlang-harness write <name> <count> <size>   send <count> pattern messages
//   xlang-harness read  <name> <count> <size>   recv+verify; exit 0 iff all match
//   xlang-harness clear <name>                  unlink the channel's shm segments
//
// Payload pattern: byte[i] = 'A' + (i % 26).
import Foundation
import Dispatch
import LibIPC

func pattern(_ n: Int) -> [UInt8] { (0..<n).map { UInt8(65 + ($0 % 26)) } }

/// Async receive via the shipped `AsyncRoute.recv()`. Drives the async work on a
/// Task and blocks the harness thread until it finishes.
func doAread(_ name: String, _ count: Int, _ size: Int) -> Int32 {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var code: Int32 = 0
    Task {
        do {
            let r = try await AsyncRoute.connect(name: name)
            let want = pattern(size)
            for i in 0..<count {
                let bytes = try await r.recv().bytes
                if bytes.count != size {
                    FileHandle.standardError.write(Data("[swift-async] recv \(i) wrong size \(bytes.count)\n".utf8)); code = 6; break
                }
                if bytes != want {
                    FileHandle.standardError.write(Data("[swift-async] recv \(i) mismatch\n".utf8)); code = 7; break
                }
            }
        } catch {
            FileHandle.standardError.write(Data("[swift-async] error: \(error)\n".utf8)); code = 5
        }
        sem.signal()
    }
    sem.wait()
    return code
}

func doWrite(_ name: String, _ count: Int, _ size: Int) -> Int32 {
    let w = Route.connectBlocking(name: name, mode: .sender)
    guard (try? w.waitForRecv(count: 1, timeout: .seconds(5))) == true else {
        FileHandle.standardError.write(Data("[swift] no receiver within 5s\n".utf8)); return 2
    }
    let msg = pattern(size)
    for i in 0..<count {
        guard (try? w.send(data: msg, timeout: .seconds(8))) == true else {
            FileHandle.standardError.write(Data("[swift] send \(i) failed\n".utf8)); return 4
        }
    }
    FileHandle.standardError.write(Data("[swift] wrote \(count) x \(size)B on '\(name)'\n".utf8))
    return 0
}

func doRead(_ name: String, _ count: Int, _ size: Int) -> Int32 {
    let r = Route.connectBlocking(name: name, mode: .receiver)
    let want = pattern(size)
    for i in 0..<count {
        guard let buf = try? r.recv(timeout: .seconds(8)) else {
            FileHandle.standardError.write(Data("[swift] recv \(i) error\n".utf8)); return 5
        }
        let bytes = buf.bytes
        if bytes.isEmpty { FileHandle.standardError.write(Data("[swift] recv \(i) timed out\n".utf8)); return 5 }
        if bytes.count != size {
            FileHandle.standardError.write(Data("[swift] recv \(i) wrong size: got \(bytes.count) want \(size)\n".utf8)); return 6
        }
        if bytes != want {
            FileHandle.standardError.write(Data("[swift] recv \(i) payload mismatch\n".utf8)); return 7
        }
    }
    FileHandle.standardError.write(Data("[swift] read \(count) x \(size)B on '\(name)' OK\n".utf8))
    return 0
}

let args = CommandLine.arguments
if args.count < 3 {
    FileHandle.standardError.write(Data("usage: \(args[0]) <write|read|clear> <name> [count] [size]\n".utf8))
    exit(1)
}
let verb = args[1], name = args[2]
if verb == "clear" { Route.clearStorageBlocking(name: name); exit(0) }
// Swift's notify source/sink + AsyncRoute are always-on (no feature gate).
if verb == "caps" { print("notify async"); exit(0) }
// Dead-connection reaper harness verbs (see tools/xlang_matrix.py --reap).
if verb == "hold" {
    // Connect a receiver and hold it (populating the owner table), so a test can
    // SIGKILL this process and check a reaper reclaims the slot.
    let secs = args.count > 3 ? (Int(args[3]) ?? 30) : 30
    let r = Route.connectBlocking(name: name, mode: .receiver)
    print("READY"); fflush(stdout)
    Thread.sleep(forTimeInterval: TimeInterval(secs))
    _ = r
    exit(0)
}
if verb == "probe" {  // sender: observe recv count without reaping or claiming a slot
    let r = Route.connectBlocking(name: name, mode: .sender)
    print(r.recvCount); exit(0)
}
if verb == "count" {  // receiver: reap-on-connect runs, then report the count
    let r = Route.connectBlocking(name: name, mode: .receiver)
    print(r.recvCount); exit(0)
}
if args.count < 5 { FileHandle.standardError.write(Data("write/read need <count> <size>\n".utf8)); exit(1) }
let count = Int(args[3]) ?? 0
let size = Int(args[4]) ?? 0
switch verb {
case "write": exit(doWrite(name, count, size))
case "read":  exit(doRead(name, count, size))
case "aread": exit(doAread(name, count, size))
default: FileHandle.standardError.write(Data("unknown verb '\(verb)'\n".utf8)); exit(1)
}
