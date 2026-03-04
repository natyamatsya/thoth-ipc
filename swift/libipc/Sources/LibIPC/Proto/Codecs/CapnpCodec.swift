// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

/// Minimal wire contract for Cap'n Proto-like message types.
///
/// This keeps Phase C scaffolding independent from any specific Swift Cap'n
/// Proto runtime. Callers can conform generated message adapters.
public protocol CapnpWireMessage: Sendable {
    init?(serializedBytes: [UInt8])
    func serializedBytes() -> [UInt8]
}

/// Encoded Cap'n Proto payload for transport.
public struct CapnpBuilder: Sendable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public init(slice: some Collection<UInt8>) {
        bytes = Array(slice)
    }

    public init<T: CapnpWireMessage>(message: T) {
        bytes = message.serializedBytes()
    }
}

/// Decoded Cap'n Proto message wrapper with access to the raw transport buffer.
public struct CapnpMessage<T: CapnpWireMessage>: Sendable {
    public let buffer: IpcBuffer
    private let value: T?

    public init(buffer: IpcBuffer) {
        self.buffer = buffer
        value = T(serializedBytes: buffer.bytes)
    }

    public static func empty() -> CapnpMessage<T> {
        CapnpMessage(buffer: IpcBuffer())
    }

    public var isEmpty: Bool { buffer.isEmpty }
    public var isValid: Bool { value != nil }

    public func root() -> T? {
        value
    }
}

/// Cap'n Proto codec adapter for generic typed protocol wrappers.
public enum CapnpCodec<T: CapnpWireMessage>: TypedCodec {
    public typealias Root = T
    public typealias MessageType = CapnpMessage<T>
    public typealias BuilderType = CapnpBuilder

    public static var codecId: CodecId { .capnp }

    public static func encode(builder: CapnpBuilder) -> [UInt8] {
        builder.bytes
    }

    public static func decode(buffer: IpcBuffer) -> CapnpMessage<T> {
        CapnpMessage(buffer: buffer)
    }

    public static func verify(message: CapnpMessage<T>) -> Bool {
        message.isValid
    }
}

public typealias TypedChannelCapnp<T: CapnpWireMessage> = TypedChannelCodec<T, CapnpCodec<T>>
public typealias TypedRouteCapnp<T: CapnpWireMessage> = TypedRouteCodec<T, CapnpCodec<T>>
