// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of rust/libipc/src/mem.rs — SlabPool
//
// Fixed-size block pool. Mirrors C++ `block_pool<BlockSize, N>`:
// - `insert` claims a slot and returns a stable integer key.
// - `remove` returns the slot to the free list.
// - The pool grows automatically (no fixed upper bound).
//
// Not thread-safe; use one per thread or protect with a lock.

/// Fixed-size block pool.
///
/// Each slot holds exactly `blockSize` bytes. Slots are identified by a
/// stable `Int` key that remains valid until `remove(key:)` is called.
public final class SlabPool {

    public let blockSize: Int

    private var storage: UnsafeMutableRawPointer?
    private var capacity: Int          // number of slots
    private var freeList: [Int] = []   // indices of free slots
    private var occupied: Int = 0

    // MARK: Init

    /// Create a pool with the given block size and initial capacity (number of slots).
    public init(blockSize: Int, capacity: Int = 0) {
        precondition(blockSize > 0, "blockSize must be > 0")
        self.blockSize = blockSize
        self.capacity  = 0
        if capacity > 0 { grow(to: capacity) }
    }

    deinit { storage?.deallocate() }

    // MARK: Insert

    /// Insert a zeroed block and return its stable key.
    @discardableResult
    public func insertZeroed() -> Int {
        let key = claimSlot()
        slotPointer(key).initializeMemory(as: UInt8.self, repeating: 0, count: blockSize)
        return key
    }

    /// Insert a block initialised from `src` (truncated / zero-padded to `blockSize`).
    @discardableResult
    public func insert(from src: [UInt8]) -> Int {
        let key = claimSlot()
        let ptr = slotPointer(key)
        let n = min(src.count, blockSize)
        if n > 0 { src.withUnsafeBytes { ptr.copyMemory(from: $0.baseAddress!, byteCount: n) } }
        if n < blockSize { ptr.advanced(by: n).initializeMemory(as: UInt8.self, repeating: 0, count: blockSize - n) }
        return key
    }

    // MARK: Access

    /// Read-only view of the block at `key`. Returns `nil` if key is invalid.
    public func get(_ key: Int) -> UnsafeRawBufferPointer? {
        guard isOccupied(key) else { return nil }
        return UnsafeRawBufferPointer(start: slotPointer(key), count: blockSize)
    }

    /// Mutable view of the block at `key`. Returns `nil` if key is invalid.
    public func getMut(_ key: Int) -> UnsafeMutableRawBufferPointer? {
        guard isOccupied(key) else { return nil }
        return UnsafeMutableRawBufferPointer(start: slotPointer(key), count: blockSize)
    }

    // MARK: Remove

    /// Return the slot at `key` to the free list.
    public func remove(_ key: Int) {
        precondition(isOccupied(key), "SlabPool.remove: key \(key) is not occupied")
        freeList.append(key)
        occupied -= 1
    }

    // MARK: Stats

    /// Number of occupied slots.
    public var count: Int { occupied }

    /// Whether no slots are occupied.
    public var isEmpty: Bool { occupied == 0 }

    /// Total number of slots (occupied + free).
    public var totalCapacity: Int { capacity }

    // MARK: Private

    private func claimSlot() -> Int {
        if freeList.isEmpty { grow(to: max(capacity * 2, 8)) }
        let key = freeList.removeLast()
        occupied += 1
        return key
    }

    private func grow(to newCapacity: Int) {
        guard newCapacity > capacity else { return }
        let newStorage = UnsafeMutableRawPointer.allocate(
            byteCount: newCapacity * blockSize, alignment: 16)
        if let old = storage {
            newStorage.copyMemory(from: old, byteCount: capacity * blockSize)
            old.deallocate()
        }
        storage = newStorage
        for i in capacity..<newCapacity { freeList.append(i) }
        capacity = newCapacity
    }

    private func slotPointer(_ key: Int) -> UnsafeMutableRawPointer {
        storage!.advanced(by: key * blockSize)
    }

    private func isOccupied(_ key: Int) -> Bool {
        guard key >= 0 && key < capacity else { return false }
        return !freeList.contains(key)
    }
}
