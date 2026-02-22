// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

import Darwin.POSIX
import Dispatch

/// Actor-isolated counter for use in concurrent tests.
actor Counter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

// MARK: - pthread helpers for tests

final class PBox: @unchecked Sendable {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
}

/// Spawn a POSIX thread running `body`. Returns the `pthread_t`.
func spawnPthread(_ body: @escaping @Sendable () -> Void) -> pthread_t {
    let box = Unmanaged.passRetained(PBox(body))
    var tid: pthread_t?
    pthread_create(&tid, nil, { ptr -> UnsafeMutableRawPointer? in
        Unmanaged<PBox>.fromOpaque(ptr).takeRetainedValue().body()
        return nil
    }, box.toOpaque())
    return tid.unsafelyUnwrapped
}

/// Join a pthread from an async context by offloading the blocking call to a GCD thread.
func joinThread(_ tid: pthread_t) async {
    nonisolated(unsafe) let t = tid
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            joinThreadSync(t)
            cont.resume()
        }
    }
}

/// Non-async wrapper so the compiler allows pthread_join.
private func joinThreadSync(_ tid: pthread_t) {
    var t = tid
    pthread_join(t, nil)
}
