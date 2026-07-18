// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors

#pragma once

#include "thoth-ipc/proto/codecs/secure_codec.h"
#include "thoth-ipc/proto/typed_channel_codec.h"

namespace ipc {
namespace proto {

template <typename T, typename InnerCodec, secure_cipher Cipher>
using typed_channel_secure =
    typed_channel_codec<T, secure_codec<InnerCodec, Cipher>>;

} // namespace proto
} // namespace ipc
