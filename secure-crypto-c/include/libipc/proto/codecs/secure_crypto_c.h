// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Stable C ABI for secure AEAD crypto operations used by typed secure codecs.

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum libipc_secure_status {
    LIBIPC_SECURE_STATUS_OK = 0,
    LIBIPC_SECURE_STATUS_INVALID_ARGUMENT = 1,
    LIBIPC_SECURE_STATUS_BUFFER_TOO_LARGE = 2,
    LIBIPC_SECURE_STATUS_CRYPTO_ERROR = 3,
    LIBIPC_SECURE_STATUS_UNSUPPORTED = 4,
    LIBIPC_SECURE_STATUS_ALLOCATION_FAILED = 5
} libipc_secure_status;

typedef enum libipc_secure_algorithm_id {
    LIBIPC_SECURE_ALG_AES_256_GCM = 1,
    LIBIPC_SECURE_ALG_CHACHA20_POLY1305 = 2
} libipc_secure_algorithm_id;

typedef struct libipc_secure_blob {
    uint8_t *data;
    size_t size;
} libipc_secure_blob;

// Caller owns outputs and must release with libipc_secure_blob_free().
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
    libipc_secure_blob *tag_out);

// Caller owns output and must release with libipc_secure_blob_free().
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
    libipc_secure_blob *plain_out);

void libipc_secure_blob_free(libipc_secure_blob *blob);

// Runtime availability of secure backend implementation.
// Returns 1 when OpenSSL EVP backend is enabled, otherwise 0.
uint32_t libipc_secure_crypto_available(void);

#ifdef __cplusplus
}
#endif
