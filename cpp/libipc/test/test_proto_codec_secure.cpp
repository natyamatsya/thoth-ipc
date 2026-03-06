// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#include <gtest/gtest.h>

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <string>
#include <type_traits>
#include <vector>

#include "libipc/buffer.h"
#include "libipc/proto/codec.h"
#include "libipc/proto/codecs/capnp_codec.h"
#include "libipc/proto/codecs/protobuf_codec.h"
#include "libipc/proto/codecs/secure_codec.h"
#include "libipc/proto/codecs/secure_openssl_evp_cipher.h"
#include "libipc/proto/typed_channel_secure.h"
#include "libipc/proto/typed_route_secure.h"

namespace {

struct fake_builder {
    std::vector<std::uint8_t> bytes_;
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

struct aead_xor_cipher {
    static constexpr std::uint16_t algorithm_id() {
        return 0x4210u;
    }

    static constexpr std::uint32_t key_id() {
        return 0x12345678u;
    }

    static bool seal(const std::uint8_t *data,
                     const std::size_t size,
                     std::vector<std::uint8_t> &nonce,
                     std::vector<std::uint8_t> &ciphertext,
                     std::vector<std::uint8_t> &tag) {
        if (data == nullptr && size != 0) return false;

        nonce = {0x10u, 0x11u, 0x12u, 0x13u, 0x14u, 0x15u,
                 0x16u, 0x17u, 0x18u, 0x19u, 0x1Au, 0x1Bu};

        ciphertext.resize(size);
        std::uint8_t checksum = 0;
        for (std::size_t i = 0; i < size; ++i) {
            ciphertext[i] = static_cast<std::uint8_t>(data[i] ^ 0x5Au);
            checksum = static_cast<std::uint8_t>(checksum ^ ciphertext[i]);
        }

        tag = {checksum,
               static_cast<std::uint8_t>(size & 0xFFu),
               static_cast<std::uint8_t>((size >> 8) & 0xFFu),
               static_cast<std::uint8_t>(nonce.size())};
        return true;
    }

    static bool open(const std::uint8_t *nonce_data,
                     const std::size_t nonce_size,
                     const std::uint8_t *cipher_data,
                     const std::size_t cipher_size,
                     const std::uint8_t *tag_data,
                     const std::size_t tag_size,
                     std::vector<std::uint8_t> &plain) {
        if (nonce_data == nullptr && nonce_size != 0) return false;
        if (cipher_data == nullptr && cipher_size != 0) return false;
        if (tag_data == nullptr) return false;
        if (nonce_size != 12) return false;
        if (tag_size != 4) return false;

        std::uint8_t checksum = 0;
        for (std::size_t i = 0; i < cipher_size; ++i)
            checksum = static_cast<std::uint8_t>(checksum ^ cipher_data[i]);

        if (tag_data[0] != checksum) return false;
        if (tag_data[1] != static_cast<std::uint8_t>(cipher_size & 0xFFu)) return false;
        if (tag_data[2] != static_cast<std::uint8_t>((cipher_size >> 8) & 0xFFu)) return false;
        if (tag_data[3] != static_cast<std::uint8_t>(nonce_size)) return false;

        plain.resize(cipher_size);
        for (std::size_t i = 0; i < cipher_size; ++i)
            plain[i] = static_cast<std::uint8_t>(cipher_data[i] ^ 0x5Au);
        return true;
    }
};

struct aead_xor_cipher_open_failure {
    static constexpr std::uint16_t algorithm_id() {
        return aead_xor_cipher::algorithm_id();
    }

    static constexpr std::uint32_t key_id() {
        return aead_xor_cipher::key_id();
    }

    static bool seal(const std::uint8_t *data,
                     const std::size_t size,
                     std::vector<std::uint8_t> &nonce,
                     std::vector<std::uint8_t> &ciphertext,
                     std::vector<std::uint8_t> &tag) {
        return aead_xor_cipher::seal(data, size, nonce, ciphertext, tag);
    }

