// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

import FlatBuffers

/// FlatBuffers codec adapter for generic typed protocol wrappers.
public enum FlatBuffersCodec<T: FlatBufferTable & Verifiable>: TypedCodec {
    public typealias Root = T
    public typealias MessageType = Message<T>
    public typealias BuilderType = Builder

    public static var codecId: CodecId { .flatBuffers }

    public static func encode(builder: Builder) -> [UInt8] {
        builder.bytes
    }

    public static func decode(buffer: IpcBuffer) -> Message<T> {
        Message(buffer: buffer)
    }

    public static func verify(message: Message<T>) -> Bool {
        message.verify()
    }
}
