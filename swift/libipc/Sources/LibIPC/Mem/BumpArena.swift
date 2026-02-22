// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of rust/libipc/src/mem.rs — BumpArena
//
// Monotonic bump-pointer arena. Mirrors C++ `monotonic_buffer_resource`:
// - Individual allocations are never freed.
// - `reset()` releases all memory at once.
//
// Not thread-safe; use one per thread or protect with a lock.

import Darwin.C

/// Monotonic bump-pointer arena.
///
/// Allocates from a contiguous heap region. Individual allocations cannot be
/// freed; call `reset()` to reclaim all memory at once.
public final class BumpArena {

    private var chunks: [Chunk] = []
    private var defaultCapacity: Int

    private struct Chunk {
        let base: UnsafeMutableRawPointer
        let capacity: Int
        var used: Int = 0

        init(capacity: Int) {
            base = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
            self.capacity = capacity
        }

        mutating func tryAlloc(byteCount: Int, alignment: Int) -> UnsafeMutableRawPointer? {
            let aligned = (used + alignment - 1) & ~(alignment - 1)
            guard aligned + byteCount <= capacity else { return nil }
            let ptr = base.advanced(by: aligned)
            used = aligned + byteCount
            return ptr
        }

        func free() { base.deallocate() }
    }

    // MARK: Init

    /// Create an arena with the given initial capacity.
    public init(capacity: Int = 4096) {
        defaultCapacity = max(capacity, 64)
        chunks.append(Chunk(capacity: defaultCapacity))
    }

    deinit { reset(); chunks.first?.free() }

    // MARK: Allocation

    /// Allocate `byteCount` bytes aligned to `alignment` (must be power of two).
    /// Returns a pointer valid until the next `reset()`.
    @discardableResult
    public func allocate(byteCount: Int, alignment: Int = 1) -> UnsafeMutableRawPointer {
        precondition(byteCount > 0)
        precondition(alignment > 0 && (alignment & (alignment - 1)) == 0,
                     "alignment must be a power of two")

        if let ptr = chunks[chunks.count - 1].tryAlloc(byteCount: byteCount, alignment: alignment) {
            return ptr
        }
        // Grow: new chunk large enough for this allocation
        let newCap = max(defaultCapacity, byteCount + alignment)
        var chunk = Chunk(capacity: newCap)
        let ptr = chunk.tryAlloc(byteCount: byteCount, alignment: alignment)!
        chunks.append(chunk)
        return ptr
    }

    /// Allocate `byteCount` bytes, fill with zeros, return as `UnsafeMutableBufferPointer`.
    public func allocateZeroed(byteCount: Int, alignment: Int = 1) -> UnsafeMutableRawBufferPointer {
        let ptr = allocate(byteCount: byteCount, alignment: alignment)
        ptr.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        return UnsafeMutableRawBufferPointer(start: ptr, count: byteCount)
    }

    /// Copy `bytes` into the arena and return a buffer pointing to the copy.
    public func allocateCopy(of bytes: [UInt8]) -> UnsafeRawBufferPointer {
        guard !bytes.isEmpty else { return UnsafeRawBufferPointer(start: nil, count: 0) }
        let ptr = allocate(byteCount: bytes.count, alignment: 1)
        bytes.withUnsafeBytes { ptr.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        return UnsafeRawBufferPointer(start: ptr, count: bytes.count)
    }

    // MARK: Reset

    /// Release all allocations. Pointers obtained before this call become invalid.
    public func reset() {
        for i in 0..<chunks.count {
            if i == 0 {
                chunks[i].used = 0   // keep the first chunk, just reset cursor
            } else {
                chunks[i].free()
            }
        }
        if chunks.count > 1 { chunks.removeSubrange(1...) }
    }

    // MARK: Stats

    /// Total bytes allocated across all chunks (including padding).
    public var allocatedBytes: Int { chunks.reduce(0) { $0 + $1.used } }

    /// Total capacity across all chunks.
    public var totalCapacity: Int { chunks.reduce(0) { $0 + $1.capacity } }
}
