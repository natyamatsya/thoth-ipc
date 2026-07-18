// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors

#pragma once

#include "thoth-ipc/proto/codecs/capnp_codec.h"
#include "thoth-ipc/proto/typed_route_codec.h"

namespace thoth {
namespace proto {

template <capnp_wire_message T>
using typed_route_capnp = typed_route_codec<T, capnp_codec>;

} // namespace proto
} // namespace thoth
