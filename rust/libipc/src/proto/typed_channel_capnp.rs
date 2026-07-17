// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Typed Cap'n Proto wrapper around the generic codec-based Channel wrapper.

use super::codecs::capnp::CapnpCodec;
use super::typed_channel_codec::TypedChannelCodec;

pub type TypedChannelCapnp<T> = TypedChannelCodec<T, CapnpCodec>;
