// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include "libipc/proto/codecs/capnp_codec.h"
#include "libipc/proto/typed_route_codec.h"

namespace ipc {
namespace proto {

template <capnp_wire_message T>
using typed_route_capnp = typed_route_codec<T, capnp_codec>;

} // namespace proto
} // namespace ipc
