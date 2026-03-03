// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Module-internal Apple ulock syscall bindings and shared atomic helpers.
// Used by IpcMutex and IpcCondition.

import Atomics

// MARK: - Apple ulock syscall bindings (private Apple API, stable since macOS 10.12)

@_silgen_name("__ulock_wait")
func _ulockWait(
    _ operation: UInt32,
    _ addr: UnsafeMutableRawPointer?,
    _ value: UInt64,
    _ timeoutUs: UInt32
) -> Int32

@_silgen_name("__ulock_wake")
func _ulockWake(
    _ operation: UInt32,
    _ addr: UnsafeMutableRawPointer?,
    _ wakeValue: UInt64
) -> Int32

let kULCompareAndWaitShared: UInt32 = 3
let kULFWakeAll: UInt32 = 0x0000_0100

// MARK: - Shared in-SHM atomic helpers

@inline(__always)
func shmAtomicU32(at ptr: UnsafeMutableRawPointer) -> UnsafeAtomic<UInt32> {
    let storage = ptr.bindMemory(to: UnsafeAtomic<UInt32>.Storage.self, capacity: 1)
    return UnsafeAtomic<UInt32>(at: storage)
}

@inline(__always)
func shmAtomicI32(at ptr: UnsafeMutableRawPointer) -> UnsafeAtomic<Int32> {
    let storage = ptr.bindMemory(to: UnsafeAtomic<Int32>.Storage.self, capacity: 1)
    return UnsafeAtomic<Int32>(at: storage)
}
