// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Port of cpp-ipc/include/libipc/proto/typed_route.h.
// Typed FlatBuffer wrapper around the generic codec-based Route wrapper.

import FlatBuffers

/// A typed wrapper around `Route` for FlatBuffer messages.
///
/// `T` is the FlatBuffers-generated root table type.
///
/// Port of `ipc::proto::typed_route<T>`.
public typealias TypedRoute<T: FlatBufferTable & Verifiable> = TypedRouteCodec<T, FlatBuffersCodec<T>>
