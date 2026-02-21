// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Benchmark backend using raw POSIX threads — mirrors the Rust thread::spawn approach.

import LibIPC
import Darwin.POSIX

// MARK: - pthread helpers

/// Run `body` on a new POSIX thread; return a handle to join later.
private func spawnThread(_ body: @escaping @Sendable () -> Void) -> pthread_t {
    // Box the closure so we can pass it through a C void*.
    let box = Unmanaged.passRetained(ClosureBox(body))
    var tid: pthread_t?
    pthread_create(&tid, nil, { ptr -> UnsafeMutableRawPointer? in
        Unmanaged<ClosureBox>.fromOpaque(ptr).takeRetainedValue().body()
        return nil
    }, box.toOpaque())
    return tid.unsafelyUnwrapped
}

private final class ClosureBox: @unchecked Sendable {
    let body: @Sendable () -> Void
    init(_ body: @escaping @Sendable () -> Void) { self.body = body }
}

// MARK: - Shared ready/done flags (plain Bool + pthread_mutex for simplicity)

private final class Flag: @unchecked Sendable {
    private var _value = false
    private var mu = pthread_mutex_t()
    init() { pthread_mutex_init(&mu, nil) }
    deinit { pthread_mutex_destroy(&mu) }
    var value: Bool {
        get { pthread_mutex_lock(&mu); defer { pthread_mutex_unlock(&mu) }; return _value }
        set { pthread_mutex_lock(&mu); _value = newValue; pthread_mutex_unlock(&mu) }
    }
}

// MARK: - Route 1-N (pthread)

func threadsBenchRoute(nReceivers: Int, count: Int, msgLo: Int, msgHi: Int) -> Stats {
    let name    = "bench_route"
    let sizes   = makeSizes(count: count, lo: msgLo, hi: msgHi)
    let payload = [UInt8](repeating: UInt8(ascii: "X"), count: msgHi)

    Route.clearStorageBlocking(name: name)
    let sender    = Route.connectBlocking(name: name, mode: .sender)
    // Pre-open all receivers on the main thread — avoids concurrent cache access.
    let receivers = (0..<nReceivers).map { _ in Route.connectBlocking(name: name, mode: .receiver) }

    let done = Flag()
    var tids: [pthread_t] = []
    for r in receivers {
        tids.append(spawnThread {
            while !done.value { _ = try? r.recv(timeout: .milliseconds(1)) }
            r.disconnect()
        })
    }

    let t0 = nowMs()
    for size in sizes { _ = try? sender.send(data: Array(payload[..<size])) }
    let totalMs = nowMs() - t0

    done.value = true
    sender.disconnect()
    for tid in tids { pthread_join(tid, nil) }

    return Stats(totalMs: totalMs, count: count)
}

// MARK: - Channel pattern (pthread)

func threadsBenchChannel(pattern: String, n: Int, count: Int, msgLo: Int, msgHi: Int) -> Stats {
    let name       = "bench_chan"
    let nSenders   = (pattern == "N-1" || pattern == "N-N") ? n : 1
    let nReceivers = (pattern == "1-N" || pattern == "N-N") ? n : 1
    let perSender  = count / nSenders
    let sizes      = makeSizes(count: count, lo: msgLo, hi: msgHi)
    let payload    = [UInt8](repeating: UInt8(ascii: "X"), count: msgHi)

    Channel.clearStorageBlocking(name: name)
    // Pre-open everything on the main thread — no concurrent cache access.
    let ctrl      = Channel.connectBlocking(name: name, mode: .sender)
    let receivers = (0..<nReceivers).map { _ in Channel.connectBlocking(name: name, mode: .receiver) }
    let senders   = (0..<nSenders).map   { _ in Channel.connectBlocking(name: name, mode: .sender) }

    let done = Flag()

    var recvTids: [pthread_t] = []
    for ch in receivers {
        recvTids.append(spawnThread {
            while !done.value { _ = try? ch.recv(timeout: .milliseconds(1)) }
            ch.disconnect()
        })
    }

    let t0 = nowMs()

    var sendTids: [pthread_t] = []
    for (s, ch) in senders.enumerated() {
        let base = s * perSender
        sendTids.append(spawnThread {
            for i in 0..<perSender {
                _ = try? ch.send(data: Array(payload[..<sizes[base + i]]))
            }
            ch.disconnect()
        })
    }
    for tid in sendTids { pthread_join(tid, nil) }

    let totalMs = nowMs() - t0

    done.value = true
    ctrl.disconnect()
    for tid in recvTids { pthread_join(tid, nil) }

    return Stats(totalMs: totalMs, count: count)
}
