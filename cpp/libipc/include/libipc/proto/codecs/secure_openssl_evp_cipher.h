// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <concepts>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "libipc/proto/codecs/secure_crypto_c.h"

namespace ipc {
namespace proto {

// Key provider contract for the OpenSSL EVP C ABI adapter.
//
// Key material lifetime is controlled by the provider and must remain valid for
// the duration of seal/open calls.
template <typename KeyProvider>
concept openssl_evp_key_provider = requires {
    { KeyProvider::key_id() } -> std::convertible_to<std::uint32_t>;
    { KeyProvider::key_data() } -> std::same_as<const std::uint8_t *>;
    { KeyProvider::key_size() } -> std::convertible_to<std::size_t>;
};

template <libipc_secure_algorithm_id Algorithm, openssl_evp_key_provider KeyProvider>
struct secure_openssl_evp_cipher {
    static constexpr std::uint16_t algorithm_id() {
        return static_cast<std::uint16_t>(Algorithm);
    }

    static constexpr std::uint32_t key_id() {
        return static_cast<std::uint32_t>(KeyProvider::key_id());
    }

    static bool seal(const std::uint8_t *plain_data,
                     const std::size_t plain_size,
                     std::vector<std::uint8_t> &nonce,
                     std::vector<std::uint8_t> &ciphertext,
                     std::vector<std::uint8_t> &tag) {
        libipc_secure_blob nonce_blob {nullptr, 0};
        libipc_secure_blob ciphertext_blob {nullptr, 0};
        libipc_secure_blob tag_blob {nullptr, 0};

        const auto status = libipc_secure_aead_encrypt(
            Algorithm,
            KeyProvider::key_data(),
            KeyProvider::key_size(),
            plain_data,
            plain_size,
            nullptr,
            0,
            &nonce_blob,
            &ciphertext_blob,
            &tag_blob);

        if (status != LIBIPC_SECURE_STATUS_OK) {
            libipc_secure_blob_free(&tag_blob);
            libipc_secure_blob_free(&ciphertext_blob);
            libipc_secure_blob_free(&nonce_blob);
            return false;
        }

        nonce.assign(nonce_blob.data, nonce_blob.data + nonce_blob.size);
        ciphertext.assign(ciphertext_blob.data,
                          ciphertext_blob.data + ciphertext_blob.size);
        tag.assign(tag_blob.data, tag_blob.data + tag_blob.size);

        libipc_secure_blob_free(&tag_blob);
        libipc_secure_blob_free(&ciphertext_blob);
        libipc_secure_blob_free(&nonce_blob);
        return true;
    }

    static bool open(const std::uint8_t *nonce_data,
                     const std::size_t nonce_size,
                     const std::uint8_t *cipher_data,
                     const std::size_t cipher_size,
                     const std::uint8_t *tag_data,
                     const std::size_t tag_size,
                     std::vector<std::uint8_t> &plain) {
        libipc_secure_blob plain_blob {nullptr, 0};

        const auto status = libipc_secure_aead_decrypt(
            Algorithm,
            KeyProvider::key_data(),
            KeyProvider::key_size(),
            nonce_data,
            nonce_size,
            cipher_data,
            cipher_size,
            tag_data,
            tag_size,
            nullptr,
            0,
            &plain_blob);

        if (status != LIBIPC_SECURE_STATUS_OK) {
            libipc_secure_blob_free(&plain_blob);
            return false;
        }

        plain.assign(plain_blob.data, plain_blob.data + plain_blob.size);
        libipc_secure_blob_free(&plain_blob);
        return true;
    }
};

} // namespace proto
} // namespace ipc
