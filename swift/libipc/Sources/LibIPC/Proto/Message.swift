// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/include/libipc/proto/message.h.
// Typed FlatBuffer message wrapper and builder over IpcBuffer.

import FlatBuffers

// MARK: - Message<T>

/// A received FlatBuffer message with typed access.
///
/// `T` must be a FlatBuffers-generated table type conforming to
/// `FlatBufferTable & Verifiable`.
///
/// The buffer is owned; access to the root is a zero-copy pointer cast
/// into the underlying `ByteBuffer`.
///
/// Port of `ipc::proto::message<T>`.
public struct Message<T: FlatBufferTable & Verifiable>: Sendable {

    public let buffer: IpcBuffer

    public init(buffer: IpcBuffer) { self.buffer = buffer }

    public static func empty() -> Message<T> { Message(buffer: IpcBuffer()) }

    public var isEmpty: Bool { buffer.isEmpty }
    public var count: Int   { buffer.count }

    /// Verify FlatBuffer integrity. Call on untrusted data before accessing `root`.
    public func verify(fileId: String? = nil) -> Bool {
        guard !buffer.isEmpty else { return false }
        var bb = ByteBuffer(bytes: buffer.bytes)
        return (try? getCheckedRoot(byteBuffer: &bb, fileId: fileId) as T) != nil
    }

    /// Zero-copy access to the decoded root table.
    /// Returns `nil` if the buffer is empty.
    public func root(fileId: String? = nil) -> T? {
        guard !buffer.isEmpty else { return nil }
        var bb = ByteBuffer(bytes: buffer.bytes)
        return try? getCheckedRoot(byteBuffer: &bb, fileId: fileId)
    }

    /// Unchecked root access — faster, no verification.
    public func rootUnchecked() -> T? {
        guard !buffer.isEmpty else { return nil }
        var bb = ByteBuffer(bytes: buffer.bytes)
        return getRoot(byteBuffer: &bb)
    }
}

// MARK: - Builder

/// Helper for building a FlatBuffer message to send over a channel.
///
/// Usage:
/// ```swift
/// var b = Builder(initialSize: 256)
/// let name = b.fbb.create(string: "hello")
/// let msg = MyTable.createMyTable(&b.fbb, nameOffset: name)
/// b.finish(msg)
/// try channel.send(buffer: b.ipcBuffer)
/// ```
///
/// Port of `ipc::proto::builder`.
public struct Builder {

    public var fbb: FlatBufferBuilder
    private var _finished: Bool = false

    public init(initialSize: Int = 1024) {
        fbb = FlatBufferBuilder(initialSize: Int32(initialSize))
    }

    /// Finish the buffer with the given root offset.
    public mutating func finish(_ root: Offset) {
        fbb.finish(offset: root)
        _finished = true
    }

    /// Finish with a 4-byte file identifier.
    public mutating func finish(_ root: Offset, fileId: String) {
        fbb.finish(offset: root, fileId: fileId)
        _finished = true
    }

    /// The finished bytes as an `IpcBuffer`. Empty if not yet finished.
    public var ipcBuffer: IpcBuffer {
        guard _finished else { return IpcBuffer() }
        let data = fbb.sizedByteArray
        return IpcBuffer(bytes: data)
    }

    /// The finished bytes as a raw array. Empty if not yet finished.
    public var bytes: [UInt8] {
        guard _finished else { return [] }
        return fbb.sizedByteArray
    }

    /// Reset the builder for reuse.
    public mutating func clear() {
        fbb.clear()
        _finished = false
    }
}