    static bool open(const std::uint8_t *nonce_data,
                     const std::size_t nonce_size,
                     const std::uint8_t *cipher_data,
                     const std::size_t cipher_size,
                     const std::uint8_t *tag_data,
                     const std::size_t tag_size,
                     std::vector<std::uint8_t> &plain) {
        if (!aead_xor_cipher::open(nonce_data,
                                   nonce_size,
                                   cipher_data,
                                   cipher_size,
                                   tag_data,
                                   tag_size,
                                   plain)) return false;
        return false;
    }
};

struct aead_xor_cipher_algorithm_mismatch : aead_xor_cipher {
    static constexpr std::uint16_t algorithm_id() {
        return static_cast<std::uint16_t>(aead_xor_cipher::algorithm_id() + 1u);
    }
};

struct aead_xor_cipher_key_mismatch : aead_xor_cipher {
    static constexpr std::uint32_t key_id() {
        return aead_xor_cipher::key_id() + 1u;
    }
};

using secure_test_codec = ipc::proto::secure_codec<fake_inner_codec, aead_xor_cipher>;
using secure_protobuf_codec = ipc::proto::secure_codec<ipc::proto::protobuf_codec, aead_xor_cipher>;
using secure_aead_test_codec = secure_test_codec;
using secure_protobuf_channel =
    ipc::proto::typed_channel_secure<fake_proto_message, ipc::proto::protobuf_codec, aead_xor_cipher>;
using secure_protobuf_route =
    ipc::proto::typed_route_secure<fake_proto_message, ipc::proto::protobuf_codec, aead_xor_cipher>;
using secure_capnp_codec = ipc::proto::secure_codec<ipc::proto::capnp_codec, aead_xor_cipher>;
using secure_capnp_channel =
    ipc::proto::typed_channel_secure<fake_capnp_message, ipc::proto::capnp_codec, aead_xor_cipher>;
using secure_capnp_route =
    ipc::proto::typed_route_secure<fake_capnp_message, ipc::proto::capnp_codec, aead_xor_cipher>;
using secure_capnp_builder = ipc::proto::secure_builder<ipc::proto::capnp_codec, aead_xor_cipher>;
using secure_fail_open_codec = ipc::proto::secure_codec<fake_inner_codec, aead_xor_cipher_open_failure>;

#ifdef LIBIPC_SECURE_OPENSSL
struct openssl_test_key_provider {
    static constexpr std::uint32_t key_id() {
        return 0x0A0B0C0Du;
    }

    static const std::uint8_t *key_data() {
        static const std::array<std::uint8_t, 32> key {
            0x00u, 0x01u, 0x02u, 0x03u, 0x04u, 0x05u, 0x06u, 0x07u,
            0x08u, 0x09u, 0x0Au, 0x0Bu, 0x0Cu, 0x0Du, 0x0Eu, 0x0Fu,
            0x10u, 0x11u, 0x12u, 0x13u, 0x14u, 0x15u, 0x16u, 0x17u,
            0x18u, 0x19u, 0x1Au, 0x1Bu, 0x1Cu, 0x1Du, 0x1Eu, 0x1Fu,
        };
        return key.data();
    }

    static constexpr std::size_t key_size() {
        return 32;
    }
};

struct openssl_wrong_key_provider {
    static constexpr std::uint32_t key_id() {
        return openssl_test_key_provider::key_id();
    }

    static const std::uint8_t *key_data() {
        static const std::array<std::uint8_t, 32> key {
            0xF0u, 0xE1u, 0xD2u, 0xC3u, 0xB4u, 0xA5u, 0x96u, 0x87u,
            0x78u, 0x69u, 0x5Au, 0x4Bu, 0x3Cu, 0x2Du, 0x1Eu, 0x0Fu,
            0x00u, 0x11u, 0x22u, 0x33u, 0x44u, 0x55u, 0x66u, 0x77u,
            0x88u, 0x99u, 0xAAu, 0xBBu, 0xCCu, 0xDDu, 0xEEu, 0xFFu,
        };
        return key.data();
    }

