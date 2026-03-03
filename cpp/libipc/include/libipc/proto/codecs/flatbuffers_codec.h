// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <cstddef>
#include <cstdint>
#include <utility>

#include "libipc/proto/codec.h"
#include "libipc/proto/message.h"

namespace ipc {
namespace proto {

struct flatbuffers_codec {
    static constexpr codec_id id = codec_id::flatbuffers;

    using builder_type = builder;

    template <typename T>
    using message_type = message<T>;

    template <typename T>
    static message_type<T> decode(ipc::buff_t buf) {
        return message_type<T>{std::move(buf)};
    }

    static const uint8_t *data(const builder_type &b) noexcept { return b.data(); }
    static std::size_t size(const builder_type &b) noexcept { return b.size(); }
};

} // namespace proto
} // namespace ipc
