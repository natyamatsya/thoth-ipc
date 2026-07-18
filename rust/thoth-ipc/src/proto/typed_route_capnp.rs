// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Typed Cap'n Proto wrapper around the generic codec-based Route wrapper.

use super::codecs::capnp::CapnpCodec;
use super::typed_route_codec::TypedRouteCodec;

pub type TypedRouteCapnp<T> = TypedRouteCodec<T, CapnpCodec>;
