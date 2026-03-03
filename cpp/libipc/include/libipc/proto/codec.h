// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <concepts>
#include <cstddef>
#include <cstdint>
#include <utility>

#include "libipc/ipc.h"

namespace ipc {
namespace proto {

enum class codec_id : std::uint8_t {
    flatbuffers = 1,
    protobuf = 2,
    capnp = 3,
};

template <typename Codec, typename T>
concept proto_codec = requires(const typename Codec::builder_type &b, ipc::buff_t buf) {
    typename Codec::builder_type;
    typename Codec::template message_type<T>;
    { Codec::id } -> std::convertible_to<codec_id>;
    { Codec::template decode<T>(std::move(buf)) } -> std::same_as<typename Codec::template message_type<T>>;
    { Codec::data(b) } -> std::convertible_to<const uint8_t *>;
    { Codec::size(b) } -> std::convertible_to<std::size_t>;
};

} // namespace proto
} // namespace ipc
