// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <utility>
#include <vector>

#include "libipc/proto/codec.h"

namespace ipc {
namespace proto {

class protobuf_builder {
    std::vector<std::uint8_t> bytes_;

public:
    protobuf_builder() = default;

    explicit protobuf_builder(std::vector<std::uint8_t> bytes)
        : bytes_{std::move(bytes)} {}

    template <typename T>
    static protobuf_builder from_message(const T &message) {
        const auto size = message.ByteSizeLong();
        if (size > static_cast<std::size_t>((std::numeric_limits<int>::max)())) return {};

        std::vector<std::uint8_t> bytes(size);
        if (size > 0 && !message.SerializeToArray(bytes.data(), static_cast<int>(size))) return {};
        return protobuf_builder{std::move(bytes)};
    }

    const std::uint8_t *data() const noexcept { return bytes_.data(); }
    std::size_t size() const noexcept { return bytes_.size(); }

    const std::vector<std::uint8_t> &bytes() const noexcept { return bytes_; }
};

template <typename T>
class protobuf_message {
    ipc::buff_t buf_;
    T value_ {};
    bool valid_ {false};

public:
    protobuf_message() = default;

    explicit protobuf_message(ipc::buff_t buf)
        : buf_{std::move(buf)} {
        if (buf_.empty()) return;
        if (buf_.size() > static_cast<std::size_t>((std::numeric_limits<int>::max)())) return;
        valid_ = value_.ParseFromArray(buf_.data(), static_cast<int>(buf_.size()));
    }

    explicit operator bool() const noexcept { return valid_; }
    bool empty() const noexcept { return buf_.empty(); }

    const T *root() const noexcept {
        if (!valid_) return nullptr;
        return &value_;
    }

    const T *operator->() const noexcept { return root(); }

    const T &operator*() const {
        assert(valid_);
        return value_;
    }

    bool verify() const noexcept { return valid_; }

    const void *data() const noexcept { return buf_.data(); }
    std::size_t size() const noexcept { return buf_.size(); }
};

struct protobuf_codec {
    static constexpr codec_id id = codec_id::protobuf;

    using builder_type = protobuf_builder;

    template <typename T>
    using message_type = protobuf_message<T>;

    template <typename T>
    static message_type<T> decode(ipc::buff_t buf) {
        return message_type<T>{std::move(buf)};
    }

    static const std::uint8_t *data(const builder_type &b) noexcept { return b.data(); }
    static std::size_t size(const builder_type &b) noexcept { return b.size(); }
};

} // namespace proto
} // namespace ipc
