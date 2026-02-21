// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/include/libipc/buffer.h + buffer.cpp.
// An owning byte buffer used as the message type for IPC channels.

/// An owning byte buffer for IPC message data.
///
/// Mirrors `ipc::buffer` / Rust `IpcBuffer`.
/// Messages sent through `Route` or `Channel` are serialised into
/// `IpcBuffer` for transmission and deserialised back on the receiver side.
public struct IpcBuffer: Sendable {
    public private(set) var bytes: [UInt8]

    // MARK: Init

    public init() {
        bytes = []
    }

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public init(slice: some Collection<UInt8>) {
        bytes = Array(slice)
    }

    /// Create a buffer from a UTF-8 string, appending a null terminator for C++ compat.
    public init(string: String) {
        var v = Array(string.utf8)
        v.append(0)
        bytes = v
    }

    // MARK: Properties

    public var isEmpty: Bool { bytes.isEmpty }
    public var count: Int { bytes.count }

    // MARK: Mutation

    public mutating func swap(with other: inout IpcBuffer) {
        Swift.swap(&bytes, &other.bytes)
    }
}

extension IpcBuffer: Equatable {
    public static func == (lhs: IpcBuffer, rhs: IpcBuffer) -> Bool {
        lhs.bytes == rhs.bytes
    }
}

extension IpcBuffer: CustomDebugStringConvertible {
    public var debugDescription: String { "IpcBuffer(count: \(bytes.count))" }
}
