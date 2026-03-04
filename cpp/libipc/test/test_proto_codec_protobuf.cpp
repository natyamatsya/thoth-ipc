// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#include <gtest/gtest.h>

#include <cstdint>
#include <cstring>
#include <vector>

#include "libipc/buffer.h"
#include "libipc/proto/codec.h"
#include "libipc/proto/codecs/protobuf_codec.h"

namespace {

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

ipc::buff_t owning_buffer_from_bytes(const std::vector<std::uint8_t> &bytes) {
    auto *data = new std::uint8_t[bytes.size()];
    std::memcpy(data, bytes.data(), bytes.size());
    return {data, bytes.size(), [](void *p, std::size_t) {
        delete[] static_cast<std::uint8_t *>(p);
    }};
}

static_assert(ipc::proto::proto_codec<ipc::proto::protobuf_codec, fake_proto_message>);

} // namespace

TEST(ProtobufCodec, BuilderFromMessageSerializesBytes) {
    fake_proto_message msg;
    msg.value_ = 1234;

    auto builder = ipc::proto::protobuf_builder::from_message(msg);

    ASSERT_EQ(builder.size(), sizeof(std::uint32_t));

    std::uint32_t decoded = 0;
    std::memcpy(&decoded, builder.data(), sizeof(decoded));
    EXPECT_EQ(decoded, 1234u);
}

TEST(ProtobufCodec, DecodeReturnsTypedMessage) {
    fake_proto_message msg;
    msg.value_ = 77;

    auto builder = ipc::proto::protobuf_builder::from_message(msg);
    auto buf = owning_buffer_from_bytes(builder.bytes());

    auto decoded = ipc::proto::protobuf_codec::decode<fake_proto_message>(std::move(buf));

    ASSERT_TRUE(decoded.verify());
    ASSERT_NE(decoded.root(), nullptr);
    EXPECT_EQ(decoded->value(), 77u);
}

TEST(ProtobufCodec, DecodeInvalidPayloadFailsVerification) {
    std::vector<std::uint8_t> bytes {1, 2, 3};
    auto buf = owning_buffer_from_bytes(bytes);

    auto decoded = ipc::proto::protobuf_codec::decode<fake_proto_message>(std::move(buf));

    EXPECT_FALSE(decoded.verify());
    EXPECT_EQ(decoded.root(), nullptr);
}
