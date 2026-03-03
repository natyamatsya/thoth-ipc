// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Generic typed wrapper around Route using a pluggable codec.

public final class TypedRouteCodec<T, C: TypedCodec>: @unchecked Sendable where C.Root == T {

    private let route: Route

    // MARK: Connect

    public static func connect(name: String, mode: Mode) async throws(IpcError) -> TypedRouteCodec<T, C> {
        TypedRouteCodec(route: try await Route.connect(name: name, mode: mode))
    }

    public static func connect(prefix: String, name: String, mode: Mode) async throws(IpcError) -> TypedRouteCodec<T, C> {
        TypedRouteCodec(route: try await Route.connect(prefix: prefix, name: name, mode: mode))
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

    /// Send a codec-specific builder payload.
    public func send(builder: C.BuilderType, timeout: Duration = .seconds(200)) throws(IpcError) -> Bool {
        try route.send(data: C.encode(builder: builder), timeout: timeout)
    }

    /// Send raw bytes (already encoded payload).
    public func send(data: [UInt8], timeout: Duration = .seconds(200)) throws(IpcError) -> Bool {
        try route.send(data: data, timeout: timeout)
    }

    // MARK: Recv

    /// Receive a typed message. Returns an empty codec message on timeout.
    public func recv(timeout: Duration? = nil) throws(IpcError) -> C.MessageType {
        C.decode(buffer: try route.recv(timeout: timeout))
    }

    /// Try receiving without blocking.
    public func tryRecv() throws(IpcError) -> C.MessageType {
        C.decode(buffer: try route.tryRecv())
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
