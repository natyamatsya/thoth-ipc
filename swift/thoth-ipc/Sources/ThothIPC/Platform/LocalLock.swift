// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// A process-local lock for short critical sections: os_unfair_lock on Darwin,
// a pthread mutex elsewhere. Heap-allocated so the lock word never moves.

#if canImport(Darwin)
import Darwin
import os
#elseif canImport(Glibc)
import Glibc
#endif

final class LocalLock: @unchecked Sendable {
    #if canImport(Darwin)
    private let word = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    init() { word.initialize(to: os_unfair_lock()) }
    func lock() { os_unfair_lock_lock(word) }
    func unlock() { os_unfair_lock_unlock(word) }
    #else
    private let word = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    init() { pthread_mutex_init(word, nil) }
    func lock() { pthread_mutex_lock(word) }
    func unlock() { pthread_mutex_unlock(word) }
    #endif

    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }

    deinit {
        #if !canImport(Darwin)
        pthread_mutex_destroy(word)
        #endif
        word.deallocate()
    }
}
