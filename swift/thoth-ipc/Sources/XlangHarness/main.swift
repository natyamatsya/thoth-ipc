// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Cross-language round-trip harness (Swift endpoint). Shares the CLI contract
// of the C++ (xlang_ipc) and Rust (xlang) harnesses so the matrix driver
// (tools/xlang-runner) can pair any writer language with any reader language
// on the ipc::route wire.
//
// Verbs (see tools/xlang-runner/README.md for the scenario each serves):
//   write/read (route), cwrite/cread (multi-writer channel), aread (async),
//   twrite/tread (typed codec), swrite[-tamper]/sread[-reject|-badkey|-badkeyid]
//   (AEAD envelope), hold/count/probe (reaping), mhold/mtry/mlock + spost/swait
//   + cvwait/cvnotify (sync primitives), caps, clear.
//
// Payload pattern: byte[i] = 'A' + (i % 26). Secure verbs are gated at runtime
// on the crypto backend (build secure-crypto-c with THOTH_IPC_SECURE_OPENSSL=1),
// which the `caps` verb reports so the matrix driver can plan around it.
import Foundation
import Dispatch
import ThothIPC
import ThothIPCSecureCrypto

func pattern(_ n: Int) -> [UInt8] { (0..<n).map { UInt8(65 + ($0 % 26)) } }

// --- Typed protocol endpoints (scenario: typed) -----------------------------
// The real TypedRouteCodec path with a hand-rolled canonical wire message
// (field 1 varint seq, field 2 bytes payload — no protobuf library needed),
// verified field-by-field on the reader.

struct XlangMsg: Equatable {
    var seq: UInt32
    var payload: [UInt8]
}

enum XlangProtoCodec: TypedCodec {
    typealias Root = XlangMsg
    typealias MessageType = XlangMsg?
    typealias BuilderType = XlangMsg

    static var codecId: CodecId { .protobuf }

    static func putVarint(_ v: UInt64, into out: inout [UInt8]) {
        var v = v
        while v >= 0x80 {
            out.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        out.append(UInt8(truncatingIfNeeded: v))
    }

    static func getVarint(_ bytes: [UInt8], _ pos: inout Int) -> UInt64? {
        var v: UInt64 = 0
        var shift: UInt64 = 0
        while pos < bytes.count {
            let b = bytes[pos]
            pos += 1
            v |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return v }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    static func encode(builder: XlangMsg) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(builder.payload.count + 12)
        out.append(0x08) // field 1, varint
        putVarint(UInt64(builder.seq), into: &out)
        out.append(0x12) // field 2, length-delimited
        putVarint(UInt64(builder.payload.count), into: &out)
        out.append(contentsOf: builder.payload)
        return out
    }

    static func decode(buffer: IpcBuffer) -> XlangMsg? {
        let bytes = buffer.bytes
        var pos = 0
        guard pos < bytes.count, bytes[pos] == 0x08 else { return nil }
        pos += 1
        guard let seq = getVarint(bytes, &pos), seq <= UInt64(UInt32.max) else { return nil }
        guard pos < bytes.count, bytes[pos] == 0x12 else { return nil }
        pos += 1
        guard let len = getVarint(bytes, &pos), bytes.count - pos == Int(len) else { return nil }
        return XlangMsg(seq: UInt32(seq), payload: Array(bytes[pos...]))
    }

    static func verify(message: XlangMsg?) -> Bool { message != nil }
}

func doTwrite(_ name: String, _ count: Int, _ size: Int) -> Int32 {
    runBlocking {
        guard let w = try? await TypedRouteCodec<XlangMsg, XlangProtoCodec>.connect(name: name, mode: .sender) else {
            perr("[swift-typed] connect(sender) failed"); return 3
        }
        guard (try? w.waitForRecv(count: 1, timeout: .seconds(5))) == true else {
            perr("[swift-typed] no receiver within 5s"); return 2
        }
        let payload = pattern(size)
        for i in 0..<count {
            let msg = XlangMsg(seq: UInt32(i), payload: payload)
            guard (try? w.send(builder: msg, timeout: .seconds(8))) == true else {
                perr("[swift-typed] send \(i) failed"); return 4
            }
        }
        perr("[swift-typed] wrote \(count) x \(size)B typed on '\(name)'")
        return 0
    }
}

func doTread(_ name: String, _ count: Int, _ size: Int) -> Int32 {
    runBlocking {
        guard let r = try? await TypedRouteCodec<XlangMsg, XlangProtoCodec>.connect(name: name, mode: .receiver) else {
            perr("[swift-typed] connect(receiver) failed"); return 3
        }
        let want = pattern(size)
        for i in 0..<count {
            guard let root = try? r.recv(timeout: .seconds(8)) else {
                perr("[swift-typed] recv \(i) timed out or undecodable"); return 5
            }
            if root.seq != UInt32(i) {
                perr("[swift-typed] recv \(i) wrong seq \(root.seq)"); return 6
            }
            if root.payload != want {
                perr("[swift-typed] recv \(i) payload mismatch"); return 7
            }
        }
        perr("[swift-typed] read \(count) x \(size)B typed on '\(name)' OK")
        return 0
    }
}

// --- Secure (AEAD envelope v1) endpoints ------------------------------------
// A raw identity inner codec keeps the plaintext byte-exact with the other
// harnesses, so the pairing proves envelope framing + AEAD interop only.

enum RawCodec: TypedCodec {
    typealias Root = [UInt8]
    typealias MessageType = [UInt8]
    typealias BuilderType = [UInt8]

