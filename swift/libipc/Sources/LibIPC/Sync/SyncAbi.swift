// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

import Atomics
import Darwin.POSIX

private let syncAbiMagic: UInt32 = 0x4C49_5341 // "LISA"
private let syncAbiInitInProgress: UInt32 = .max
private let syncAbiVersionMajor: UInt32 = 1
private let syncAbiVersionMinor: UInt32 = 0

// Swift macOS sync uses the Apple ulock profile.
private let syncAbiBackendId: UInt32 = 2 // apple_ulock

private enum SyncAbiPrimitive: UInt32 {
    case mutex = 1
    case condition = 2

    var sidecarSuffix: String {
        switch self {
        case .mutex: return "__libipc_sync_abi_mutex"
        case .condition: return "__libipc_sync_abi_condition"
        }
    }

    var label: String {
        switch self {
        case .mutex: return "mutex"
        case .condition: return "condition"
        }
    }

    var payloadSize: UInt32 {
        switch self {
        case .mutex:
            return 8 // state(u32) + holder(u32)
        case .condition:
            return 8 // seq(u32) + waiters(i32)
        }
    }
}

private struct SyncAbiStamp {
    var magic: UInt32 = 0
    var abiVersionMajor: UInt32 = 0
    var abiVersionMinor: UInt32 = 0
    var backendId: UInt32 = 0
    var primitiveId: UInt32 = 0
    var payloadSize: UInt32 = 0
}

private struct SyncAbiExpected {
    let abiVersionMajor: UInt32
    let abiVersionMinor: UInt32
    let backendId: UInt32
    let primitiveId: UInt32
    let payloadSize: UInt32
}

struct SyncAbiGuard: ~Copyable {
    private let shm: ShmHandle
    private static let acquireRetryLimit = 16

    private static func sidecarName(_ name: String, _ primitive: SyncAbiPrimitive) -> String {
        "\(name)\(primitive.sidecarSuffix)"
    }

    private static func expected(for primitive: SyncAbiPrimitive) -> SyncAbiExpected {
        SyncAbiExpected(
            abiVersionMajor: syncAbiVersionMajor,
            abiVersionMinor: syncAbiVersionMinor,
            backendId: syncAbiBackendId,
            primitiveId: primitive.rawValue,
            payloadSize: primitive.payloadSize
        )
    }

    @inline(__always)
    private static func withAtomicWord<R>(
        _ base: UnsafeMutableRawPointer,
        _ index: Int,
        _ body: (UnsafeAtomic<UInt32>) -> R
    ) -> R {
        let raw = base.advanced(by: index * MemoryLayout<UInt32>.stride)
        let storage = raw.bindMemory(to: UnsafeAtomic<UInt32>.Storage.self, capacity: 1)
        return body(UnsafeAtomic<UInt32>(at: storage))
    }

    private static func validate(
        base: UnsafeMutableRawPointer,
        expected: SyncAbiExpected,
        primitive: SyncAbiPrimitive
    ) throws(IpcError) {
        let actualMajor = withAtomicWord(base, 1) { $0.load(ordering: .acquiring) }
        let actualMinor = withAtomicWord(base, 2) { $0.load(ordering: .acquiring) }
        let actualBackend = withAtomicWord(base, 3) { $0.load(ordering: .acquiring) }
        let actualPrimitive = withAtomicWord(base, 4) { $0.load(ordering: .acquiring) }
        let actualPayload = withAtomicWord(base, 5) { $0.load(ordering: .acquiring) }

        if actualMajor == expected.abiVersionMajor,
           actualMinor == expected.abiVersionMinor,
           actualBackend == expected.backendId,
           actualPrimitive == expected.primitiveId,
           actualPayload == expected.payloadSize {
            return
        }

        throw .invalidArgument(
            "sync ABI mismatch for \(primitive.label): "
            + "expected major.minor=\(expected.abiVersionMajor).\(expected.abiVersionMinor), "
            + "backend=\(expected.backendId), primitive=\(expected.primitiveId), payload=\(expected.payloadSize) "
            + "but found major.minor=\(actualMajor).\(actualMinor), "
            + "backend=\(actualBackend), primitive=\(actualPrimitive), payload=\(actualPayload)"
        )
    }

    private static func initOrValidate(
        base: UnsafeMutableRawPointer,
        expected: SyncAbiExpected,
        primitive: SyncAbiPrimitive
    ) throws(IpcError) {
        while true {
            let magic = withAtomicWord(base, 0) { $0.load(ordering: .acquiring) }
            if magic == syncAbiMagic {
                try validate(base: base, expected: expected, primitive: primitive)
                return
            }

            if magic == syncAbiInitInProgress {
                sched_yield()
                continue
            }

            if magic == 0 {
                let (exchanged, _) = withAtomicWord(base, 0) {
                    $0.weakCompareExchange(
                        expected: 0,
                        desired: syncAbiInitInProgress,
                        successOrdering: .acquiringAndReleasing,
                        failureOrdering: .acquiring
                    )
                }
                if !exchanged {
                    continue
                }

                withAtomicWord(base, 1) { $0.store(expected.abiVersionMajor, ordering: .relaxed) }
                withAtomicWord(base, 2) { $0.store(expected.abiVersionMinor, ordering: .relaxed) }
                withAtomicWord(base, 3) { $0.store(expected.backendId, ordering: .relaxed) }
                withAtomicWord(base, 4) { $0.store(expected.primitiveId, ordering: .relaxed) }
                withAtomicWord(base, 5) { $0.store(expected.payloadSize, ordering: .relaxed) }
                withAtomicWord(base, 0) { $0.store(syncAbiMagic, ordering: .releasing) }
                return
            }

            throw .invalidArgument(
                "sync ABI stamp magic mismatch for \(primitive.label): "
                + "expected \(syncAbiMagic), found \(magic)"
            )
        }
    }

    private static func ensure(name: String, primitive: SyncAbiPrimitive) throws(IpcError) -> SyncAbiGuard {
        guard !name.isEmpty else {
            throw .invalidArgument("name is empty")
        }

        let metaName = sidecarName(name, primitive)
        let shm: ShmHandle
        do {
            shm = try acquireSidecarShm(name: metaName)
        } catch {
            throw error
        }

        try initOrValidate(base: shm.ptr, expected: expected(for: primitive), primitive: primitive)
        return SyncAbiGuard(shm: shm)
    }

    private static func acquireSidecarShm(name: String) throws(IpcError) -> ShmHandle {
        var attempts = 0
        while true {
            do {
                return try ShmHandle.acquire(
                    name: name,
                    size: MemoryLayout<SyncAbiStamp>.size,
                    mode: .createOrOpen
                )
            } catch IpcError.osError(let eno) where eno == EINVAL && attempts < acquireRetryLimit {
                attempts &+= 1
                sched_yield()
            } catch {
                throw error
            }
        }
    }

    private static func clearStorage(name: String, primitive: SyncAbiPrimitive) {
        guard !name.isEmpty else {
            return
        }
        ShmHandle.clearStorage(name: sidecarName(name, primitive))
    }

    static func openMutex(name: String) throws(IpcError) -> SyncAbiGuard {
        try ensure(name: name, primitive: .mutex)
    }

    static func openCondition(name: String) throws(IpcError) -> SyncAbiGuard {
        try ensure(name: name, primitive: .condition)
    }

    static func clearMutexStorage(name: String) {
        clearStorage(name: name, primitive: .mutex)
    }

    static func clearConditionStorage(name: String) {
        clearStorage(name: name, primitive: .condition)
    }
}
