// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/include/libipc/proto/typed_route.h.
// Typed FlatBuffer wrapper around Route.

import FlatBuffers

/// A typed wrapper around `Route` for FlatBuffer messages.
///
/// `T` is the FlatBuffers-generated root table type.
/// `Route` is single-writer, multiple-reader (broadcast).
///
/// Port of `ipc::proto::typed_route<T>`.
public final class TypedRoute<T: FlatBufferTable & Verifiable>: @unchecked Sendable {

    private let route: Route

    // MARK: Connect

    public static func connect(name: String, mode: Mode) async throws(IpcError) -> TypedRoute<T> {
        TypedRoute(route: try await Route.connect(name: name, mode: mode))
    }

    public static func connect(prefix: String, name: String, mode: Mode) async throws(IpcError) -> TypedRoute<T> {
        TypedRoute(route: try await Route.connect(prefix: prefix, name: name, mode: mode))
    }

    private init(route: Route) { self.route = route }

    // MARK: Properties

    public var name: String   { route.name }
    public var mode: Mode     { route.mode }
    public var valid: Bool    { route.valid }
    public var recvCount: Int { route.recvCount }

    // MARK: Lifecycle

    public func disconnect() { route.disconnect() }

    // MARK: Send

    /// Send a finished `Builder` payload.
    public func send(builder: Builder, timeout: Duration = .seconds(200)) throws(IpcError) -> Bool {
        try route.send(data: builder.bytes, timeout: timeout)
    }

    /// Send raw bytes (already a finished FlatBuffer).
    public func send(data: [UInt8], timeout: Duration = .seconds(200)) throws(IpcError) -> Bool {
        try route.send(data: data, timeout: timeout)
    }

    // MARK: Recv

    /// Receive a typed message. Returns an empty `Message` on timeout.
    public func recv(timeout: Duration? = nil) throws(IpcError) -> Message<T> {
        Message(buffer: try route.recv(timeout: timeout))
    }

    /// Try receiving without blocking.
    public func tryRecv() throws(IpcError) -> Message<T> {
        Message(buffer: try route.tryRecv())
    }

    public func waitForRecv(count: Int, timeout: Duration? = nil) throws(IpcError) -> Bool {
        try route.waitForRecv(count: count, timeout: timeout)
    }

    // MARK: Storage

    public func clear() async { await route.clear() }
    public static func clearStorage(name: String) async { await Route.clearStorage(name: name) }
    public static func clearStorage(prefix: String, name: String) async {
        await Route.clearStorage(prefix: prefix, name: name)
    }
}
