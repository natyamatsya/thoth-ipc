// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Typed FlatBuffer wrapper around the generic codec-based Channel wrapper.
// Port of cpp-ipc/include/thoth_ipc/proto/typed_channel.h.

use super::codecs::flatbuffers::FlatBuffersCodec;
use super::typed_channel_codec::TypedChannelCodec;

/// A typed wrapper around [`crate::channel::Channel`] for FlatBuffer messages.
///
/// `T` is the FlatBuffers-generated root table type.
///
/// Port of `thoth::proto::typed_channel<T>` from the C++ thoth_ipc library.
pub type TypedChannel<T> = TypedChannelCodec<T, FlatBuffersCodec>;
