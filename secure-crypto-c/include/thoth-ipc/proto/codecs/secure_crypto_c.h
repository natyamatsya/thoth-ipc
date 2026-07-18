// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Stable C ABI for secure AEAD crypto operations used by typed secure codecs.

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum thoth_ipc_secure_status {
    THOTH_IPC_SECURE_STATUS_OK = 0,
    THOTH_IPC_SECURE_STATUS_INVALID_ARGUMENT = 1,
    THOTH_IPC_SECURE_STATUS_BUFFER_TOO_LARGE = 2,
    THOTH_IPC_SECURE_STATUS_CRYPTO_ERROR = 3,
    THOTH_IPC_SECURE_STATUS_UNSUPPORTED = 4,
    THOTH_IPC_SECURE_STATUS_ALLOCATION_FAILED = 5
} thoth_ipc_secure_status;

typedef enum thoth_ipc_secure_algorithm_id {
    THOTH_IPC_SECURE_ALG_AES_256_GCM = 1,
    THOTH_IPC_SECURE_ALG_CHACHA20_POLY1305 = 2
} thoth_ipc_secure_algorithm_id;

typedef struct thoth_ipc_secure_blob {
    uint8_t *data;
    size_t size;
} thoth_ipc_secure_blob;

// Caller owns outputs and must release with thoth_ipc_secure_blob_free().
thoth_ipc_secure_status thoth_ipc_secure_aead_encrypt(
    const thoth_ipc_secure_algorithm_id algorithm,
    const uint8_t *key_data,
    const size_t key_size,
    const uint8_t *plain_data,
    const size_t plain_size,
    const uint8_t *aad_data,
    const size_t aad_size,
    thoth_ipc_secure_blob *nonce_out,
    thoth_ipc_secure_blob *ciphertext_out,
    thoth_ipc_secure_blob *tag_out);

// Caller owns output and must release with thoth_ipc_secure_blob_free().
thoth_ipc_secure_status thoth_ipc_secure_aead_decrypt(
    const thoth_ipc_secure_algorithm_id algorithm,
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
    thoth_ipc_secure_blob *plain_out);

void thoth_ipc_secure_blob_free(thoth_ipc_secure_blob *blob);

// Runtime availability of secure backend implementation.
// Returns 1 when OpenSSL EVP backend is enabled, otherwise 0.
uint32_t thoth_ipc_secure_crypto_available(void);

#ifdef __cplusplus
}
#endif
