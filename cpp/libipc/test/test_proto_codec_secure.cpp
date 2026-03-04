// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#include <gtest/gtest.h>

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <type_traits>
#include <vector>

#include "libipc/buffer.h"
#include "libipc/proto/codec.h"
#include "libipc/proto/codecs/protobuf_codec.h"
#include "libipc/proto/codecs/secure_codec.h"
#include "libipc/proto/typed_channel_secure.h"
#include "libipc/proto/typed_route_secure.h"

namespace {

struct fake_builder {
    std::vector<std::uint8_t> bytes_;
};

struct failing_open_cipher {
    static bool seal(const std::uint8_t *data, std::size_t size,
                     std::vector<std::uint8_t> &out) {
        out.resize(size);
        for (std::size_t i = 0; i < size; ++i)
            out[i] = static_cast<std::uint8_t>(data[i] ^ 0xA5u);
        return true;
    }

    static bool open(const std::uint8_t *data, std::size_t size,
                     std::vector<std::uint8_t> &out) {
        out.resize(size);
        for (std::size_t i = 0; i < size; ++i)
            out[i] = static_cast<std::uint8_t>(data[i] ^ 0xA5u);
        return false;
    }
};

struct fake_proto_message {
    std::uint32_t value_ {0};

    std::size_t ByteSizeLong() const {
        return sizeof(value_);
    }

    bool SerializeToArray(void *dst, int size) const {
        if (dst == nullptr) return false;
        if (size != static_cast<int>(sizeof(value_))) return false;
        std::memcpy(dst, &value_, sizeof(value_));
        return true;
    }

    bool ParseFromArray(const void *src, int size) {
        if (src == nullptr) return false;
        if (size != static_cast<int>(sizeof(value_))) return false;
        std::memcpy(&value_, src, sizeof(value_));
        return true;
    }

    std::uint32_t value() const {
        return value_;
    }
};

struct fake_message {
    ipc::buff_t buf_;

    fake_message() = default;
    explicit fake_message(ipc::buff_t buf)
        : buf_{std::move(buf)} {}

    bool empty() const noexcept { return buf_.empty(); }

    std::uint32_t value() const {
        if (buf_.size() != sizeof(std::uint32_t)) return 0;

        std::uint32_t out = 0;
        std::memcpy(&out, buf_.data(), sizeof(out));
        return out;
    }
};

struct fake_inner_codec {
    static constexpr ipc::proto::codec_id id = ipc::proto::codec_id::protobuf;
    using builder_type = fake_builder;

    template <typename T>
    using message_type = fake_message;

    template <typename T>
    static message_type<T> decode(ipc::buff_t buf) {
        return message_type<T>{std::move(buf)};
    }

    static const std::uint8_t *data(const builder_type &b) noexcept {
        return b.bytes_.data();
    }

    static std::size_t size(const builder_type &b) noexcept {
        return b.bytes_.size();
    }
};

struct xor_cipher {
    static bool seal(const std::uint8_t *data, std::size_t size,
                     std::vector<std::uint8_t> &out) {
        out.resize(size);
        for (std::size_t i = 0; i < size; ++i)
            out[i] = static_cast<std::uint8_t>(data[i] ^ 0xA5u);
        return true;
    }

    static bool open(const std::uint8_t *data, std::size_t size,
                     std::vector<std::uint8_t> &out) {
        return seal(data, size, out);
    }
};

using secure_test_codec = ipc::proto::secure_codec<fake_inner_codec, xor_cipher>;
using secure_protobuf_codec = ipc::proto::secure_codec<ipc::proto::protobuf_codec, xor_cipher>;
using secure_protobuf_channel =
    ipc::proto::typed_channel_secure<fake_proto_message, ipc::proto::protobuf_codec, xor_cipher>;
using secure_protobuf_route =
    ipc::proto::typed_route_secure<fake_proto_message, ipc::proto::protobuf_codec, xor_cipher>;
using secure_fail_open_codec = ipc::proto::secure_codec<fake_inner_codec, failing_open_cipher>;

ipc::buff_t owning_buffer_from_bytes(const std::vector<std::uint8_t> &bytes) {
    auto *data = new std::uint8_t[bytes.size()];
    std::memcpy(data, bytes.data(), bytes.size());
    return {data, bytes.size(), [](void *p, std::size_t) {
        delete[] static_cast<std::uint8_t *>(p);
    }};
}

static_assert(ipc::proto::secure_cipher<xor_cipher>);
static_assert(ipc::proto::proto_codec<secure_test_codec, int>);
static_assert(std::is_default_constructible_v<secure_protobuf_channel>);
static_assert(std::is_default_constructible_v<secure_protobuf_route>);

} // namespace

TEST(SecureCodec, BuilderSealsInnerPayload) {
    fake_builder plain_builder;
    plain_builder.bytes_ = {1, 2, 3, 4};

    ipc::proto::secure_builder<fake_inner_codec, xor_cipher> secure_builder{plain_builder};

    ASSERT_EQ(secure_builder.size(), plain_builder.bytes_.size());
    EXPECT_NE(secure_builder.bytes(), plain_builder.bytes_);
}

TEST(SecureCodec, DecodeOpensPayloadBeforeInnerDecode) {
    std::uint32_t plain_value = 0x11223344u;
    std::vector<std::uint8_t> plain_bytes(sizeof(plain_value));
    std::memcpy(plain_bytes.data(), &plain_value, sizeof(plain_value));

    std::vector<std::uint8_t> sealed_bytes;
    ASSERT_TRUE(xor_cipher::seal(plain_bytes.data(), plain_bytes.size(), sealed_bytes));

    auto buf = owning_buffer_from_bytes(sealed_bytes);
    auto decoded = secure_test_codec::decode<int>(std::move(buf));

    EXPECT_FALSE(decoded.empty());
    EXPECT_EQ(decoded.value(), plain_value);
}

TEST(SecureCodec, DecodeFailsClosedWhenOpenFails) {
    std::vector<std::uint8_t> sealed_bytes {0xAA, 0xBB, 0xCC, 0xDD};
    auto buf = owning_buffer_from_bytes(sealed_bytes);

    auto decoded = secure_fail_open_codec::decode<int>(std::move(buf));

    EXPECT_TRUE(decoded.empty());
}

TEST(SecureCodec, ComposesWithProtobufCodec) {
    fake_proto_message plain_message;
    plain_message.value_ = 0x44332211u;

    auto plain_builder = ipc::proto::protobuf_builder::from_message(plain_message);
    ASSERT_EQ(plain_builder.size(), sizeof(std::uint32_t));

    ipc::proto::secure_builder<ipc::proto::protobuf_codec, xor_cipher> secure_builder{plain_builder};
    ASSERT_EQ(secure_builder.size(), plain_builder.size());
    ASSERT_NE(std::memcmp(secure_builder.data(), plain_builder.data(), plain_builder.size()), 0);

    auto sealed_buf = owning_buffer_from_bytes(secure_builder.bytes());
    auto decoded = secure_protobuf_codec::decode<fake_proto_message>(std::move(sealed_buf));

    ASSERT_TRUE(decoded.verify());
    ASSERT_NE(decoded.root(), nullptr);
    EXPECT_EQ(decoded->value(), plain_message.value());
}
