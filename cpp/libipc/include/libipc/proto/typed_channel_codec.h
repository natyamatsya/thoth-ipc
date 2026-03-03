// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <cstddef>
#include <cstdint>

#include "libipc/ipc.h"
#include "libipc/proto/codec.h"

namespace ipc {
namespace proto {

template <typename T, typename Codec>
    requires proto_codec<Codec, T>
class typed_channel_codec {
    ipc::channel ch_;

public:
    using codec_type = Codec;
    using builder_type = typename codec_type::builder_type;
    using message_type = typename codec_type::template message_type<T>;

    typed_channel_codec() = default;

    typed_channel_codec(char const *name, unsigned mode)
        : ch_{name, mode} {}

    void connect(char const *name, unsigned mode) {
        ch_ = ipc::channel{name, mode};
    }

    void disconnect() { ch_.disconnect(); }
    bool valid() const noexcept { return ch_.valid(); }

    bool send(const builder_type &b) {
        return ch_.send(codec_type::data(b), codec_type::size(b));
    }

    bool send(const uint8_t *data, std::size_t size) {
        return ch_.send(data, size);
    }

    message_type recv(std::uint64_t tm = ipc::invalid_value) {
        return codec_type::template decode<T>(ch_.recv(tm));
    }

    message_type try_recv() {
        return codec_type::template decode<T>(ch_.try_recv());
    }

    ipc::channel &raw() noexcept { return ch_; }
    const ipc::channel &raw() const noexcept { return ch_; }

    static void clear_storage(char const *name) {
        ipc::channel::clear_storage(name);
    }
};

} // namespace proto
} // namespace ipc
