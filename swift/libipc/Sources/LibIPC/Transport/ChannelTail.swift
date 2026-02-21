// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// waitForRecv + clearStorage + Route + Channel public types.

import Darwin.POSIX

// MARK: - clearStorage helper

func clearStorageImpl(prefix: String, name: String) async {
    let fp = prefix.isEmpty ? "" : "\(prefix)_"
    ShmHandle.clearStorage(name: "\(fp)QU_CONN__\(name)")
    ShmHandle.clearStorage(name: "\(fp)CA_CONN__\(name)")
    await Waiter.clearStorage(name: "\(fp)WT_CONN__\(name)")
    await Waiter.clearStorage(name: "\(fp)RD_CONN__\(name)")
    await Waiter.clearStorage(name: "\(fp)CC_CONN__\(name)")
    let cp = "\(fp)\(name)_"
    for ps in [128, 256, 512, 1024, 2048, 4096, 8192, 16384, 65536] {
        clearChunkShm(prefix: cp, chunkSize: calcChunkSize(ps))
    }
}

// MARK: - Route

/// A single-producer, multi-consumer broadcast IPC channel.
/// Mirrors `ipc::route` / Rust `Route`.
public final class Route: @unchecked Sendable {
    private let inner: ChanInner

    public static func connect(name: String, mode: Mode) async throws(IpcError) -> Route {
        try await connect(prefix: "", name: name, mode: mode)
    }
    public static func connect(prefix: String, name: String, mode: Mode) async throws(IpcError) -> Route {
        Route(inner: try await ChanInner.open(prefix: prefix, name: name, mode: mode))
    }
    private init(inner: ChanInner) { self.inner = inner }

    public var name: String  { inner.name }
    public var mode: Mode    { inner.mode }
    public var valid: Bool   { inner.valid }
    public var recvCount: Int { inner.recvCount }

    public func disconnect() { inner.disconnect() }

    public func send(data: [UInt8], timeout: Duration = .seconds(200)) throws(IpcError) -> Bool {
        try inner.send(data: data, timeout: timeout)
    }
    public func send(buffer: IpcBuffer, timeout: Duration = .seconds(200)) throws(IpcError) -> Bool {
        try inner.send(data: buffer.bytes, timeout: timeout)
    }
    public func send(string: String, timeout: Duration = .seconds(200)) throws(IpcError) -> Bool {
        try inner.send(data: IpcBuffer(string: string).bytes, timeout: timeout)
    }
    public func trySend(data: [UInt8]) throws(IpcError) -> Bool {
        try inner.send(data: data, timeout: Duration.zero)
    }
    public func recv(timeout: Duration? = nil) throws(IpcError) -> IpcBuffer {
        try inner.recv(timeout: timeout)
    }
    public func tryRecv() throws(IpcError) -> IpcBuffer { try inner.tryRecv() }
    public func waitForRecv(count: Int, timeout: Duration? = nil) throws(IpcError) -> Bool {
        try inner.waitForRecv(count: count, timeout: timeout)
    }
    public func clear() async { inner.disconnect(); await clearStorageImpl(prefix: inner.prefix, name: inner.name) }
    public static func clearStorage(name: String) async { await clearStorageImpl(prefix: "", name: name) }
    public static func clearStorage(prefix: String, name: String) async { await clearStorageImpl(prefix: prefix, name: name) }
}

// MARK: - Channel

/// A multi-producer, multi-consumer broadcast IPC channel.
/// Mirrors `ipc::channel` / Rust `Channel`.
public final class Channel: @unchecked Sendable {
    private let inner: ChanInner

    public static func connect(name: String, mode: Mode) async throws(IpcError) -> Channel {
        try await connect(prefix: "", name: name, mode: mode)
    }
    public static func connect(prefix: String, name: String, mode: Mode) async throws(IpcError) -> Channel {
        Channel(inner: try await ChanInner.open(prefix: prefix, name: name, mode: mode))
    }
    private init(inner: ChanInner) { self.inner = inner }

    public var name: String  { inner.name }
    public var mode: Mode    { inner.mode }
    public var valid: Bool   { inner.valid }
    public var recvCount: Int { inner.recvCount }

    public func disconnect() { inner.disconnect() }

    public func send(data: [UInt8], timeout: Duration = .seconds(200)) throws(IpcError) -> Bool {
        try inner.send(data: data, timeout: timeout)
    }
    public func send(buffer: IpcBuffer, timeout: Duration = .seconds(200)) throws(IpcError) -> Bool {
        try inner.send(data: buffer.bytes, timeout: timeout)
    }
    public func send(string: String, timeout: Duration = .seconds(200)) throws(IpcError) -> Bool {
        try inner.send(data: IpcBuffer(string: string).bytes, timeout: timeout)
    }
    public func trySend(data: [UInt8]) throws(IpcError) -> Bool {
        try inner.send(data: data, timeout: Duration.zero)
    }
    public func recv(timeout: Duration? = nil) throws(IpcError) -> IpcBuffer {
        try inner.recv(timeout: timeout)
    }
    public func tryRecv() throws(IpcError) -> IpcBuffer { try inner.tryRecv() }
    public func waitForRecv(count: Int, timeout: Duration? = nil) throws(IpcError) -> Bool {
        try inner.waitForRecv(count: count, timeout: timeout)
    }
    public func clear() async { inner.disconnect(); await clearStorageImpl(prefix: inner.prefix, name: inner.name) }
    public static func clearStorage(name: String) async { await clearStorageImpl(prefix: "", name: name) }
    public static func clearStorage(prefix: String, name: String) async { await clearStorageImpl(prefix: prefix, name: name) }
}
