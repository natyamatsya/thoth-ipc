// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Process-local shm cache — mirrors C++ `curr_prog` in posix/mutex.h
// and Rust `mutex_cache()` / `cond_cache()` in platform/posix.rs.
//
// On macOS, PTHREAD_PROCESS_SHARED mutexes and conditions store internal
// pointers relative to the virtual address used at pthread_mutex_init time.
// All threads within the same process that open the same named primitive
// MUST map the same virtual address — i.e. the same mmap. This actor
// maintains a process-local cache of open shm handles keyed by name.

import Atomics
import Darwin.POSIX
import os

// MARK: - CachedShm

/// A cached shm handle with a process-local reference count.
final class CachedShm: @unchecked Sendable {
    // @unchecked Sendable: shm is process-shared by design;
    // ShmCache serialises all access via actor isolation.
    let shm: ShmHandle
    let localRef: ManagedAtomic<Int>

    init(shm: consuming ShmHandle) {
        self.shm = shm
        self.localRef = ManagedAtomic(1)
    }
}

// MARK: - ShmCacheStorage (mutex-protected, usable from both async and POSIX threads)

/// The actual map storage, protected by a `pthread_mutex`.
/// Both the actor wrapper and the sync path share this object, ensuring
/// the same virtual address is returned for the same SHM name regardless
/// of which concurrency model the caller uses.
final class ShmCacheStorage: @unchecked Sendable {
    private var map: [String: CachedShm] = [:]
    private var lock = os_unfair_lock()

    func acquire(
        name: String,
        size: Int,
        initialize: (UnsafeMutableRawPointer) throws -> Void
    ) throws -> CachedShm {
        os_unfair_lock_lock(&lock)
        if let existing = map[name] {
            existing.localRef.wrappingIncrement(ordering: .relaxed)
            os_unfair_lock_unlock(&lock)
            return existing
        }
        // shm_open + mmap are fast syscalls — safe to hold the lock across them.
        do {
            let shm = try ShmHandle.acquire(name: name, size: size, mode: .createOrOpen)
            if shm.previousRefCount == 0 { try initialize(shm.ptr) }
            let entry = CachedShm(shm: shm)
            map[name] = entry
            os_unfair_lock_unlock(&lock)
            return entry
        } catch {
            os_unfair_lock_unlock(&lock)
            throw error
        }
    }

    func release(name: String) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let entry = map[name] else { return }
        let prev = entry.localRef.loadThenWrappingDecrement(ordering: .acquiringAndReleasing)
        if prev <= 1 { map.removeValue(forKey: name) }
    }

    func purge(name: String) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        map.removeValue(forKey: name)
    }
}

// MARK: - ShmCache actor (thin async wrapper around ShmCacheStorage)

/// Process-local cache of open shm handles.
///
/// Separate instances are used for mutexes and conditions (matching the Rust
/// `mutex_cache()` / `cond_cache()` pattern).
actor ShmCache {
    nonisolated let storage = ShmCacheStorage()

    /// Acquire or reuse a cached shm handle (async path).
    func acquire(
        name: String,
        size: Int,
        initialize: (UnsafeMutableRawPointer) throws -> Void
    ) throws -> CachedShm {
        try storage.acquire(name: name, size: size, initialize: initialize)
    }

    /// Acquire or reuse a cached shm handle (sync path — safe from POSIX threads).
    nonisolated func acquireSync(
        name: String,
        size: Int,
        initialize: (UnsafeMutableRawPointer) throws -> Void
    ) throws -> CachedShm {
        try storage.acquire(name: name, size: size, initialize: initialize)
    }

    /// Release one local reference (async path).
    func release(name: String) { storage.release(name: name) }

    /// Release one local reference (sync path — safe from POSIX threads).
    nonisolated func releaseSync(name: String) { storage.release(name: name) }

    /// Forcibly remove a cache entry (used by `clearStorage`).
    func purge(name: String) { storage.purge(name: name) }
}

// MARK: - Shared cache singletons

/// Process-global cache for mutex shm handles.
let mutexCache = ShmCache()

/// Process-global cache for condition variable shm handles.
let condCache = ShmCache()
