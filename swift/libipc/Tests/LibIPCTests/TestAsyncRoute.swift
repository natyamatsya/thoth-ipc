// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Layer 2 async-receive tests — Swift equivalent of
// rust/libipc/tests/async_notify.rs. Cross-language wakeup is covered by the
// xlang async matrix; this is the in-process smoke test of AsyncRoute.

import Testing
@testable import LibIPC

@Suite("AsyncRoute")
struct AsyncRouteTests {
    @Test("recv() is woken by a notified send")
    func asyncRecvWakes() async throws {
        let name = "swift_asyncroute_\(UInt32.random(in: 0 ..< UInt32.max))"
        Route.clearStorageBlocking(name: name)
        defer { Route.clearStorageBlocking(name: name) }

        // Receiver first, so the sender's wait_for_recv succeeds and the sink is
        // registered before any post.
        let ar = try await AsyncRoute.connect(name: name)
        #expect(ar.recvCount >= 0)

        let sender = Task.detached {
            let s = Route.connectBlocking(name: name, mode: .sender)
            _ = try? s.waitForRecv(count: 1, timeout: .seconds(3))
            for i in 0 ..< 5 {
                // >64B → also exercises the chunk-storage decode path.
                _ = try? s.send(data: [UInt8](repeating: UInt8(65 + i), count: 100),
                                timeout: .seconds(3))
            }
        }

        for i in 0 ..< 5 {
            let bytes = try await ar.recv().bytes
            #expect(bytes.count == 100)
            #expect(bytes.allSatisfy { $0 == UInt8(65 + i) })
        }
        await sender.value
    }
}
