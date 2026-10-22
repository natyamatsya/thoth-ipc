// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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

@inline(__always) private func threadArg(_ p: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer { p! }

/// Spawn a POSIX thread running `body`. Returns the `pthread_t`.
func spawnPthread(_ body: @escaping @Sendable () -> Void) -> pthread_t {
    let box = Unmanaged.passRetained(PBox(body))
    // pthread_t is an optional pointer on Darwin and an integer on Linux, and the
    // start routine's argument is optional only on Linux.
    #if canImport(Darwin)
    var tid: pthread_t?
    #else
    var tid = pthread_t()
    #endif
    pthread_create(&tid, nil, { ptr -> UnsafeMutableRawPointer? in
        Unmanaged<PBox>.fromOpaque(threadArg(ptr)).takeRetainedValue().body()
        return nil
    }, box.toOpaque())
    #if canImport(Darwin)
    return tid.unsafelyUnwrapped
    #else
    return tid
    #endif
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
    pthread_join(tid, nil)
}
