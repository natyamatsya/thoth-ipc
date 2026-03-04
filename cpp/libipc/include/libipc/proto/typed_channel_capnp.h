// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include "libipc/proto/codecs/capnp_codec.h"
#include "libipc/proto/typed_channel_codec.h"

namespace ipc {
namespace proto {

template <capnp_wire_message T>
using typed_channel_capnp = typed_channel_codec<T, capnp_codec>;

} // namespace proto
} // namespace ipc
