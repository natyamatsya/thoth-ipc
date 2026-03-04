// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#include "libipc/proto/codecs/secure_crypto_c.h"

#include <new>

#ifdef LIBIPC_SECURE_OPENSSL
#include <limits>

#include <openssl/evp.h>
#include <openssl/rand.h>
#endif

namespace {

void clear_blob(libipc_secure_blob *blob) {
    if (blob == nullptr) return;
    blob->data = nullptr;
    blob->size = 0;
}

void free_blob_storage(libipc_secure_blob *blob) {
    if (blob == nullptr) return;
    if (blob->data != nullptr) delete[] blob->data;
    clear_blob(blob);
}

bool allocate_blob(const size_t size,
                   libipc_secure_blob *blob) {
    if (blob == nullptr) return false;
    clear_blob(blob);
    if (size == 0) return true;

    auto *storage = new (std::nothrow) uint8_t[size];
    if (storage == nullptr) return false;
    blob->data = storage;
    blob->size = size;
    return true;
}

#ifdef LIBIPC_SECURE_OPENSSL

constexpr size_t openssl_aead_nonce_size {12};
constexpr size_t openssl_aead_tag_size {16};

const EVP_CIPHER *resolve_cipher(const libipc_secure_algorithm_id algorithm) {
    if (algorithm == LIBIPC_SECURE_ALG_AES_256_GCM) return EVP_aes_256_gcm();
    if (algorithm == LIBIPC_SECURE_ALG_CHACHA20_POLY1305) return EVP_chacha20_poly1305();
    return nullptr;
}

bool validate_key_size(const libipc_secure_algorithm_id algorithm,
                       const size_t key_size) {
    if (algorithm == LIBIPC_SECURE_ALG_AES_256_GCM) return key_size == 32;
    if (algorithm == LIBIPC_SECURE_ALG_CHACHA20_POLY1305) return key_size == 32;
    return false;
}

bool is_int_compatible(const size_t value) {
    return value <= static_cast<size_t>(std::numeric_limits<int>::max());
}

#endif

} // namespace

