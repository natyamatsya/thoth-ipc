// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <utility>
#include <vector>

#include "libipc/proto/codec.h"

namespace ipc {
namespace proto {

// AEAD cipher policy contract for envelope v1 (algorithm/key/nonce/tag aware).
template <typename Cipher>
concept secure_cipher_aead = requires(const std::uint8_t *plain_data,
                                      const std::size_t plain_size,
                                      const std::uint8_t *nonce_data,
                                      const std::size_t nonce_size,
                                      const std::uint8_t *cipher_data,
                                      const std::size_t cipher_size,
                                      const std::uint8_t *tag_data,
                                      const std::size_t tag_size,
                                      std::vector<std::uint8_t> &nonce,
                                      std::vector<std::uint8_t> &ciphertext,
                                      std::vector<std::uint8_t> &tag,
                                      std::vector<std::uint8_t> &plain) {
    { Cipher::algorithm_id() } -> std::convertible_to<std::uint16_t>;
    { Cipher::key_id() } -> std::convertible_to<std::uint32_t>;
    { Cipher::seal(plain_data, plain_size, nonce, ciphertext, tag) } -> std::same_as<bool>;
    { Cipher::open(nonce_data,
                   nonce_size,
                   cipher_data,
                   cipher_size,
                   tag_data,
                   tag_size,
                   plain) } -> std::same_as<bool>;
};

// Cipher policy for secure_codec.
//
// The API is intentionally static so typed_channel_codec/typed_route_codec can
// stay stateless and fully compile-time. OFF-path users pay zero runtime cost.
template <typename Cipher>
concept secure_cipher = secure_cipher_aead<Cipher>;

namespace detail {

inline constexpr std::uint8_t secure_envelope_magic[] {'S', 'I', 'P', 'C'};
inline constexpr std::uint8_t secure_envelope_version {1};
inline constexpr std::size_t secure_envelope_offset_version {
    sizeof(secure_envelope_magic)
};
inline constexpr std::size_t secure_envelope_offset_algorithm_id {
    secure_envelope_offset_version + sizeof(secure_envelope_version)
};
inline constexpr std::size_t secure_envelope_offset_key_id {
    secure_envelope_offset_algorithm_id + sizeof(std::uint16_t)
};
inline constexpr std::size_t secure_envelope_offset_nonce_size {
    secure_envelope_offset_key_id + sizeof(std::uint32_t)
};
inline constexpr std::size_t secure_envelope_offset_tag_size {
    secure_envelope_offset_nonce_size + sizeof(std::uint16_t)
};
inline constexpr std::size_t secure_envelope_offset_ciphertext_size {
    secure_envelope_offset_tag_size + sizeof(std::uint16_t)
};
inline constexpr std::size_t secure_envelope_fixed_header_size {
    secure_envelope_offset_ciphertext_size + sizeof(std::uint32_t)
};

struct secure_envelope_view {
    std::uint16_t algorithm_id {0};
    std::uint32_t key_id {0};
    const std::uint8_t *nonce {nullptr};
    std::size_t nonce_size {0};
    const std::uint8_t *ciphertext {nullptr};
    std::size_t ciphertext_size {0};
    const std::uint8_t *tag {nullptr};
    std::size_t tag_size {0};
};

inline void append_u16_le(std::vector<std::uint8_t> &out,
                          const std::uint16_t value) {
    out.push_back(static_cast<std::uint8_t>(value & 0x00FFu));
    out.push_back(static_cast<std::uint8_t>((value >> 8) & 0x00FFu));
}

inline void append_u32_le(std::vector<std::uint8_t> &out,
                          const std::uint32_t value) {
    out.push_back(static_cast<std::uint8_t>(value & 0x000000FFu));
    out.push_back(static_cast<std::uint8_t>((value >> 8) & 0x000000FFu));
    out.push_back(static_cast<std::uint8_t>((value >> 16) & 0x000000FFu));
    out.push_back(static_cast<std::uint8_t>((value >> 24) & 0x000000FFu));
}

inline bool read_u16_le(const std::uint8_t *data,
                        const std::size_t size,
                        const std::size_t offset,
                        std::uint16_t &value) {
    if (data == nullptr) return false;
    if (offset > size) return false;
    if (size - offset < sizeof(std::uint16_t)) return false;
    value = static_cast<std::uint16_t>(data[offset])
        | static_cast<std::uint16_t>(static_cast<std::uint16_t>(data[offset + 1]) << 8);
    return true;
}

inline bool read_u32_le(const std::uint8_t *data,
                        const std::size_t size,
                        const std::size_t offset,
                        std::uint32_t &value) {
    if (data == nullptr) return false;
    if (offset > size) return false;
    if (size - offset < sizeof(std::uint32_t)) return false;
    value = static_cast<std::uint32_t>(data[offset])
        | static_cast<std::uint32_t>(static_cast<std::uint32_t>(data[offset + 1]) << 8)
        | static_cast<std::uint32_t>(static_cast<std::uint32_t>(data[offset + 2]) << 16)
        | static_cast<std::uint32_t>(static_cast<std::uint32_t>(data[offset + 3]) << 24);
    return true;
}

template <typename Cipher>
constexpr std::uint16_t cipher_algorithm_id() {
    return static_cast<std::uint16_t>(Cipher::algorithm_id());
}

template <typename Cipher>
constexpr std::uint32_t cipher_key_id() {
    return static_cast<std::uint32_t>(Cipher::key_id());
}

inline bool append_secure_envelope(std::vector<std::uint8_t> &out,
                                   const std::uint16_t algorithm_id,
                                   const std::uint32_t key_id,
                                   const std::vector<std::uint8_t> &nonce,
                                   const std::vector<std::uint8_t> &ciphertext,
                                   const std::vector<std::uint8_t> &tag) {
    if (nonce.size() > std::numeric_limits<std::uint16_t>::max()) return false;
    if (tag.size() > std::numeric_limits<std::uint16_t>::max()) return false;
    if (ciphertext.size() > std::numeric_limits<std::uint32_t>::max()) return false;

    out.reserve(secure_envelope_fixed_header_size
                + nonce.size()
                + ciphertext.size()
                + tag.size());
    out.insert(out.end(),
               secure_envelope_magic,
               secure_envelope_magic + sizeof(secure_envelope_magic));
    out.push_back(secure_envelope_version);
    append_u16_le(out, algorithm_id);
    append_u32_le(out, key_id);
    append_u16_le(out, static_cast<std::uint16_t>(nonce.size()));
    append_u16_le(out, static_cast<std::uint16_t>(tag.size()));
    append_u32_le(out, static_cast<std::uint32_t>(ciphertext.size()));
    out.insert(out.end(), nonce.begin(), nonce.end());
    out.insert(out.end(), ciphertext.begin(), ciphertext.end());
    out.insert(out.end(), tag.begin(), tag.end());
    return true;
}

inline bool parse_secure_envelope(const std::uint8_t *data,
                                  const std::size_t size,
                                  secure_envelope_view &view) {
    if (data == nullptr) return false;
    if (size < secure_envelope_fixed_header_size) return false;
    if (std::memcmp(data,
                    secure_envelope_magic,
                    sizeof(secure_envelope_magic)) != 0) return false;
    if (data[secure_envelope_offset_version] != secure_envelope_version) return false;

    std::uint16_t nonce_size_u16 = 0;
    std::uint16_t tag_size_u16 = 0;
    std::uint32_t ciphertext_size_u32 = 0;
    if (!read_u16_le(data, size, secure_envelope_offset_algorithm_id, view.algorithm_id)) return false;
    if (!read_u32_le(data, size, secure_envelope_offset_key_id, view.key_id)) return false;
    if (!read_u16_le(data, size, secure_envelope_offset_nonce_size, nonce_size_u16)) return false;
    if (!read_u16_le(data, size, secure_envelope_offset_tag_size, tag_size_u16)) return false;
    if (!read_u32_le(data,
                     size,
                     secure_envelope_offset_ciphertext_size,
                     ciphertext_size_u32)) return false;

    view.nonce_size = static_cast<std::size_t>(nonce_size_u16);
    view.tag_size = static_cast<std::size_t>(tag_size_u16);
    view.ciphertext_size = static_cast<std::size_t>(ciphertext_size_u32);

    const auto payload_size = view.nonce_size + view.ciphertext_size + view.tag_size;
    if (payload_size > size) return false;
    if (size - secure_envelope_fixed_header_size != payload_size) return false;

    auto *payload = data + secure_envelope_fixed_header_size;
    view.nonce = payload;
    view.ciphertext = payload + view.nonce_size;
    view.tag = view.ciphertext + view.ciphertext_size;
    return true;
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

        std::vector<std::uint8_t> nonce;
        std::vector<std::uint8_t> ciphertext;
        std::vector<std::uint8_t> tag;
        if (!Cipher::seal(data, size, nonce, ciphertext, tag)) return;

        if (!detail::append_secure_envelope(bytes_,
                                            detail::cipher_algorithm_id<Cipher>(),
                                            detail::cipher_key_id<Cipher>(),
                                            nonce,
                                            ciphertext,
                                            tag)) bytes_.clear();
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
        detail::secure_envelope_view envelope;
        if (!detail::parse_secure_envelope(data, buf.size(), envelope)) return {};

        std::vector<std::uint8_t> plain;
        if (envelope.algorithm_id != detail::cipher_algorithm_id<Cipher>()) return {};
        if (envelope.key_id != detail::cipher_key_id<Cipher>()) return {};
        if (!Cipher::open(envelope.nonce,
                          envelope.nonce_size,
                          envelope.ciphertext,
                          envelope.ciphertext_size,
                          envelope.tag,
                          envelope.tag_size,
                          plain)) return {};
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
