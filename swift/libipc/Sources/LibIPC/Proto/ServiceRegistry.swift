// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/include/libipc/proto/service_registry.h.
// SHM-backed process service registry.

import Darwin.POSIX

// MARK: - Constants

public let maxServices: Int = 32
public let maxNameLen:  Int = 64

// MARK: - ServiceEntry

/// A single service entry in the shared registry.
/// Binary layout matches C++ / Rust `ServiceEntry`.
@frozen
public struct ServiceEntry: Sendable {
    public var name:           (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    public var controlChannel: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    public var replyChannel:   (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    public var pid:            Int32
    public var registeredAt:   Int64
    public var flags:          UInt32

    public init() {
        name           = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                          0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        controlChannel = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                          0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        replyChannel   = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                          0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        pid = 0; registeredAt = 0; flags = 0
    }
}

extension ServiceEntry {
    public var isActive: Bool { pid > 0 && nameString.first != nil }

    public var nameString: String { tupleString(name) }
    public var controlChannelString: String { tupleString(controlChannel) }
    public var replyChannelString: String { tupleString(replyChannel) }

    public var isAlive: Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno != ESRCH
    }

    mutating func fill(name: String, ctrl: String, reply: String, pid: Int32) {
        self = ServiceEntry()
        writeTuple(&self.name, from: name)
        writeTuple(&self.controlChannel, from: ctrl)
        writeTuple(&self.replyChannel, from: reply)
        self.pid = pid
        self.registeredAt = Int64(Darwin.time(nil))
    }
}

// MARK: - RegistryData (SHM layout)

private struct RegistryData {
    var spinlock: Int32 = 0
    var count: UInt32 = 0
    var entries: (
        ServiceEntry, ServiceEntry, ServiceEntry, ServiceEntry,
        ServiceEntry, ServiceEntry, ServiceEntry, ServiceEntry,
        ServiceEntry, ServiceEntry, ServiceEntry, ServiceEntry,
        ServiceEntry, ServiceEntry, ServiceEntry, ServiceEntry,
        ServiceEntry, ServiceEntry, ServiceEntry, ServiceEntry,
        ServiceEntry, ServiceEntry, ServiceEntry, ServiceEntry,
        ServiceEntry, ServiceEntry, ServiceEntry, ServiceEntry,
        ServiceEntry, ServiceEntry, ServiceEntry, ServiceEntry
    ) = (
        ServiceEntry(), ServiceEntry(), ServiceEntry(), ServiceEntry(),
        ServiceEntry(), ServiceEntry(), ServiceEntry(), ServiceEntry(),
        ServiceEntry(), ServiceEntry(), ServiceEntry(), ServiceEntry(),
        ServiceEntry(), ServiceEntry(), ServiceEntry(), ServiceEntry(),
        ServiceEntry(), ServiceEntry(), ServiceEntry(), ServiceEntry(),
        ServiceEntry(), ServiceEntry(), ServiceEntry(), ServiceEntry(),
        ServiceEntry(), ServiceEntry(), ServiceEntry(), ServiceEntry(),
        ServiceEntry(), ServiceEntry(), ServiceEntry(), ServiceEntry()
    )
}

// MARK: - ServiceRegistry

/// Service registry backed by a well-known shared memory segment.
///
/// Any process that opens a `ServiceRegistry` with the same domain sees the
/// same set of registered services.
///
/// Port of `ipc::proto::service_registry`.
public final class ServiceRegistry: @unchecked Sendable {

    private let shm: ShmHandle
    private let data: UnsafeMutablePointer<RegistryData>

    private static func shmName(domain: String) -> String {
        domain.isEmpty ? "__ipc_registry__default" : "__ipc_registry__\(domain)"
    }

    /// Open or create the registry for `domain` (empty string = default).
    public static func open(domain: String = "") throws(IpcError) -> ServiceRegistry {
        let name = shmName(domain: domain)
        var shm = try ShmHandle.acquire(name: name, size: MemoryLayout<RegistryData>.size, mode: .createOrOpen)
        let isFirst = shm.previousRefCount == 0
        let reg = ServiceRegistry(shm: consume shm)
        if isFirst { reg.forceReset() }
        return reg
    }

    private init(shm: consuming ShmHandle) {
        let ptr = shm.ptr.assumingMemoryBound(to: RegistryData.self)
        self.shm = shm
        self.data = ptr
    }

    // MARK: - Register / Unregister

    /// Register a service under the calling process's PID. Returns `true` on success.
    @discardableResult
    public func register(name: String, controlChannel: String, replyChannel: String) -> Bool {
        register(name: name, controlChannel: controlChannel, replyChannel: replyChannel, pid: getpid())
    }

