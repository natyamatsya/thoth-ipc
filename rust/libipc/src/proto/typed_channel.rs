// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Typed FlatBuffer wrapper around the generic codec-based Channel wrapper.
// Port of cpp-ipc/include/libipc/proto/typed_channel.h.

use super::codecs::flatbuffers::FlatBuffersCodec;
use super::typed_channel_codec::TypedChannelCodec;

/// A typed wrapper around [`crate::channel::Channel`] for FlatBuffer messages.
///
/// `T` is the FlatBuffers-generated root table type.
///
/// Port of `ipc::proto::typed_channel<T>` from the C++ libipc library.
pub type TypedChannel<T> = TypedChannelCodec<T, FlatBuffersCodec>;