extern "C" {

void libipc_secure_blob_free(libipc_secure_blob *blob) {
    free_blob_storage(blob);
}

libipc_secure_status libipc_secure_aead_encrypt(
    const libipc_secure_algorithm_id algorithm,
    const uint8_t *key_data,
    const size_t key_size,
    const uint8_t *plain_data,
    const size_t plain_size,
    const uint8_t *aad_data,
    const size_t aad_size,
    libipc_secure_blob *nonce_out,
    libipc_secure_blob *ciphertext_out,
    libipc_secure_blob *tag_out) {
    if (nonce_out == nullptr) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (ciphertext_out == nullptr) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (tag_out == nullptr) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;

    clear_blob(nonce_out);
    clear_blob(ciphertext_out);
    clear_blob(tag_out);

#ifdef LIBIPC_SECURE_OPENSSL
    if (key_data == nullptr) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (plain_data == nullptr && plain_size != 0) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (aad_data == nullptr && aad_size != 0) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (!validate_key_size(algorithm, key_size)) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (!is_int_compatible(plain_size)) return LIBIPC_SECURE_STATUS_BUFFER_TOO_LARGE;
    if (!is_int_compatible(aad_size)) return LIBIPC_SECURE_STATUS_BUFFER_TOO_LARGE;

    const auto *cipher = resolve_cipher(algorithm);
    if (cipher == nullptr) return LIBIPC_SECURE_STATUS_UNSUPPORTED;

    if (!allocate_blob(openssl_aead_nonce_size, nonce_out)) return LIBIPC_SECURE_STATUS_ALLOCATION_FAILED;
    if (!allocate_blob(plain_size, ciphertext_out)) {
        free_blob_storage(nonce_out);
        return LIBIPC_SECURE_STATUS_ALLOCATION_FAILED;
    }
    if (!allocate_blob(openssl_aead_tag_size, tag_out)) {
        free_blob_storage(ciphertext_out);
        free_blob_storage(nonce_out);
        return LIBIPC_SECURE_STATUS_ALLOCATION_FAILED;
    }

    if (RAND_bytes(nonce_out->data, static_cast<int>(nonce_out->size)) != 1) {
        free_blob_storage(tag_out);
        free_blob_storage(ciphertext_out);
        free_blob_storage(nonce_out);
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }

    auto *ctx = EVP_CIPHER_CTX_new();
    if (ctx == nullptr) {
        free_blob_storage(tag_out);
        free_blob_storage(ciphertext_out);
        free_blob_storage(nonce_out);
        return LIBIPC_SECURE_STATUS_ALLOCATION_FAILED;
    }

    int len = 0;
    int ciphertext_size = 0;

    auto cleanup_error = [&]() {
        EVP_CIPHER_CTX_free(ctx);
        free_blob_storage(tag_out);
        free_blob_storage(ciphertext_out);
        free_blob_storage(nonce_out);
    };

    if (EVP_EncryptInit_ex(ctx, cipher, nullptr, nullptr, nullptr) != 1) {
        cleanup_error();
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }
    if (EVP_CIPHER_CTX_ctrl(ctx,
                            EVP_CTRL_AEAD_SET_IVLEN,
                            static_cast<int>(nonce_out->size),
                            nullptr) != 1) {
        cleanup_error();
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }
    if (EVP_EncryptInit_ex(ctx, nullptr, nullptr, key_data, nonce_out->data) != 1) {
        cleanup_error();
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }
    if (aad_size != 0) {
        if (EVP_EncryptUpdate(ctx,
                              nullptr,
                              &len,
                              aad_data,
                              static_cast<int>(aad_size)) != 1) {
            cleanup_error();
            return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
        }
    }
    if (plain_size != 0) {
        if (EVP_EncryptUpdate(ctx,
                              ciphertext_out->data,
                              &len,
                              plain_data,
                              static_cast<int>(plain_size)) != 1) {
            cleanup_error();
            return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
        }
        ciphertext_size = len;
    }

    if (EVP_EncryptFinal_ex(ctx, ciphertext_out->data + ciphertext_size, &len) != 1) {
        cleanup_error();
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }
    ciphertext_size += len;

    if (EVP_CIPHER_CTX_ctrl(ctx,
                            EVP_CTRL_AEAD_GET_TAG,
                            static_cast<int>(tag_out->size),
                            tag_out->data) != 1) {
        cleanup_error();
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }

    EVP_CIPHER_CTX_free(ctx);
    ciphertext_out->size = static_cast<size_t>(ciphertext_size);
    return LIBIPC_SECURE_STATUS_OK;
#else
    (void) algorithm;
    (void) key_data;
    (void) key_size;
    (void) plain_data;
    (void) plain_size;
    (void) aad_data;
    (void) aad_size;
    return LIBIPC_SECURE_STATUS_UNSUPPORTED;
#endif
}

libipc_secure_status libipc_secure_aead_decrypt(
    const libipc_secure_algorithm_id algorithm,
    const uint8_t *key_data,
    const size_t key_size,
    const uint8_t *nonce_data,
    const size_t nonce_size,
    const uint8_t *ciphertext_data,
    const size_t ciphertext_size,
    const uint8_t *tag_data,
    const size_t tag_size,
    const uint8_t *aad_data,
    const size_t aad_size,
    libipc_secure_blob *plain_out) {
    if (plain_out == nullptr) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;

    clear_blob(plain_out);

#ifdef LIBIPC_SECURE_OPENSSL
    if (key_data == nullptr) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (nonce_data == nullptr && nonce_size != 0) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (ciphertext_data == nullptr && ciphertext_size != 0) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (tag_data == nullptr && tag_size != 0) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (aad_data == nullptr && aad_size != 0) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (!validate_key_size(algorithm, key_size)) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (nonce_size != openssl_aead_nonce_size) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (tag_size != openssl_aead_tag_size) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (!is_int_compatible(ciphertext_size)) return LIBIPC_SECURE_STATUS_BUFFER_TOO_LARGE;
    if (!is_int_compatible(aad_size)) return LIBIPC_SECURE_STATUS_BUFFER_TOO_LARGE;

    const auto *cipher = resolve_cipher(algorithm);
    if (cipher == nullptr) return LIBIPC_SECURE_STATUS_UNSUPPORTED;

    if (!allocate_blob(ciphertext_size, plain_out)) return LIBIPC_SECURE_STATUS_ALLOCATION_FAILED;

    auto *ctx = EVP_CIPHER_CTX_new();
    if (ctx == nullptr) {
        free_blob_storage(plain_out);
        return LIBIPC_SECURE_STATUS_ALLOCATION_FAILED;
    }

    int len = 0;
    int plain_size = 0;

    auto cleanup_error = [&]() {
        EVP_CIPHER_CTX_free(ctx);
        free_blob_storage(plain_out);
    };

    if (EVP_DecryptInit_ex(ctx, cipher, nullptr, nullptr, nullptr) != 1) {
        cleanup_error();
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }
    if (EVP_CIPHER_CTX_ctrl(ctx,
                            EVP_CTRL_AEAD_SET_IVLEN,
                            static_cast<int>(nonce_size),
                            nullptr) != 1) {
        cleanup_error();
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }
    if (EVP_DecryptInit_ex(ctx, nullptr, nullptr, key_data, nonce_data) != 1) {
        cleanup_error();
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }
    if (aad_size != 0) {
        if (EVP_DecryptUpdate(ctx,
                              nullptr,
                              &len,
                              aad_data,
                              static_cast<int>(aad_size)) != 1) {
            cleanup_error();
            return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
        }
    }
    if (ciphertext_size != 0) {
        if (EVP_DecryptUpdate(ctx,
                              plain_out->data,
                              &len,
                              ciphertext_data,
                              static_cast<int>(ciphertext_size)) != 1) {
            cleanup_error();
            return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
        }
        plain_size = len;
    }

    if (EVP_CIPHER_CTX_ctrl(ctx,
                            EVP_CTRL_AEAD_SET_TAG,
                            static_cast<int>(tag_size),
                            const_cast<uint8_t *>(tag_data)) != 1) {
        cleanup_error();
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }

    const int final_ok = EVP_DecryptFinal_ex(ctx, plain_out->data + plain_size, &len);
    if (final_ok != 1) {
        cleanup_error();
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }

    plain_size += len;
    EVP_CIPHER_CTX_free(ctx);
    plain_out->size = static_cast<size_t>(plain_size);
    return LIBIPC_SECURE_STATUS_OK;
#else
    (void) algorithm;
    (void) key_data;
    (void) key_size;
    (void) nonce_data;
    (void) nonce_size;
    (void) ciphertext_data;
    (void) ciphertext_size;
    (void) tag_data;
    (void) tag_size;
    (void) aad_data;
    (void) aad_size;
    return LIBIPC_SECURE_STATUS_UNSUPPORTED;
#endif
}

} // extern "C"
