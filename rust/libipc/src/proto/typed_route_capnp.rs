// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Typed Cap'n Proto wrapper around the generic codec-based Route wrapper.

use super::codecs::capnp::CapnpCodec;
use super::typed_route_codec::TypedRouteCodec;

pub type TypedRouteCapnp<T> = TypedRouteCodec<T, CapnpCodec>;
