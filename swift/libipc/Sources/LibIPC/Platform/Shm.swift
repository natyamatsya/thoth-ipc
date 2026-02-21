// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/src/libipc/platform/posix/shm_posix.cpp
// POSIX shared memory handle — binary-compatible with ipc::shm::handle.

import Darwin.POSIX
import Atomics
import LibIPCShim

// MARK: - Open mode

/// Open mode for shared memory segments.
/// Mirrors `ipc::shm::create` / `ipc::shm::open` from the C++ library.
public enum ShmOpenMode: Sendable {
    /// Create exclusively — fail if already exists.
    case create
    /// Open existing — fail if it does not exist.
    case open
    /// Create if missing, open if already exists.
    case createOrOpen
}

// MARK: - Layout helpers

/// Alignment of the trailing `atomic<int32_t>` ref-counter — matches C++ `calc_size()`.
private let refCountAlign = MemoryLayout<Int32>.alignment  // 4

/// Total mapped size including the trailing ref-counter.
/// Mirrors C++ `calc_size(user_size)`.
func calcSize(_ userSize: Int) -> Int {
    let aligned = ((userSize &- 1) / refCountAlign + 1) * refCountAlign
    return aligned + MemoryLayout<Int32>.size
}

// MARK: - ShmHandle

/// A named, inter-process shared memory region.
///
/// Binary-compatible with `ipc::shm::handle` from the C++ libipc library.
/// The mapped region ends with a trailing `atomic<int32_t>` reference counter
/// shared between all processes mapping the same segment.
///
/// `ShmHandle` is `~Copyable`: ownership is explicit and the mapping is
/// released in `deinit`.
public struct ShmHandle: ~Copyable, @unchecked Sendable {
    // @unchecked Sendable: the shm region is process-shared by design;
    // callers are responsible for synchronisation of the mapped memory.

    let mem: UnsafeMutableRawPointer
    let totalSize: Int
    let userSize_: Int
    let posixName: String
    /// Ref count *before* our own increment — 0 means we were first.
    let prevRef: Int32

    // MARK: Acquire

    /// Acquire a named shared memory region of `size` bytes.
    public static func acquire(name: String, size: Int, mode: ShmOpenMode) throws(IpcError) -> ShmHandle {
        guard !name.isEmpty else { throw .invalidArgument("name is empty") }
        guard size > 0 else { throw .invalidArgument("size must be > 0") }

        let posixName = makeShmName(name)
        let total = calcSize(size)
        let perms: mode_t = 0o666

        let (fd, needTruncate): (Int32, Bool)
        switch mode {
        case .create:
            let f = posixName.withCString { libipc_shm_open_create($0, perms) }
            guard f != -1 else { throw .osError(errno) }
            (fd, needTruncate) = (f, true)

        case .open:
            let f = posixName.withCString { libipc_shm_open_open($0, perms) }
            guard f != -1 else { throw .osError(errno) }
            (fd, needTruncate) = (f, false)

        case .createOrOpen:
            let f = posixName.withCString { libipc_shm_open_create($0, perms) }
            if f != -1 {
                (fd, needTruncate) = (f, true)
            } else {
                guard errno == EEXIST else { throw .osError(errno) }
                let f2 = posixName.withCString { libipc_shm_open_open($0, perms) }
                guard f2 != -1 else { throw .osError(errno) }
                (fd, needTruncate) = (f2, false)
            }
        }

        fchmod(fd, perms)

        if needTruncate {
            guard ftruncate(fd, off_t(total)) == 0 else {
                let err = errno; close(fd); throw .osError(err)
            }
        }

        let raw = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        close(fd)
        guard raw != MAP_FAILED, let mem = raw else { throw .osError(errno) }

        // Increment the trailing ref-counter (mirrors C++ get_mem).
        let prev = withRefCount(mem, total) { $0.loadThenWrappingIncrement(ordering: .acquiringAndReleasing) }

        return ShmHandle(
            mem: mem,
            totalSize: total,
            userSize_: size,
            posixName: posixName,
            prevRef: prev
        )
    }

    // MARK: Accessors

    /// Pointer to the user-visible region.
    public var ptr: UnsafeMutableRawPointer { mem }

    /// User-requested size (the usable portion).
    public var userSize: Int { userSize_ }

    /// Total mapped size (including the trailing ref-counter).
    public var mappedSize: Int { totalSize }

    /// POSIX name (with leading '/').
    public var name: String { posixName }

    /// Ref count *before* our own increment during acquire (0 = we were first).
    public var previousRefCount: Int32 { prevRef }

    /// Current reference count.
    public var refCount: Int32 {
        withRefCount(mem, totalSize) { $0.load(ordering: .acquiring) }
    }

    // MARK: Unlink

    /// Force-remove the backing file. Does NOT release the mapping.
    public func unlink() {
        _ = posixName.withCString { shm_unlink($0) }
    }

    /// Remove a named shm segment by name without needing an open handle.
    public static func unlink(name: String) {
        _ = makeShmName(name).withCString { shm_unlink($0) }
    }

    /// Remove the backing storage for a named shm segment.
    public static func clearStorage(name: String) {
        unlink(name: name)
    }

    // MARK: Deinit

    deinit {
        let prev = withRefCount(mem, totalSize) { $0.loadThenWrappingDecrement(ordering: .acquiringAndReleasing) }
        munmap(mem, totalSize)
        if prev <= 1 { unlink() }
    }
}

// MARK: - Ref-counter helper

/// Calls `body` with an `UnsafeAtomic<Int32>` view of the trailing ref-counter
/// in a mapped region. The `UnsafeAtomic` is destroyed after the call.
///
/// - Safety: `mem` must point to a valid mapped region of at least `totalSize` bytes.
private func withRefCount<R>(
    _ mem: UnsafeMutableRawPointer,
    _ totalSize: Int,
    _ body: (UnsafeAtomic<Int32>) -> R
) -> R {
    let offset = totalSize - MemoryLayout<Int32>.size
    // UnsafeAtomic.init(at:) requires a pointer to AtomicStorage.
    // On all supported platforms Int32.AtomicStorage == Int32, so we
    // rebind through a raw pointer to avoid the type-system mismatch.
    let rawPtr = mem.advanced(by: offset)
    let storagePtr = rawPtr.bindMemory(to: UnsafeAtomic<Int32>.Storage.self, capacity: 1)
    let atomic = UnsafeAtomic<Int32>(at: storagePtr)
    return body(atomic)
    // Note: UnsafeAtomic.destroy() must NOT be called here — we do not own
    // the storage (it lives in the shm region).
}
