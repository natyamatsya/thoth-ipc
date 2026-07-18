// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Layer 2 of the optional async-receive work, Swift side: an ergonomic
// `AsyncRoute.recv() async` on top of the Layer-1 readiness fd
// (`Route.nativeWaitHandle()`). Like the Rust `AsyncRoute`, this leans on the
// platform's event loop rather than a bespoke reactor — here a `DispatchSource`
// read source waits for the fd to become readable, then we drain it and
// `tryRecv()`. A Swift `send()` from any language's peer posts the notify that
// wakes this fd.
//
// Single-consumer: drive `recv()` from one task at a time (as with the Rust
// `AsyncRoute`, which takes `&mut self`).

import Darwin
import Dispatch

public final class AsyncRoute: @unchecked Sendable {
    private let route: Route
    private let fd: Int32
    private let queue = DispatchQueue(label: "ipc.asyncroute")

    /// Wrap an existing receiver `Route`. Throws if it has no readiness handle
    /// (not a receiver, or the notify layer is unavailable).
    public init(_ route: Route) throws(IpcError) {
        guard route.mode == .receiver else { throw .osError(EINVAL) }
        let h = route.nativeWaitHandle()
        guard h >= 0 else { throw .osError(ENOTSUP) }
        self.route = route
        self.fd = h
    }

    /// Connect as a receiver on `name` and wrap it for async receive.
    public static func connect(name: String) async throws(IpcError) -> AsyncRoute {
        try AsyncRoute(try await Route.connect(name: name, mode: .receiver))
    }

    /// Connect as a receiver on `name` under `prefix`.
    public static func connect(prefix: String, name: String) async throws(IpcError) -> AsyncRoute {
        try AsyncRoute(try await Route.connect(prefix: prefix, name: name, mode: .receiver))
    }

    public var recvCount: Int { route.recvCount }
    public func disconnect() { route.disconnect() }

    /// Await the next message. Cancel-safe: nothing is consumed until a full
    /// message is returned, so cancelling the awaiting task leaves state intact.
    public func recv() async throws(IpcError) -> IpcBuffer {
        while true {
            // Fast path: anything already queued (also covers messages that landed
            // before we parked, and coalesced notifications).
            let buf = try route.tryRecv()
            if !buf.isEmpty { return buf }
            // Park until the readiness fd signals (a sender's notify post).
            await waitReadable()
            // Level-triggered token fd: drain, then re-check the ring.
            route.drainWaitHandle()
            let again = try route.tryRecv()
            if !again.isEmpty { return again }
            // Spurious wake / consumed elsewhere — loop and re-park.
        }
    }

    /// Suspend until `fd` is readable, using a one-shot dispatch read source.
    private func waitReadable() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                // Guard against the handler firing more than once (cancel + event).
                nonisolated(unsafe) var resumed = false
                let finish = {
                    if resumed { return }
                    resumed = true
                    src.cancel()
                    cont.resume()
                }
                src.setEventHandler(handler: finish)
                src.setCancelHandler(handler: {})
                src.resume()
                // Stash so cancellation can tear it down.
                self.pending = src
            }
        } onCancel: {
            queue.async { self.pending?.cancel(); self.pending = nil }
        }
    }

    // Held only while a single recv() is parked (single-consumer).
    private var pending: DispatchSourceRead?
}
