// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Typed Cap'n Proto wrapper around the generic codec-based Channel wrapper.

use super::codecs::capnp::CapnpCodec;
use super::typed_channel_codec::TypedChannelCodec;

pub type TypedChannelCapnp<T> = TypedChannelCodec<T, CapnpCodec>;
