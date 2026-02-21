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

// MARK: - ShmCache actor

/// Process-local cache of open shm handles.
///
/// Separate instances are used for mutexes and conditions (matching the Rust
/// `mutex_cache()` / `cond_cache()` pattern).
actor ShmCache {
    private var map: [String: CachedShm] = [:]

    /// Acquire or reuse a cached shm handle.
    ///
    /// If this is the first local open for `name`, `init` is called with the
    /// shm pointer **while the actor is still isolated**, ensuring no other
    /// task can use the handle before initialisation completes.
    func acquire(
        name: String,
        size: Int,
        initialize: (UnsafeMutableRawPointer) throws -> Void
    ) throws -> CachedShm {
        if let existing = map[name] {
            existing.localRef.wrappingIncrement(ordering: .relaxed)
            return existing
        }
        let shm = try ShmHandle.acquire(name: name, size: size, mode: .createOrOpen)
        if shm.previousRefCount == 0 {
            try initialize(shm.ptr)
        }
        let entry = CachedShm(shm: shm)
        map[name] = entry
        return entry
    }

    /// Release one local reference. Removes the entry when the last ref drops.
    func release(name: String) {
        guard let entry = map[name] else { return }
        let prev = entry.localRef.loadThenWrappingDecrement(ordering: .acquiringAndReleasing)
        if prev <= 1 { map.removeValue(forKey: name) }
    }

    /// Forcibly remove a cache entry (used by `clearStorage` to avoid stale
    /// entries after the underlying shm has been unlinked).
    func purge(name: String) {
        map.removeValue(forKey: name)
    }
}

// MARK: - Shared cache singletons

/// Process-global cache for mutex shm handles.
let mutexCache = ShmCache()

/// Process-global cache for condition variable shm handles.
let condCache = ShmCache()
