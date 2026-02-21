// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// waitForRecv + clearStorage + Route + Channel public types.

import Darwin.POSIX

// MARK: - Async→sync bridge (no Foundation)

// Box used by runBlocking — must be at file scope (cannot nest class in generic function).
private final class _RunBlockingBox<V>: @unchecked Sendable {
    var value: V? = nil
    var error: (any Error)? = nil
    var mu   = pthread_mutex_t()
    var cond = pthread_cond_t()
    var done = false
    init() { pthread_mutex_init(&mu, nil); pthread_cond_init(&cond, nil) }
    deinit { pthread_mutex_destroy(&mu); pthread_cond_destroy(&cond) }
    // Wrappers so the async Task closure can call them without triggering
    // the "pthread_mutex_lock unavailable from async contexts" diagnostic.
    nonisolated func signal(value v: V) {
        pthread_mutex_lock(&mu); self.value = v; done = true
        pthread_cond_signal(&cond); pthread_mutex_unlock(&mu)
    }
    nonisolated func signal(error e: any Error) {
        pthread_mutex_lock(&mu); self.error = e; done = true
        pthread_cond_signal(&cond); pthread_mutex_unlock(&mu)
    }
}

/// Run an async throwing closure on the Swift concurrency runtime and block
/// the calling (POSIX) thread until it completes, returning the result.
/// Safe to call from any non-async context including pthread worker threads.
func runBlocking<T: Sendable>(_ body: @Sendable @escaping () async throws -> T) throws -> T {
    let box = _RunBlockingBox<T>()
    Task {
        do    { box.signal(value: try await body()) }
        catch { box.signal(error: error) }
    }
    pthread_mutex_lock(&box.mu)
    while !box.done { pthread_cond_wait(&box.cond, &box.mu) }
    pthread_mutex_unlock(&box.mu)
    if let e = box.error { throw e }
    return box.value!
}

// MARK: - clearStorage helper

/// Synchronous variant — only unlinks SHM segments, does not touch actor caches.
/// Safe to call from POSIX threads. Use when the caller knows no other process
/// holds the segment open (i.e. at benchmark teardown).
func clearStorageImplSync(prefix: String, name: String) {
    let fp = prefix.isEmpty ? "" : "\(prefix)_"
    ShmHandle.clearStorage(name: "\(fp)QU_CONN__\(name)")
    ShmHandle.clearStorage(name: "\(fp)CA_CONN__\(name)")
    ShmHandle.clearStorage(name: "\(fp)WT_CONN__\(name)_WAITER_COND_")
    ShmHandle.clearStorage(name: "\(fp)WT_CONN__\(name)_WAITER_LOCK_")
    ShmHandle.clearStorage(name: "\(fp)RD_CONN__\(name)_WAITER_COND_")
    ShmHandle.clearStorage(name: "\(fp)RD_CONN__\(name)_WAITER_LOCK_")
    ShmHandle.clearStorage(name: "\(fp)CC_CONN__\(name)_WAITER_COND_")
    ShmHandle.clearStorage(name: "\(fp)CC_CONN__\(name)_WAITER_LOCK_")
    let cp = "\(fp)\(name)_"
    for ps in [128, 256, 512, 1024, 2048, 4096, 8192, 16384, 65536] {
        clearChunkShm(prefix: cp, chunkSize: calcChunkSize(ps))
    }
}

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

    /// Blocking connect — safe to call from a POSIX thread (not from an async context).
    public static func connectBlocking(name: String, mode: Mode) -> Route {
        Route(inner: try! ChanInner.openSync(prefix: "", name: name, mode: mode))
    }
    /// Blocking clearStorage — safe to call from a POSIX thread.
    public static func clearStorageBlocking(name: String) {
        clearStorageImplSync(prefix: "", name: name)
    }
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

    /// Blocking connect — safe to call from a POSIX thread (not from an async context).
    public static func connectBlocking(name: String, mode: Mode) -> Channel {
        Channel(inner: try! ChanInner.openSync(prefix: "", name: name, mode: mode))
    }
    /// Blocking clearStorage — safe to call from a POSIX thread.
    public static func clearStorageBlocking(name: String) {
        clearStorageImplSync(prefix: "", name: name)
    }
}
