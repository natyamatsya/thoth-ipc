// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <utility>
#include <vector>

#include "libipc/proto/codec.h"

namespace ipc {
namespace proto {

// Cipher policy for secure_codec.
//
// The API is intentionally static so typed_channel_codec/typed_route_codec can
// stay stateless and fully compile-time. OFF-path users pay zero runtime cost.
template <typename Cipher>
concept secure_cipher = requires(const std::uint8_t *data, std::size_t size,
                                 std::vector<std::uint8_t> &out) {
    { Cipher::seal(data, size, out) } -> std::same_as<bool>;
    { Cipher::open(data, size, out) } -> std::same_as<bool>;
};

namespace detail {

inline constexpr std::uint8_t secure_envelope_magic[] {'S', 'I', 'P', 'C'};
inline constexpr std::uint8_t secure_envelope_version {1};
inline constexpr std::size_t secure_envelope_header_size {
    sizeof(secure_envelope_magic) + sizeof(secure_envelope_version)
};

inline void append_secure_envelope_header(std::vector<std::uint8_t> &out) {
    out.insert(out.end(),
               secure_envelope_magic,
               secure_envelope_magic + sizeof(secure_envelope_magic));
    out.push_back(secure_envelope_version);
}

inline bool has_secure_envelope_header(const std::uint8_t *data,
                                       std::size_t size) {
    if (data == nullptr) return false;
    if (size < secure_envelope_header_size) return false;
    if (std::memcmp(data,
                    secure_envelope_magic,
                    sizeof(secure_envelope_magic)) != 0) return false;
    return data[sizeof(secure_envelope_magic)] == secure_envelope_version;
}

inline ipc::buff_t owning_buffer_from_bytes(std::vector<std::uint8_t> bytes) {
    if (bytes.empty()) return {};

    auto *storage = new std::uint8_t[bytes.size()];
    std::memcpy(storage, bytes.data(), bytes.size());
    return {
        storage,
        bytes.size(),
        [](void *p, std::size_t) {
            delete[] static_cast<std::uint8_t *>(p);
        }
    };
}

} // namespace detail

template <typename InnerCodec, secure_cipher Cipher>
class secure_builder {
    std::vector<std::uint8_t> bytes_;

public:
    using inner_builder_type = typename InnerCodec::builder_type;

    secure_builder() = default;

    explicit secure_builder(const inner_builder_type &inner) {
        const auto *data = InnerCodec::data(inner);
        const auto size = InnerCodec::size(inner);

        if (size == 0) return;
        if (data == nullptr) return;

        std::vector<std::uint8_t> sealed;
        if (!Cipher::seal(data, size, sealed)) return;

        bytes_.reserve(detail::secure_envelope_header_size + sealed.size());
        detail::append_secure_envelope_header(bytes_);
        bytes_.insert(bytes_.end(), sealed.begin(), sealed.end());
    }

    explicit secure_builder(std::vector<std::uint8_t> bytes)
        : bytes_{std::move(bytes)} {}

    const std::uint8_t *data() const noexcept { return bytes_.data(); }
    std::size_t size() const noexcept { return bytes_.size(); }

    const std::vector<std::uint8_t> &bytes() const noexcept { return bytes_; }
};

template <typename InnerCodec, secure_cipher Cipher>
struct secure_codec {
    // Keep the inner codec id to avoid transport-level behavior changes.
    static constexpr codec_id id = InnerCodec::id;

    using builder_type = secure_builder<InnerCodec, Cipher>;

    template <typename T>
    using message_type = typename InnerCodec::template message_type<T>;

    template <typename T>
    static message_type<T> decode(ipc::buff_t buf) {
        if (buf.empty()) return {};

        auto *data = static_cast<const std::uint8_t *>(buf.data());
        if (!detail::has_secure_envelope_header(data, buf.size())) return {};

        const auto *sealed = data + detail::secure_envelope_header_size;
        const auto sealed_size = buf.size() - detail::secure_envelope_header_size;

        std::vector<std::uint8_t> plain;
        if (!Cipher::open(sealed, sealed_size, plain)) return {};
        return InnerCodec::template decode<T>(
            detail::owning_buffer_from_bytes(std::move(plain)));
    }

    static const std::uint8_t *data(const builder_type &b) noexcept {
        return b.data();
    }

    static std::size_t size(const builder_type &b) noexcept {
        return b.size();
    }
};

} // namespace proto
} // namespace ipc
