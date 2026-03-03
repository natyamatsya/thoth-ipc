// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Generic typed wrapper around Channel using a pluggable codec.

public final class TypedChannelCodec<T, C: TypedCodec>: @unchecked Sendable where C.Root == T {

    private let channel: Channel

    // MARK: Connect

    public static func connect(name: String, mode: Mode) async throws(IpcError) -> TypedChannelCodec<T, C> {
        TypedChannelCodec(channel: try await Channel.connect(name: name, mode: mode))
    }

    public static func connect(prefix: String, name: String, mode: Mode) async throws(IpcError) -> TypedChannelCodec<T, C> {
        TypedChannelCodec(channel: try await Channel.connect(prefix: prefix, name: name, mode: mode))
    }

    private init(channel: Channel) { self.channel = channel }

    // MARK: Properties

    public var name: String   { channel.name }
    public var mode: Mode     { channel.mode }
    public var valid: Bool    { channel.valid }
    public var recvCount: Int { channel.recvCount }

    // MARK: Lifecycle

    public func disconnect() { channel.disconnect() }

    // MARK: Send

    /// Send a codec-specific builder payload.
    public func send(builder: C.BuilderType, timeout: Duration = .seconds(200)) throws(IpcError) -> Bool {
        try channel.send(data: C.encode(builder: builder), timeout: timeout)
    }

    /// Send raw bytes (already encoded payload).
    public func send(data: [UInt8], timeout: Duration = .seconds(200)) throws(IpcError) -> Bool {
        try channel.send(data: data, timeout: timeout)
    }

    // MARK: Recv

    /// Receive a typed message. Returns an empty codec message on timeout.
    public func recv(timeout: Duration? = nil) throws(IpcError) -> C.MessageType {
        C.decode(buffer: try channel.recv(timeout: timeout))
    }

    /// Try receiving without blocking.
    public func tryRecv() throws(IpcError) -> C.MessageType {
        C.decode(buffer: try channel.tryRecv())
    }

    public func waitForRecv(count: Int, timeout: Duration? = nil) throws(IpcError) -> Bool {
        try channel.waitForRecv(count: count, timeout: timeout)
    }

    // MARK: Storage

    public func clear() async { await channel.clear() }
    public static func clearStorage(name: String) async { await Channel.clearStorage(name: name) }
    public static func clearStorage(prefix: String, name: String) async {
        await Channel.clearStorage(prefix: prefix, name: name)
    }
}
