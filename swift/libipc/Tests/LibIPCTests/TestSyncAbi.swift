// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

import Testing
@testable import LibIPC

@Suite("SyncAbiGuard")
struct TestSyncAbi {
    private static func uniqueName(_ prefix: String) -> String {
        "\(prefix)_\(UInt32.random(in: 0..<UInt32.max))"
    }

    private static func mutexSidecarName(_ name: String) -> String {
        "\(name)__libipc_sync_abi_mutex"
    }

    private static func storeWord(base: UnsafeMutableRawPointer, index: Int, value: UInt32) {
        let raw = base.advanced(by: index * MemoryLayout<UInt32>.stride)
        raw.assumingMemoryBound(to: UInt32.self).pointee = value
    }

    private static func isTimeout(_ error: IpcError) -> Bool {
        if case .timeout = error { return true }
        return false
    }

    private static func isInvalidArgument(_ error: IpcError) -> Bool {
        if case .invalidArgument = error { return true }
        return false
    }

    @Test("openMutex times out when sync ABI init is stuck")
    func openMutexTimesOutWhenInitStuck() throws {
        let name = Self.uniqueName("swift_test_sync_abi_stuck")
        let sidecar = Self.mutexSidecarName(name)
        defer { SyncAbiGuard.clearMutexStorage(name: name) }

        let shm = try ShmHandle.acquire(
            name: sidecar,
            size: MemoryLayout<UInt32>.stride * 6,
            mode: .createOrOpen
        )
        Self.storeWord(base: shm.ptr, index: 0, value: .max)

        do {
            _ = try SyncAbiGuard.openMutex(name: name)
            #expect(Bool(false))
        } catch {
            #expect(Self.isTimeout(error))
        }
    }

    @Test("openMutex rejects backend mismatch")
    func openMutexRejectsBackendMismatch() throws {
        let name = Self.uniqueName("swift_test_sync_abi_mismatch")
        let sidecar = Self.mutexSidecarName(name)
        defer { SyncAbiGuard.clearMutexStorage(name: name) }

        let shm = try ShmHandle.acquire(
            name: sidecar,
            size: MemoryLayout<UInt32>.stride * 6,
            mode: .createOrOpen
        )

        // magic, major, minor, backend, primitive, payload
        Self.storeWord(base: shm.ptr, index: 0, value: 0x4C49_5341)
        Self.storeWord(base: shm.ptr, index: 1, value: 1)
        Self.storeWord(base: shm.ptr, index: 2, value: 0)
        Self.storeWord(base: shm.ptr, index: 3, value: 3)
        Self.storeWord(base: shm.ptr, index: 4, value: 1)
        Self.storeWord(base: shm.ptr, index: 5, value: 8)

        do {
            _ = try SyncAbiGuard.openMutex(name: name)
            #expect(Bool(false))
        } catch {
            #expect(Self.isInvalidArgument(error))
        }
    }
}