    // Metadata only: these bytes never travel through the typed layer.
    static var codecId: CodecId { .protobuf }

    static func encode(builder: [UInt8]) -> [UInt8] { builder }
    static func decode(buffer: IpcBuffer) -> [UInt8] { buffer.bytes }
}

/// Shared xlang test key — must stay byte-identical across the C++, Rust and
/// Swift harnesses (same values as the per-language secure codec tests).
struct XlangTestKey: OpenSSLEVPKeyProvider {
    static let keyId: UInt32 = 0x0A0B_0C0D
    static let keyBytes: [UInt8] = [
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B,
        0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
    ]
}

/// Same key id, different key material: the envelope's key_id check passes and
/// the AEAD open itself must fail (fail-closed path).
struct XlangWrongKey: OpenSSLEVPKeyProvider {
    static let keyId: UInt32 = XlangTestKey.keyId
    static let keyBytes: [UInt8] = [
        0xF0, 0xE1, 0xD2, 0xC3, 0xB4, 0xA5, 0x96, 0x87, 0x78, 0x69, 0x5A, 0x4B,
        0x3C, 0x2D, 0x1E, 0x0F, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
    ]
}

/// Same key material, different key id: the envelope's key_id check itself
/// must reject the message before any AEAD work.
struct XlangWrongIdKey: OpenSSLEVPKeyProvider {
    static let keyId: UInt32 = XlangTestKey.keyId + 1
    static let keyBytes: [UInt8] = XlangTestKey.keyBytes
}

func doSwrite<Cipher: SecureCipher>(_: Cipher.Type, _ name: String, _ count: Int, _ size: Int,
                                    tamper: Bool) -> Int32 {
    let w = Route.connectBlocking(name: name, mode: .sender)
    guard (try? w.waitForRecv(count: 1, timeout: .seconds(5))) == true else {
        FileHandle.standardError.write(Data("[swift-secure] no receiver within 5s\n".utf8)); return 2
    }
    let plain = pattern(size)
    for i in 0..<count {
        // Seal per message so every envelope carries a fresh nonce.
        let sealed = SecureBuilder<RawCodec, Cipher>(inner: plain)
        if sealed.bytes.isEmpty {
            FileHandle.standardError.write(Data("[swift-secure] seal \(i) failed\n".utf8)); return 9
        }
        var bytes = sealed.bytes
        if tamper {
            // Flip a bit in the trailing AEAD tag: a correctly keyed reader
            // must still reject every message.
            bytes[bytes.count - 1] ^= 0x7F
        }
        guard (try? w.send(data: bytes, timeout: .seconds(8))) == true else {
            FileHandle.standardError.write(Data("[swift-secure] send \(i) failed\n".utf8)); return 4
        }
    }
    let how = tamper ? "tamper-sealed" : "sealed"
    FileHandle.standardError.write(Data("[swift-secure] wrote \(count) x \(size)B \(how) on '\(name)'\n".utf8))
    return 0
}

func doSread<Cipher: SecureCipher>(_: Cipher.Type, _ name: String, _ count: Int, _ size: Int,
                                   expectOpen: Bool) -> Int32 {
    let r = Route.connectBlocking(name: name, mode: .receiver)
    let want = pattern(size)
    for i in 0..<count {
        guard let buf = try? r.recv(timeout: .seconds(8)) else {
            FileHandle.standardError.write(Data("[swift-secure] recv \(i) error\n".utf8)); return 5
        }
        let raw = buf.bytes
        if raw.isEmpty {
            FileHandle.standardError.write(Data("[swift-secure] recv \(i) timed out\n".utf8)); return 5
        }
        if raw == want {
            FileHandle.standardError.write(Data("[swift-secure] recv \(i) arrived as plaintext\n".utf8)); return 10
        }
        let plain = SecureCodec<RawCodec, Cipher>.decode(buffer: IpcBuffer(bytes: raw))
        if !expectOpen {
            if !plain.isEmpty {
                FileHandle.standardError.write(Data("[swift-secure] recv \(i) opened under the WRONG key\n".utf8)); return 11
            }
            continue
        }
        if plain.isEmpty {
            FileHandle.standardError.write(Data("[swift-secure] recv \(i) open failed\n".utf8)); return 8
        }
        if plain.count != size {
            FileHandle.standardError.write(Data("[swift-secure] recv \(i) wrong size: got \(plain.count) want \(size)\n".utf8)); return 6
        }
        if plain != want {
            FileHandle.standardError.write(Data("[swift-secure] recv \(i) plaintext mismatch\n".utf8)); return 7
        }
    }
    let what = expectOpen ? "opened+verified" : "rejected (wrong key)"
    FileHandle.standardError.write(Data("[swift-secure] \(what) \(count) x \(size)B on '\(name)' OK\n".utf8))
    return 0
}

/// Verb dispatch over key provider x expectation:
///   swrite / swrite-tamper — seal (and optionally corrupt the tag)
///   sread                  — correct key, every open must succeed
///   sread-reject           — correct key, every open must FAIL (tampered or
///                            algorithm-mismatched envelopes)
///   sread-badkey           — wrong key material (same id), must fail in AEAD open
///   sread-badkeyid         — wrong key id, must fail the envelope key_id check
func runSecureAlg<C: SecureCipherFamily>(_: C.Type, _ verb: String, _ name: String,
                                         _ count: Int, _ size: Int) -> Int32 {
    switch verb {
    case "swrite": return doSwrite(C.Keyed.self, name, count, size, tamper: false)
    case "swrite-tamper": return doSwrite(C.Keyed.self, name, count, size, tamper: true)
    case "sread": return doSread(C.Keyed.self, name, count, size, expectOpen: true)
    case "sread-reject": return doSread(C.Keyed.self, name, count, size, expectOpen: false)
    case "sread-badkey": return doSread(C.WrongKey.self, name, count, size, expectOpen: false)
    case "sread-badkeyid": return doSread(C.WrongId.self, name, count, size, expectOpen: false)
    default:
        FileHandle.standardError.write(Data("[swift-secure] unknown verb '\(verb)'\n".utf8))
        return 1
    }
}

/// Groups one algorithm's ciphers over the three key providers.
protocol SecureCipherFamily {
    associatedtype Keyed: SecureCipher
    associatedtype WrongKey: SecureCipher
    associatedtype WrongId: SecureCipher
}

enum AES256GCMFamily: SecureCipherFamily {
    typealias Keyed = SecureOpenSSLEVPCipherAES256GCM<XlangTestKey>
    typealias WrongKey = SecureOpenSSLEVPCipherAES256GCM<XlangWrongKey>
    typealias WrongId = SecureOpenSSLEVPCipherAES256GCM<XlangWrongIdKey>
}

enum ChaCha20Poly1305Family: SecureCipherFamily {
    typealias Keyed = SecureOpenSSLEVPCipherChaCha20Poly1305<XlangTestKey>
    typealias WrongKey = SecureOpenSSLEVPCipherChaCha20Poly1305<XlangWrongKey>
    typealias WrongId = SecureOpenSSLEVPCipherChaCha20Poly1305<XlangWrongIdKey>
}

func runSecure(_ verb: String, _ name: String, _ count: Int, _ size: Int, _ alg: String) -> Int32 {
    guard SecureOpenSSLEVPBackend.isAvailable else {
        FileHandle.standardError.write(Data("[swift-secure] crypto backend unavailable (build with THOTH_IPC_SECURE_OPENSSL=1)\n".utf8))
        return 12
    }
    switch alg {
    case "aes256gcm": return runSecureAlg(AES256GCMFamily.self, verb, name, count, size)
    case "chacha20poly1305": return runSecureAlg(ChaCha20Poly1305Family.self, verb, name, count, size)
    default:
        FileHandle.standardError.write(Data("[swift-secure] unknown algorithm '\(alg)'\n".utf8))
        return 1
    }
}

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

func doWrite(_ name: String, _ count: Int, _ size: Int, _ minrecv: Int) -> Int32 {
    let w = Route.connectBlocking(name: name, mode: .sender)
    guard (try? w.waitForRecv(count: minrecv, timeout: .seconds(5))) == true else {
        FileHandle.standardError.write(Data("[swift] fewer than \(minrecv) receivers within 5s\n".utf8)); return 2
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

// Multi-writer endpoints on ipc::channel (N writers, N readers) — same wire
// ABI as route, but exercises the multi-producer claim/CAS paths and cc_id
// self-filtering with concurrent senders of different languages.
func doCwrite(_ name: String, _ count: Int, _ size: Int) -> Int32 {
    let w = Channel.connectBlocking(name: name, mode: .sender)
    guard (try? w.waitForRecv(count: 1, timeout: .seconds(5))) == true else {
        FileHandle.standardError.write(Data("[swift-chan] no receiver within 5s\n".utf8)); return 2
    }
    let msg = pattern(size)
    for i in 0..<count {
        guard (try? w.send(data: msg, timeout: .seconds(8))) == true else {
            FileHandle.standardError.write(Data("[swift-chan] send \(i) failed\n".utf8)); return 4
        }
    }
    FileHandle.standardError.write(Data("[swift-chan] wrote \(count) x \(size)B on '\(name)'\n".utf8))
    return 0
}

func doCread(_ name: String, _ count: Int, _ size: Int) -> Int32 {
    let r = Channel.connectBlocking(name: name, mode: .receiver)
    let want = pattern(size)
    for i in 0..<count {
        guard let buf = try? r.recv(timeout: .seconds(8)) else {
            FileHandle.standardError.write(Data("[swift-chan] recv \(i) error\n".utf8)); return 5
        }
        let bytes = buf.bytes
        if bytes.isEmpty { FileHandle.standardError.write(Data("[swift-chan] recv \(i) timed out\n".utf8)); return 5 }
        if bytes.count != size {
            FileHandle.standardError.write(Data("[swift-chan] recv \(i) wrong size: got \(bytes.count) want \(size)\n".utf8)); return 6
        }
        if bytes != want {
            FileHandle.standardError.write(Data("[swift-chan] recv \(i) payload mismatch\n".utf8)); return 7
        }
    }
    FileHandle.standardError.write(Data("[swift-chan] read \(count) x \(size)B on '\(name)' OK\n".utf8))
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

/// Drive an async body to completion from the synchronous harness main.
func runBlocking(_ body: @escaping @Sendable () async -> Int32) -> Int32 {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var code: Int32 = 0
    Task {
        code = await body()
        sem.signal()
    }
    sem.wait()
    return code
}

func perr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let args = CommandLine.arguments
if args.count < 3 {
    FileHandle.standardError.write(Data("usage: \(args[0]) <write|read|clear> <name> [count] [size]\n".utf8))
    exit(1)
}
let verb = args[1], name = args[2]
if verb == "clear" {
    // One clearer for everything a case may have created under <name>:
    // the ring (route and channel share storage) plus the primitives'
    // derived objects (mutex <name>_m, semaphore <name>_s, cond <name>_c).
    Route.clearStorageBlocking(name: name)
    exit(runBlocking {
        await IpcMutex.clearStorage(name: name + "_m")
        IpcSemaphore.clearStorage(name: name + "_s")
        await IpcCondition.clearStorage(name: name + "_c")
        return 0
    })
}
// --- Cross-language sync primitive endpoints (scenario: primitives) --------
// Lock the mutex and hold it (READY once held), so a peer can probe
// contention (mtry) or, after SIGKILL, robust dead-holder recovery (mlock).
if verb == "mhold" {
    let secs = args.count > 3 ? (Int(args[3]) ?? 20) : 20
    exit(runBlocking {
        guard let m = try? await IpcMutex.open(name: name + "_m") else { perr("[swift-prim] open mutex failed"); return 3 }
        guard (try? m.lock()) != nil else { perr("[swift-prim] lock failed"); return 3 }
        print("READY"); fflush(stdout)
        try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
        try? m.unlock()
        return 0
    })
}
if verb == "mtry" {
    exit(runBlocking {
        guard let m = try? await IpcMutex.open(name: name + "_m") else { perr("[swift-prim] open mutex failed"); return 3 }
        if let got = try? m.tryLock() {
            if got { try? m.unlock(); print("acquired") } else { print("busy") }
        } else {
            print("error")
        }
        return 0
    })
}
if verb == "mlock" {
    let ms = args.count > 3 ? (Int(args[3]) ?? 5000) : 5000
    exit(runBlocking {
        guard let m = try? await IpcMutex.open(name: name + "_m") else { perr("[swift-prim] open mutex failed"); return 3 }
        if let got = try? await m.lock(timeout: .milliseconds(ms)) {
            if got { try? m.unlock(); print("acquired") } else { print("timeout") }
        } else {
            print("error")
        }
        return 0
    })
}
if verb == "spost" {
    let n = args.count > 3 ? (UInt32(args[3]) ?? 1) : 1
    guard let s = try? IpcSemaphore.open(name: name + "_s", count: 0) else { perr("[swift-prim] open semaphore failed"); exit(3) }
    guard (try? s.post(count: n)) != nil else { perr("[swift-prim] post failed"); exit(3) }
    perr("[swift-prim] posted \(n) on '\(name)_s'")
    exit(0)
}
// Wait for exactly <n> posts: all must arrive within the timeout, and no
// surplus token may remain afterwards (count exactness cross-language).
if verb == "swait" {
    let n = args.count > 3 ? (Int(args[3]) ?? 1) : 1
    let ms = args.count > 4 ? (Int(args[4]) ?? 8000) : 8000
    exit(runBlocking {
        guard let s = try? IpcSemaphore.open(name: name + "_s", count: 0) else { perr("[swift-prim] open semaphore failed"); return 3 }
        for i in 0..<n {
            guard (try? await s.wait(timeout: .milliseconds(ms))) == true else {
                perr("[swift-prim] sem wait \(i) timed out"); return 5
            }
        }
        if (try? await s.wait(timeout: .milliseconds(500))) == true {
            perr("[swift-prim] sem had a surplus token after \(n) waits"); return 6
        }
        perr("[swift-prim] waited \(n) posts on '\(name)_s' OK")
        return 0
    })
}
if verb == "cvwait" {
    let ms = args.count > 3 ? (Int(args[3]) ?? 8000) : 8000
    exit(runBlocking {
        guard let m = try? await IpcMutex.open(name: name + "_m") else { perr("[swift-prim] open mutex failed"); return 3 }
        guard let c = try? await IpcCondition.open(name: name + "_c") else { perr("[swift-prim] open condition failed"); return 3 }
        guard (try? m.lock()) != nil else { perr("[swift-prim] lock failed"); return 3 }
        let woke = (try? c.wait(mutex: m, timeout: .milliseconds(ms))) == true
        try? m.unlock()
        if woke { perr("[swift-prim] condition woke on '\(name)_c'"); return 0 }
        perr("[swift-prim] condition wait timed out"); return 5
    })
}
// Broadcast repeatedly (the waiter needs only one wake; looping avoids a
// notify-before-wait race without a side channel).
if verb == "cvnotify" {
    exit(runBlocking {
        guard let m = try? await IpcMutex.open(name: name + "_m") else { perr("[swift-prim] open mutex failed"); return 3 }
        guard let c = try? await IpcCondition.open(name: name + "_c") else { perr("[swift-prim] open condition failed"); return 3 }
        for _ in 0..<30 {
            if (try? m.lock()) != nil {
                try? c.broadcast()
                try? m.unlock()
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return 0
    })
}
// Swift's notify source/sink + AsyncRoute are always-on (no feature gate);
// secure caps depend on the crypto backend compiled into secure-crypto-c.
if verb == "caps" {
    // "prim" = the sync-primitive verbs (mhold/mtry/mlock/spost/swait/
    // cvwait/cvnotify) are available.
    var caps = ["prim", "typed:protobuf", "notify", "async"]
    if SecureOpenSSLEVPBackend.isAvailable {
        caps += ["secure", "secure:aes256gcm", "secure:chacha20poly1305"]
    }
    print(caps.joined(separator: " ")); exit(0)
}
// Dead-connection reaper harness verbs (see tools/xlang-runner, scenario: reap).
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
let alg = args.count > 5 ? args[5] : "aes256gcm"
switch verb {
case "write":
    // Optional 6th arg: wait for that many receivers before sending
    // (fanout cases start N readers of mixed languages).
    let minrecv = args.count > 5 ? max(Int(args[5]) ?? 1, 1) : 1
    exit(doWrite(name, count, size, minrecv))
case "read":   exit(doRead(name, count, size))
case "cwrite": exit(doCwrite(name, count, size))
case "cread":  exit(doCread(name, count, size))
case "twrite": exit(doTwrite(name, count, size))
case "tread":  exit(doTread(name, count, size))
case "aread":  exit(doAread(name, count, size))
case "swrite", "swrite-tamper", "sread", "sread-reject", "sread-badkey", "sread-badkeyid":
    exit(runSecure(verb, name, count, size, alg))
default: FileHandle.standardError.write(Data("unknown verb '\(verb)'\n".utf8)); exit(1)
}
