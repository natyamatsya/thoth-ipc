// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/include/libipc/proto/typed_channel.h.
// Typed FlatBuffer wrapper around the generic codec-based Channel wrapper.

import FlatBuffers

/// A typed wrapper around `Channel` for FlatBuffer messages.
///
/// `T` is the FlatBuffers-generated root table type.
///
/// Port of `ipc::proto::typed_channel<T>`.
public typealias TypedChannel<T: FlatBufferTable & Verifiable> = TypedChannelCodec<T, FlatBuffersCodec<T>>
