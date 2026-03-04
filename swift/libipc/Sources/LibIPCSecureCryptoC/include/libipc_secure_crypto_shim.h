// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t libipc_secure_status;
typedef uint32_t libipc_secure_algorithm_id;

enum {
    LIBIPC_SECURE_STATUS_OK = 0,
    LIBIPC_SECURE_STATUS_INVALID_ARGUMENT = 1,
    LIBIPC_SECURE_STATUS_BUFFER_TOO_LARGE = 2,
    LIBIPC_SECURE_STATUS_CRYPTO_ERROR = 3,
    LIBIPC_SECURE_STATUS_UNSUPPORTED = 4,
    LIBIPC_SECURE_STATUS_ALLOCATION_FAILED = 5,
};

enum {
    LIBIPC_SECURE_ALG_AES_256_GCM = 1,
    LIBIPC_SECURE_ALG_CHACHA20_POLY1305 = 2,
};

typedef struct libipc_secure_blob {
    uint8_t *data;
    size_t size;
} libipc_secure_blob;

libipc_secure_status libipc_secure_aead_encrypt(
    libipc_secure_algorithm_id algorithm,
    const uint8_t *key_data,
    size_t key_size,
    const uint8_t *plain_data,
    size_t plain_size,
    const uint8_t *aad_data,
    size_t aad_size,
    libipc_secure_blob *nonce_out,
    libipc_secure_blob *ciphertext_out,
    libipc_secure_blob *tag_out);

libipc_secure_status libipc_secure_aead_decrypt(
    libipc_secure_algorithm_id algorithm,
    const uint8_t *key_data,
    size_t key_size,
    const uint8_t *nonce_data,
    size_t nonce_size,
    const uint8_t *ciphertext_data,
    size_t ciphertext_size,
    const uint8_t *tag_data,
    size_t tag_size,
    const uint8_t *aad_data,
    size_t aad_size,
    libipc_secure_blob *plain_out);

void libipc_secure_blob_free(libipc_secure_blob *blob);

uint32_t libipc_secure_crypto_available(void);

#ifdef __cplusplus
}
#endif
