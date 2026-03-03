// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Typed FlatBuffer wrapper around the generic codec-based Route wrapper.
// Port of cpp-ipc/include/libipc/proto/typed_route.h.

use super::codecs::flatbuffers::FlatBuffersCodec;
use super::typed_route_codec::TypedRouteCodec;

/// A typed wrapper around [`crate::channel::Route`] for FlatBuffer messages.
///
/// `T` is the FlatBuffers-generated root table type.
///
/// Port of `ipc::proto::typed_route<T>` from the C++ libipc library.
pub type TypedRoute<T> = TypedRouteCodec<T, FlatBuffersCodec>;