    static constexpr std::size_t key_size() {
        return 32;
    }
};

struct openssl_mismatched_key_id_provider {
    static constexpr std::uint32_t key_id() {
        return openssl_test_key_provider::key_id() + 1u;
    }

    static const std::uint8_t *key_data() {
        return openssl_test_key_provider::key_data();
    }

    static constexpr std::size_t key_size() {
        return openssl_test_key_provider::key_size();
    }
};

using secure_openssl_cipher =
    ipc::proto::secure_openssl_evp_cipher<LIBIPC_SECURE_ALG_AES_256_GCM, openssl_test_key_provider>;
using secure_openssl_codec = ipc::proto::secure_codec<ipc::proto::protobuf_codec, secure_openssl_cipher>;
using secure_openssl_wrong_key_cipher =
    ipc::proto::secure_openssl_evp_cipher<LIBIPC_SECURE_ALG_AES_256_GCM, openssl_wrong_key_provider>;
using secure_openssl_wrong_key_codec =
    ipc::proto::secure_codec<ipc::proto::protobuf_codec, secure_openssl_wrong_key_cipher>;
using secure_openssl_mismatched_key_id_cipher =
    ipc::proto::secure_openssl_evp_cipher<LIBIPC_SECURE_ALG_AES_256_GCM, openssl_mismatched_key_id_provider>;
using secure_openssl_mismatched_key_id_codec =
    ipc::proto::secure_codec<ipc::proto::protobuf_codec, secure_openssl_mismatched_key_id_cipher>;
#endif

ipc::buff_t owning_buffer_from_bytes(const std::vector<std::uint8_t> &bytes) {
    auto *data = new std::uint8_t[bytes.size()];
    std::memcpy(data, bytes.data(), bytes.size());
    return {data, bytes.size(), [](void *p, std::size_t) {
        delete[] static_cast<std::uint8_t *>(p);
    }};
}

std::string make_unique_name(const char *prefix) {
    static std::atomic<std::uint32_t> counter {0};
    const auto id = counter.fetch_add(1, std::memory_order_relaxed);
    return std::string(prefix) + "_" + std::to_string(id);
}

static_assert(ipc::proto::secure_cipher<aead_xor_cipher>);
static_assert(ipc::proto::secure_cipher_aead<aead_xor_cipher>);
static_assert(ipc::proto::proto_codec<secure_test_codec, int>);
static_assert(std::is_default_constructible_v<secure_protobuf_channel>);
static_assert(std::is_default_constructible_v<secure_protobuf_route>);
static_assert(std::is_default_constructible_v<secure_capnp_channel>);
static_assert(std::is_default_constructible_v<secure_capnp_route>);
#ifdef LIBIPC_SECURE_OPENSSL
static_assert(ipc::proto::secure_cipher_aead<secure_openssl_cipher>);
#endif

} // namespace

TEST(SecureCodec, BuilderSealsInnerPayload) {
    fake_builder plain_builder;
    plain_builder.bytes_ = {1, 2, 3, 4};

    ipc::proto::secure_builder<fake_inner_codec, aead_xor_cipher> secure_builder{plain_builder};

    ASSERT_GT(secure_builder.size(), plain_builder.bytes_.size());
    EXPECT_NE(secure_builder.bytes(), plain_builder.bytes_);
}

TEST(SecureCodec, DecodeOpensPayloadBeforeInnerDecode) {
    std::uint32_t plain_value = 0x11223344u;
    std::vector<std::uint8_t> plain_bytes(sizeof(plain_value));
    std::memcpy(plain_bytes.data(), &plain_value, sizeof(plain_value));

    fake_builder plain_builder;
    plain_builder.bytes_ = plain_bytes;

    ipc::proto::secure_builder<fake_inner_codec, aead_xor_cipher> secure_builder{plain_builder};
    ASSERT_GT(secure_builder.size(), plain_builder.bytes_.size());

    auto buf = owning_buffer_from_bytes(secure_builder.bytes());
    auto decoded = secure_test_codec::decode<int>(std::move(buf));

    EXPECT_FALSE(decoded.empty());
    EXPECT_EQ(decoded.value(), plain_value);
}

TEST(SecureCodec, DecodeFailsClosedWhenOpenFails) {
    fake_builder plain_builder;
    plain_builder.bytes_ = {0xAA, 0xBB, 0xCC, 0xDD};

    ipc::proto::secure_builder<fake_inner_codec, aead_xor_cipher_open_failure> secure_builder{plain_builder};
    auto buf = owning_buffer_from_bytes(secure_builder.bytes());

    auto decoded = secure_fail_open_codec::decode<int>(std::move(buf));

    EXPECT_TRUE(decoded.empty());
}

TEST(SecureCodec, AeadCipherRoundTrip) {
    std::uint32_t plain_value = 0xCAFEBABEu;
    std::vector<std::uint8_t> plain_bytes(sizeof(plain_value));
    std::memcpy(plain_bytes.data(), &plain_value, sizeof(plain_value));

    fake_builder plain_builder;
    plain_builder.bytes_ = plain_bytes;

    ipc::proto::secure_builder<fake_inner_codec, aead_xor_cipher> secure_builder{plain_builder};
    ASSERT_GT(secure_builder.size(), plain_builder.bytes_.size());

    auto buf = owning_buffer_from_bytes(secure_builder.bytes());
    auto decoded = secure_aead_test_codec::decode<int>(std::move(buf));

    EXPECT_FALSE(decoded.empty());
    EXPECT_EQ(decoded.value(), plain_value);
}

TEST(SecureCodec, DecodeFailsClosedWhenAeadAlgorithmIdMismatches) {
    fake_builder plain_builder;
    plain_builder.bytes_ = {1, 2, 3, 4};

    ipc::proto::secure_builder<fake_inner_codec, aead_xor_cipher_algorithm_mismatch> secure_builder{plain_builder};
    auto buf = owning_buffer_from_bytes(secure_builder.bytes());

    auto decoded = secure_aead_test_codec::decode<int>(std::move(buf));

    EXPECT_TRUE(decoded.empty());
}

TEST(SecureCodec, DecodeFailsClosedWhenAeadKeyIdMismatches) {
    fake_builder plain_builder;
    plain_builder.bytes_ = {1, 2, 3, 4};

    ipc::proto::secure_builder<fake_inner_codec, aead_xor_cipher_key_mismatch> secure_builder{plain_builder};
    auto buf = owning_buffer_from_bytes(secure_builder.bytes());

    auto decoded = secure_aead_test_codec::decode<int>(std::move(buf));

    EXPECT_TRUE(decoded.empty());
}

TEST(SecureCodec, DecodeFailsClosedWhenAeadTagTampered) {
    fake_builder plain_builder;
    plain_builder.bytes_ = {0x21, 0x22, 0x23, 0x24};

    ipc::proto::secure_builder<fake_inner_codec, aead_xor_cipher> secure_builder{plain_builder};
    auto bytes = secure_builder.bytes();
    ASSERT_FALSE(bytes.empty());
    bytes.back() = static_cast<std::uint8_t>(bytes.back() ^ 0x7Fu);

    auto buf = owning_buffer_from_bytes(bytes);
    auto decoded = secure_aead_test_codec::decode<int>(std::move(buf));

    EXPECT_TRUE(decoded.empty());
}

TEST(SecureCodec, DecodeFailsClosedWhenAeadEnvelopeTruncated) {
    fake_builder plain_builder;
    plain_builder.bytes_ = {0x31, 0x32, 0x33, 0x34};

    ipc::proto::secure_builder<fake_inner_codec, aead_xor_cipher> secure_builder{plain_builder};
    auto bytes = secure_builder.bytes();
    ASSERT_GT(bytes.size(), 1u);
    bytes.pop_back();

    auto buf = owning_buffer_from_bytes(bytes);
    auto decoded = secure_aead_test_codec::decode<int>(std::move(buf));

    EXPECT_TRUE(decoded.empty());
}

TEST(SecureCodec, DecodeFailsClosedWhenEnvelopeHeaderMissing) {
    std::vector<std::uint8_t> plain_bytes {0x11, 0x22, 0x33, 0x44};
    auto buf = owning_buffer_from_bytes(plain_bytes);

    auto decoded = secure_test_codec::decode<int>(std::move(buf));

    EXPECT_TRUE(decoded.empty());
}

TEST(SecureCodec, ComposesWithProtobufCodec) {
    fake_proto_message plain_message;
    plain_message.value_ = 0x44332211u;

    auto plain_builder = ipc::proto::protobuf_builder::from_message(plain_message);
    ASSERT_EQ(plain_builder.size(), sizeof(std::uint32_t));

    ipc::proto::secure_builder<ipc::proto::protobuf_codec, aead_xor_cipher> secure_builder{plain_builder};
    ASSERT_GT(secure_builder.size(), plain_builder.size());
    ASSERT_NE(std::memcmp(secure_builder.data(), plain_builder.data(), plain_builder.size()), 0);

    auto sealed_buf = owning_buffer_from_bytes(secure_builder.bytes());
    auto decoded = secure_protobuf_codec::decode<fake_proto_message>(std::move(sealed_buf));

    ASSERT_TRUE(decoded.verify());
    ASSERT_NE(decoded.root(), nullptr);
    EXPECT_EQ(decoded->value(), plain_message.value());
}

#ifdef LIBIPC_SECURE_OPENSSL
TEST(SecureCodec, OpenSslEvpAes256GcmRoundTrip) {
    fake_proto_message plain_message;
    plain_message.value_ = 0x10203040u;

    auto plain_builder = ipc::proto::protobuf_builder::from_message(plain_message);
    ASSERT_EQ(plain_builder.size(), sizeof(std::uint32_t));

    ipc::proto::secure_builder<ipc::proto::protobuf_codec, secure_openssl_cipher> secure_builder{plain_builder};
    ASSERT_GT(secure_builder.size(), plain_builder.size());

    auto sealed_buf = owning_buffer_from_bytes(secure_builder.bytes());
    auto decoded = secure_openssl_codec::decode<fake_proto_message>(std::move(sealed_buf));

    ASSERT_TRUE(decoded.verify());
    ASSERT_NE(decoded.root(), nullptr);
    EXPECT_EQ(decoded->value(), plain_message.value());
}

TEST(SecureCodec, OpenSslEvpFailsClosedWhenKeyIdMismatches) {
    fake_proto_message plain_message;
    plain_message.value_ = 0x55667788u;

    auto plain_builder = ipc::proto::protobuf_builder::from_message(plain_message);
    ipc::proto::secure_builder<ipc::proto::protobuf_codec, secure_openssl_cipher> secure_builder{plain_builder};

    auto sealed_buf = owning_buffer_from_bytes(secure_builder.bytes());
    auto decoded = secure_openssl_mismatched_key_id_codec::decode<fake_proto_message>(
        std::move(sealed_buf));

    EXPECT_TRUE(decoded.empty());
    EXPECT_FALSE(decoded.verify());
}

TEST(SecureCodec, OpenSslEvpFailsClosedWhenWrongKeyMaterial) {
    fake_proto_message plain_message;
    plain_message.value_ = 0x66778899u;

    auto plain_builder = ipc::proto::protobuf_builder::from_message(plain_message);
    ipc::proto::secure_builder<ipc::proto::protobuf_codec, secure_openssl_cipher> secure_builder{plain_builder};

    auto sealed_buf = owning_buffer_from_bytes(secure_builder.bytes());
    auto decoded = secure_openssl_wrong_key_codec::decode<fake_proto_message>(
        std::move(sealed_buf));

    EXPECT_TRUE(decoded.empty());
    EXPECT_FALSE(decoded.verify());
}

TEST(SecureCodec, OpenSslEvpFailsClosedWhenTagTampered) {
    fake_proto_message plain_message;
    plain_message.value_ = 0xABCDEF12u;

    auto plain_builder = ipc::proto::protobuf_builder::from_message(plain_message);
    ipc::proto::secure_builder<ipc::proto::protobuf_codec, secure_openssl_cipher> secure_builder{plain_builder};

    auto bytes = secure_builder.bytes();
    ASSERT_FALSE(bytes.empty());
    bytes.back() = static_cast<std::uint8_t>(bytes.back() ^ 0x7Fu);

    auto sealed_buf = owning_buffer_from_bytes(bytes);
    auto decoded = secure_openssl_codec::decode<fake_proto_message>(std::move(sealed_buf));

    EXPECT_TRUE(decoded.empty());
    EXPECT_FALSE(decoded.verify());
}
#endif

TEST(SecureCodec, TypedRouteCapnpRoundTrip) {
    const auto name = make_unique_name("secure_capnp_route");
    secure_capnp_route::clear_storage(name.c_str());

    secure_capnp_route sender{name.c_str(), ipc::sender};
    secure_capnp_route receiver{name.c_str(), ipc::receiver};

    ASSERT_TRUE(sender.valid());
    ASSERT_TRUE(receiver.valid());
    ASSERT_TRUE(sender.raw().wait_for_recv(1, 1000));

    fake_capnp_message plain_message;
    plain_message.value_ = 0xA1B2C3D4u;

    const auto inner_builder = ipc::proto::capnp_builder::from_message(plain_message);
    const secure_capnp_builder secure_builder{inner_builder};

    ASSERT_GT(secure_builder.size(), inner_builder.size());
    ASSERT_TRUE(sender.send(secure_builder));

    auto decoded = receiver.recv(1000);
    ASSERT_TRUE(decoded.verify());
    ASSERT_NE(decoded.root(), nullptr);
    EXPECT_EQ(decoded->value(), plain_message.value());

    sender.disconnect();
    receiver.disconnect();
    secure_capnp_route::clear_storage(name.c_str());
}

TEST(SecureCodec, TypedChannelCapnpRoundTrip) {
    const auto name = make_unique_name("secure_capnp_channel");
    secure_capnp_channel::clear_storage(name.c_str());

    secure_capnp_channel sender{name.c_str(), ipc::sender};
    secure_capnp_channel receiver{name.c_str(), ipc::receiver};

    ASSERT_TRUE(sender.valid());
    ASSERT_TRUE(receiver.valid());
    ASSERT_TRUE(sender.raw().wait_for_recv(1, 1000));

    fake_capnp_message plain_message;
    plain_message.value_ = 0x0C0FFEE0u;

    const auto inner_builder = ipc::proto::capnp_builder::from_message(plain_message);
    const secure_capnp_builder secure_builder{inner_builder};

    ASSERT_GT(secure_builder.size(), inner_builder.size());
    ASSERT_TRUE(sender.send(secure_builder));

    auto decoded = receiver.recv(1000);
    ASSERT_TRUE(decoded.verify());
    ASSERT_NE(decoded.root(), nullptr);
    EXPECT_EQ(decoded->value(), plain_message.value());

    sender.disconnect();
    receiver.disconnect();
    secure_capnp_channel::clear_storage(name.c_str());
}

TEST(SecureCodec, ComposesWithCapnpCodec) {
    fake_capnp_message plain_message;
    plain_message.value_ = 0x89ABCDEFu;

    auto plain_builder = ipc::proto::capnp_builder::from_message(plain_message);
    ASSERT_EQ(plain_builder.size(), sizeof(std::uint32_t));

    ipc::proto::secure_builder<ipc::proto::capnp_codec, aead_xor_cipher> secure_builder{plain_builder};
    ASSERT_GT(secure_builder.size(), plain_builder.size());
    ASSERT_NE(std::memcmp(secure_builder.data(), plain_builder.data(), plain_builder.size()), 0);

    auto sealed_buf = owning_buffer_from_bytes(secure_builder.bytes());
    auto decoded = secure_capnp_codec::decode<fake_capnp_message>(std::move(sealed_buf));

    ASSERT_TRUE(decoded.verify());
    ASSERT_NE(decoded.root(), nullptr);
    EXPECT_EQ(decoded->value(), plain_message.value());
}
