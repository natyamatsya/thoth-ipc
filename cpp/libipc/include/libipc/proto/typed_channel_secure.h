// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include "libipc/proto/codecs/secure_codec.h"
#include "libipc/proto/typed_channel_codec.h"

namespace ipc {
namespace proto {

template <typename T, typename InnerCodec, secure_cipher Cipher>
using typed_channel_secure =
    typed_channel_codec<T, secure_codec<InnerCodec, Cipher>>;

} // namespace proto
} // namespace ipc
