// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

/// Wire-level codec identifiers for typed protocol wrappers.
public enum CodecId: UInt8, Sendable {
    case flatBuffers = 1
    case protobuf = 2
    case capnp = 3
}

/// Codec contract for typed protocol wrappers.
public protocol TypedCodec {
    associatedtype Root
    associatedtype MessageType
    associatedtype BuilderType

    static var codecId: CodecId { get }

    static func encode(builder: BuilderType) -> [UInt8]
    static func decode(buffer: IpcBuffer) -> MessageType
    static func verify(message: MessageType) -> Bool
}

public extension TypedCodec {
    static func verify(message _: MessageType) -> Bool { true }
}
