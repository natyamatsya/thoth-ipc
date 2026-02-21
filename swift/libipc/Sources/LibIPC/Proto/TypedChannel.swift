// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/include/libipc/proto/typed_channel.h.
// Typed FlatBuffer wrapper around Channel.

import FlatBuffers

/// A typed wrapper around `Channel` for FlatBuffer messages.
///
/// `T` is the FlatBuffers-generated root table type.
/// `Channel` is multi-writer, multiple-reader (broadcast).
///
/// Port of `ipc::proto::typed_channel<T>`.
public final class TypedChannel<T: FlatBufferTable & Verifiable>: @unchecked Sendable {

    private let channel: Channel

    // MARK: Connect

    public static func connect(name: String, mode: Mode) async throws(IpcError) -> TypedChannel<T> {
        TypedChannel(channel: try await Channel.connect(name: name, mode: mode))
    }

    public static func connect(prefix: String, name: String, mode: Mode) async throws(IpcError) -> TypedChannel<T> {
        TypedChannel(channel: try await Channel.connect(prefix: prefix, name: name, mode: mode))
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

    /// Send a finished `Builder` payload.
    public func send(builder: Builder, timeout: Duration = .seconds(200)) throws(IpcError) -> Bool {
        try channel.send(data: builder.bytes, timeout: timeout)
    }

    /// Send raw bytes (already a finished FlatBuffer).
    public func send(data: [UInt8], timeout: Duration = .seconds(200)) throws(IpcError) -> Bool {
        try channel.send(data: data, timeout: timeout)
    }

    // MARK: Recv

    /// Receive a typed message. Returns an empty `Message` on timeout.
    public func recv(timeout: Duration? = nil) throws(IpcError) -> Message<T> {
        Message(buffer: try channel.recv(timeout: timeout))
    }

    /// Try receiving without blocking.
    public func tryRecv() throws(IpcError) -> Message<T> {
        Message(buffer: try channel.tryRecv())
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
