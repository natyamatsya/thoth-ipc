// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <concepts>

#include "libipc/proto/codecs/protobuf_codec.h"

#if __has_include(<google/protobuf/message_lite.h>)

#include <google/protobuf/message_lite.h>

#include "libipc/proto/typed_channel_codec.h"
#include "libipc/proto/typed_route_codec.h"

namespace ipc {
namespace proto {

template <typename T>
concept google_message_lite = std::derived_from<T, ::google::protobuf::MessageLite>;

template <google_message_lite T>
using typed_channel_protobuf_lite = typed_channel_codec<T, protobuf_codec>;

template <google_message_lite T>
using typed_route_protobuf_lite = typed_route_codec<T, protobuf_codec>;

template <google_message_lite T>
protobuf_builder protobuf_builder_from_message_lite(const T &message) {
    return protobuf_builder::from_message(message);
}

} // namespace proto
} // namespace ipc

#endif // __has_include(<google/protobuf/message_lite.h>)