    /// Register with an explicit PID (useful for testing).
    @discardableResult
    public func register(name: String, controlChannel: String, replyChannel: String, pid: Int32) -> Bool {
        guard !name.isEmpty else { return false }
        lock()
        defer { unlock() }
        return withEntries { entries in
            for i in 0..<maxServices {
                if entries[i].isActive && entries[i].nameString == name {
                    if entries[i].isAlive { return false }
                    entries[i].fill(name: name, ctrl: controlChannel, reply: replyChannel, pid: pid)
                    return true
                }
            }
            for i in 0..<maxServices {
                if !entries[i].isActive || !entries[i].isAlive {
                    entries[i].fill(name: name, ctrl: controlChannel, reply: replyChannel, pid: pid)
                    return true
                }
            }
            return false
        }
    }

    /// Unregister a service by name. Only the owning PID can unregister.
    @discardableResult
    public func unregister(name: String) -> Bool {
        unregister(name: name, pid: getpid())
    }

    @discardableResult
    public func unregister(name: String, pid: Int32) -> Bool {
        lock()
        defer { unlock() }
        return withEntries { entries in
            for i in 0..<maxServices {
                if entries[i].isActive && entries[i].nameString == name && entries[i].pid == pid {
                    entries[i] = ServiceEntry()
                    return true
                }
            }
            return false
        }
    }

    // MARK: - Lookup

    /// Look up a service by exact name. Returns a copy if found and alive.
    public func find(name: String) -> ServiceEntry? {
        lock()
        defer { unlock() }
        return withEntries { entries in
            for i in 0..<maxServices {
                if entries[i].isActive && entries[i].nameString == name {
                    if !entries[i].isAlive { entries[i] = ServiceEntry(); continue }
                    return entries[i]
                }
            }
            return nil
        }
    }

    /// Find all live entries whose name starts with `prefix`.
    public func findAll(prefix: String) -> [ServiceEntry] {
        lock()
        defer { unlock() }
        return withEntries { entries in
            var result: [ServiceEntry] = []
            for i in 0..<maxServices {
                guard entries[i].isActive else { continue }
                if !entries[i].isAlive { entries[i] = ServiceEntry(); continue }
                if entries[i].nameString.hasPrefix(prefix) { result.append(entries[i]) }
            }
            return result
        }
    }

    /// List all live services.
    public func list() -> [ServiceEntry] {
        lock()
        defer { unlock() }
        return withEntries { entries in
            var result: [ServiceEntry] = []
            for i in 0..<maxServices {
                guard entries[i].isActive else { continue }
                if !entries[i].isAlive { entries[i] = ServiceEntry(); continue }
                result.append(entries[i])
            }
            return result
        }
    }

    /// Remove all entries for dead processes. Returns count removed.
    @discardableResult
    public func gc() -> Int {
        lock()
        defer { unlock() }
        return withEntries { entries in
            var removed = 0
            for i in 0..<maxServices {
                if entries[i].isActive && !entries[i].isAlive {
                    entries[i] = ServiceEntry()
                    removed += 1
                }
            }
            return removed
        }
    }

    /// Unlink the SHM backing store for a domain (call after all handles are closed).
    public static func destroyStorage(domain: String = "") {
        ShmHandle.clearStorage(name: shmName(domain: domain))
    }

    /// Clear the entire registry (force-resets spinlock first).
    public func clear() {
        forceReset()
        withEntries { entries in
            for i in 0..<maxServices { entries[i] = ServiceEntry() }
        }
    }

    // MARK: - Private helpers

    /// Force-reset the spinlock to 0 (use only when no other holder can exist).
    private func forceReset() {
        data.pointee.spinlock = 0
    }

    private func lock() {
        while !OSAtomicCompareAndSwap32(0, 1, &data.pointee.spinlock) {
            sched_yield()
        }
    }

    private func unlock() {
        OSAtomicCompareAndSwap32(1, 0, &data.pointee.spinlock)
    }

    @discardableResult
    private func withEntries<R>(_ body: (UnsafeMutableBufferPointer<ServiceEntry>) -> R) -> R {
        let offset = MemoryLayout<RegistryData>.offset(of: \RegistryData.entries)!
        let ptr = UnsafeMutableRawPointer(data).advanced(by: offset)
            .assumingMemoryBound(to: ServiceEntry.self)
        let buf = UnsafeMutableBufferPointer(start: ptr, count: maxServices)
        return body(buf)
    }
}

// MARK: - String helpers for fixed-size byte tuples

private func tupleString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let bytes = raw.prefix(while: { $0 != 0 })
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}

private func writeTuple<T>(_ tuple: inout T, from string: String) {
    let bytes = Array(string.utf8.prefix(maxNameLen - 1))
    withUnsafeMutableBytes(of: &tuple) { dst in
        for (i, b) in bytes.enumerated() { dst[i] = b }
        if bytes.count < dst.count { dst[bytes.count] = 0 }
    }
}
