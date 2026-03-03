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
class typed_route_codec {
    ipc::route rt_;

public:
    using codec_type = Codec;
    using builder_type = typename codec_type::builder_type;
    using message_type = typename codec_type::template message_type<T>;

    typed_route_codec() = default;

    typed_route_codec(char const *name, unsigned mode)
        : rt_{name, mode} {}

    void connect(char const *name, unsigned mode) {
        rt_ = ipc::route{name, mode};
    }

    void disconnect() { rt_.disconnect(); }
    bool valid() const noexcept { return rt_.valid(); }

    bool send(const builder_type &b) {
        return rt_.send(codec_type::data(b), codec_type::size(b));
    }

    bool send(const uint8_t *data, std::size_t size) {
        return rt_.send(data, size);
    }

    message_type recv(std::uint64_t tm = ipc::invalid_value) {
        return codec_type::template decode<T>(rt_.recv(tm));
    }

    message_type try_recv() {
        return codec_type::template decode<T>(rt_.try_recv());
    }

    ipc::route &raw() noexcept { return rt_; }
    const ipc::route &raw() const noexcept { return rt_; }

    static void clear_storage(char const *name) {
        ipc::route::clear_storage(name);
    }
};

} // namespace proto
} // namespace ipc
