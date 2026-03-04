// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

/// Minimal wire contract for protobuf-like message types.
///
/// This keeps the Phase B scaffolding independent from any specific Swift
/// protobuf runtime. Callers can conform generated message types via adapters.
public protocol ProtobufWireMessage: Sendable {
    init?(serializedBytes: [UInt8])
    func serializedBytes() -> [UInt8]
}

/// Encoded protobuf payload for transport.
public struct ProtobufBuilder: Sendable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public init(slice: some Collection<UInt8>) {
        bytes = Array(slice)
    }

    public init<T: ProtobufWireMessage>(message: T) {
        bytes = message.serializedBytes()
    }
}

/// Decoded protobuf message wrapper with access to the raw transport buffer.
public struct ProtobufMessage<T: ProtobufWireMessage>: Sendable {
    public let buffer: IpcBuffer
    private let value: T?

    public init(buffer: IpcBuffer) {
        self.buffer = buffer
        value = T(serializedBytes: buffer.bytes)
    }

    public static func empty() -> ProtobufMessage<T> {
        ProtobufMessage(buffer: IpcBuffer())
    }

    public var isEmpty: Bool { buffer.isEmpty }
    public var isValid: Bool { value != nil }

    public func root() -> T? {
        value
    }
}

/// Protocol Buffers codec adapter for generic typed protocol wrappers.
public enum ProtobufCodec<T: ProtobufWireMessage>: TypedCodec {
    public typealias Root = T
    public typealias MessageType = ProtobufMessage<T>
    public typealias BuilderType = ProtobufBuilder

    public static var codecId: CodecId { .protobuf }

    public static func encode(builder: ProtobufBuilder) -> [UInt8] {
        builder.bytes
    }

    public static func decode(buffer: IpcBuffer) -> ProtobufMessage<T> {
        ProtobufMessage(buffer: buffer)
    }

    public static func verify(message: ProtobufMessage<T>) -> Bool {
        message.isValid
    }
}
