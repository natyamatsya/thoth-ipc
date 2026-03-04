// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <utility>
#include <vector>

#include "libipc/proto/codec.h"

namespace ipc {
namespace proto {

/// Minimal wire contract for Cap'n Proto-like message types.
///
/// This keeps the Phase C scaffolding independent from a concrete Cap'n Proto
/// runtime. Runtime adapters can bridge generated message types to this
/// contract.
template <typename T>
concept capnp_wire_message = requires(const T &message, const std::uint8_t *data,
                                      const std::size_t size) {
    { message.encode_capnp() } -> std::same_as<std::vector<std::uint8_t>>;
    { T::decode_capnp(data, size) } -> std::same_as<std::optional<T>>;
};

/// Encoded Cap'n Proto payload for transport.
class capnp_builder {
    std::vector<std::uint8_t> bytes_;

public:
    capnp_builder() = default;

    explicit capnp_builder(std::vector<std::uint8_t> bytes)
        : bytes_{std::move(bytes)} {}

    template <capnp_wire_message T>
    static capnp_builder from_message(const T &message) {
        return capnp_builder{message.encode_capnp()};
    }

    const std::uint8_t *data() const noexcept { return bytes_.data(); }
    std::size_t size() const noexcept { return bytes_.size(); }

    const std::vector<std::uint8_t> &bytes() const noexcept { return bytes_; }
};

/// Decoded Cap'n Proto message wrapper with access to the raw transport buffer.
template <capnp_wire_message T>
class capnp_message {
    ipc::buff_t buf_;
    std::optional<T> value_;

public:
    capnp_message() = default;

    explicit capnp_message(ipc::buff_t buf)
        : buf_{std::move(buf)} {
        if (buf_.empty()) return;

        auto *data = static_cast<const std::uint8_t *>(buf_.data());
        if (data == nullptr) return;

        value_ = T::decode_capnp(data, buf_.size());
    }

    explicit operator bool() const noexcept { return value_.has_value(); }
    bool empty() const noexcept { return buf_.empty(); }

    const T *root() const noexcept {
        if (!value_.has_value()) return nullptr;
        return &(*value_);
    }

    const T *operator->() const noexcept { return root(); }

    const T &operator*() const {
        assert(value_.has_value());
        return *value_;
    }

    bool verify() const noexcept { return value_.has_value(); }

    const void *data() const noexcept { return buf_.data(); }
    std::size_t size() const noexcept { return buf_.size(); }
};

struct capnp_codec {
    static constexpr codec_id id = codec_id::capnp;

    using builder_type = capnp_builder;

    template <capnp_wire_message T>
    using message_type = capnp_message<T>;

    template <capnp_wire_message T>
    static message_type<T> decode(ipc::buff_t buf) {
        return message_type<T>{std::move(buf)};
    }

    static const std::uint8_t *data(const builder_type &b) noexcept { return b.data(); }
    static std::size_t size(const builder_type &b) noexcept { return b.size(); }
};

} // namespace proto
} // namespace ipc
