// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#include <gtest/gtest.h>

#include <cstdint>
#include <cstring>
#include <optional>
#include <type_traits>
#include <vector>

#include "libipc/buffer.h"
#include "libipc/proto/codec.h"
#include "libipc/proto/codecs/capnp_codec.h"
#include "libipc/proto/typed_channel_capnp.h"
#include "libipc/proto/typed_route_capnp.h"

namespace {

struct fake_capnp_message {
    std::uint32_t value_ {0};

    std::vector<std::uint8_t> encode_capnp() const {
        std::vector<std::uint8_t> bytes(sizeof(value_));
        std::memcpy(bytes.data(), &value_, sizeof(value_));
        return bytes;
    }

    static std::optional<fake_capnp_message> decode_capnp(const std::uint8_t *data,
                                                          const std::size_t size) {
        if (data == nullptr) return std::nullopt;
        if (size != sizeof(std::uint32_t)) return std::nullopt;

        std::uint32_t value = 0;
        std::memcpy(&value, data, sizeof(value));
        return fake_capnp_message{value};
    }

    std::uint32_t value() const {
        return value_;
    }
};

ipc::buff_t owning_buffer_from_bytes(const std::vector<std::uint8_t> &bytes) {
    auto *data = new std::uint8_t[bytes.size()];
    std::memcpy(data, bytes.data(), bytes.size());
    return {data, bytes.size(), [](void *p, std::size_t) {
        delete[] static_cast<std::uint8_t *>(p);
    }};
}

static_assert(ipc::proto::capnp_wire_message<fake_capnp_message>);
static_assert(ipc::proto::proto_codec<ipc::proto::capnp_codec, fake_capnp_message>);

using capnp_channel = ipc::proto::typed_channel_capnp<fake_capnp_message>;
using capnp_route = ipc::proto::typed_route_capnp<fake_capnp_message>;

static_assert(std::is_default_constructible_v<capnp_channel>);
static_assert(std::is_default_constructible_v<capnp_route>);

} // namespace

TEST(CapnpCodec, BuilderFromMessageSerializesBytes) {
    fake_capnp_message msg;
    msg.value_ = 1234;

    auto builder = ipc::proto::capnp_builder::from_message(msg);

    ASSERT_EQ(builder.size(), sizeof(std::uint32_t));

    std::uint32_t decoded = 0;
    std::memcpy(&decoded, builder.data(), sizeof(decoded));
    EXPECT_EQ(decoded, 1234u);
}

TEST(CapnpCodec, DecodeReturnsTypedMessage) {
    fake_capnp_message msg;
    msg.value_ = 77;

    auto builder = ipc::proto::capnp_builder::from_message(msg);
    auto buf = owning_buffer_from_bytes(builder.bytes());

    auto decoded = ipc::proto::capnp_codec::decode<fake_capnp_message>(std::move(buf));

    ASSERT_TRUE(decoded.verify());
    ASSERT_NE(decoded.root(), nullptr);
    EXPECT_EQ(decoded->value(), 77u);
}

TEST(CapnpCodec, DecodeInvalidPayloadFailsVerification) {
    std::vector<std::uint8_t> bytes {1, 2, 3};
    auto buf = owning_buffer_from_bytes(bytes);

    auto decoded = ipc::proto::capnp_codec::decode<fake_capnp_message>(std::move(buf));

    EXPECT_FALSE(decoded.verify());
    EXPECT_EQ(decoded.root(), nullptr);
}
