// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#if canImport(SwiftProtobuf)

import Foundation
import SwiftProtobuf

/// Default `ProtobufWireMessage` behavior for SwiftProtobuf-generated messages.
///
/// Usage:
/// ```swift
/// extension MySchema_MyMessage: ProtobufWireMessage {}
/// ```
public extension ProtobufWireMessage where Self: SwiftProtobuf.Message {
    init?(serializedBytes: [UInt8]) {
        guard let decoded = try? Self(serializedData: Data(serializedBytes)) else { return nil }
        self = decoded
    }

    func serializedBytes() -> [UInt8] {
        guard let data = try? serializedData() else { return [] }
        return Array(data)
    }
}

/// Decoded SwiftProtobuf message wrapper with access to raw transport bytes.
public struct SwiftProtobufMessage<T: SwiftProtobuf.Message> {
    public let buffer: IpcBuffer
    private let value: T?

    public init(buffer: IpcBuffer) {
        self.buffer = buffer
        value = try? T(serializedData: Data(buffer.bytes))
    }

    public var isEmpty: Bool { buffer.isEmpty }
    public var isValid: Bool { value != nil }

    public func root() -> T? {
        value
    }
}

/// SwiftProtobuf runtime codec adapter for typed protocol wrappers.
public enum SwiftProtobufCodec<T: SwiftProtobuf.Message>: TypedCodec {
    public typealias Root = T
    public typealias MessageType = SwiftProtobufMessage<T>
    public typealias BuilderType = T

    public static var codecId: CodecId { .protobuf }

    public static func encode(builder: T) -> [UInt8] {
        guard let data = try? builder.serializedData() else { return [] }
        return Array(data)
    }

    public static func decode(buffer: IpcBuffer) -> SwiftProtobufMessage<T> {
        SwiftProtobufMessage(buffer: buffer)
    }

    public static func verify(message: SwiftProtobufMessage<T>) -> Bool {
        message.isValid
    }
}

public typealias TypedChannelSwiftProtobuf<T: SwiftProtobuf.Message> = TypedChannelCodec<T, SwiftProtobufCodec<T>>
public typealias TypedRouteSwiftProtobuf<T: SwiftProtobuf.Message> = TypedRouteCodec<T, SwiftProtobufCodec<T>>

#endif
