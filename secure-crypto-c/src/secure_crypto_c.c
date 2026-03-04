// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#include "libipc/proto/codecs/secure_crypto_c.h"

#include <limits.h>
#include <stdlib.h>

#ifdef LIBIPC_SECURE_OPENSSL
#include <openssl/evp.h>
#include <openssl/rand.h>
#endif

static const size_t kNonceSize = 12;
static const size_t kTagSize = 16;

static void clear_blob(libipc_secure_blob *blob) {
    if (blob == NULL) return;
    blob->data = NULL;
    blob->size = 0;
}

static void free_blob(libipc_secure_blob *blob) {
    if (blob == NULL) return;
    if (blob->data != NULL) free(blob->data);
    clear_blob(blob);
}

static libipc_secure_status allocate_blob(const size_t size,
                                          libipc_secure_blob *blob) {
    if (blob == NULL) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;

    clear_blob(blob);
    if (size == 0) return LIBIPC_SECURE_STATUS_OK;

    uint8_t *storage = (uint8_t *) malloc(size);
    if (storage == NULL) return LIBIPC_SECURE_STATUS_ALLOCATION_FAILED;

    blob->data = storage;
    blob->size = size;
    return LIBIPC_SECURE_STATUS_OK;
}

#ifdef LIBIPC_SECURE_OPENSSL
static const EVP_CIPHER *resolve_cipher(const libipc_secure_algorithm_id algorithm) {
    if (algorithm == LIBIPC_SECURE_ALG_AES_256_GCM) return EVP_aes_256_gcm();
    if (algorithm == LIBIPC_SECURE_ALG_CHACHA20_POLY1305) return EVP_chacha20_poly1305();
    return NULL;
}

static int is_supported_key_size(const libipc_secure_algorithm_id algorithm,
                                 const size_t key_size) {
    if (algorithm == LIBIPC_SECURE_ALG_AES_256_GCM) return key_size == 32;
    if (algorithm == LIBIPC_SECURE_ALG_CHACHA20_POLY1305) return key_size == 32;
    return 0;
}

static int fits_int(const size_t value) {
    return value <= (size_t) INT_MAX;
}
#endif

uint32_t libipc_secure_crypto_available(void) {
#ifdef LIBIPC_SECURE_OPENSSL
    return 1;
#else
    return 0;
#endif
}

void libipc_secure_blob_free(libipc_secure_blob *blob) {
    free_blob(blob);
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
    if (nonce_out == NULL) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (ciphertext_out == NULL) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (tag_out == NULL) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;

    clear_blob(nonce_out);
    clear_blob(ciphertext_out);
    clear_blob(tag_out);

#ifdef LIBIPC_SECURE_OPENSSL
    if (key_data == NULL) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (plain_data == NULL && plain_size != 0) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (aad_data == NULL && aad_size != 0) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (!is_supported_key_size(algorithm, key_size)) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (!fits_int(plain_size)) return LIBIPC_SECURE_STATUS_BUFFER_TOO_LARGE;
    if (!fits_int(aad_size)) return LIBIPC_SECURE_STATUS_BUFFER_TOO_LARGE;

    const EVP_CIPHER *cipher = resolve_cipher(algorithm);
    if (cipher == NULL) return LIBIPC_SECURE_STATUS_UNSUPPORTED;

    if (allocate_blob(kNonceSize, nonce_out) != LIBIPC_SECURE_STATUS_OK)
        return LIBIPC_SECURE_STATUS_ALLOCATION_FAILED;
    if (allocate_blob(plain_size, ciphertext_out) != LIBIPC_SECURE_STATUS_OK) {
        free_blob(nonce_out);
        return LIBIPC_SECURE_STATUS_ALLOCATION_FAILED;
    }
    if (allocate_blob(kTagSize, tag_out) != LIBIPC_SECURE_STATUS_OK) {
        free_blob(ciphertext_out);
        free_blob(nonce_out);
        return LIBIPC_SECURE_STATUS_ALLOCATION_FAILED;
    }

    if (RAND_bytes(nonce_out->data, (int) nonce_out->size) != 1) {
        free_blob(tag_out);
        free_blob(ciphertext_out);
        free_blob(nonce_out);
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (ctx == NULL) {
        free_blob(tag_out);
        free_blob(ciphertext_out);
        free_blob(nonce_out);
        return LIBIPC_SECURE_STATUS_ALLOCATION_FAILED;
    }

    int len = 0;
    int ciphertext_size = 0;

    if (EVP_EncryptInit_ex(ctx, cipher, NULL, NULL, NULL) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        free_blob(tag_out);
        free_blob(ciphertext_out);
        free_blob(nonce_out);
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, (int) nonce_out->size, NULL) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        free_blob(tag_out);
        free_blob(ciphertext_out);
        free_blob(nonce_out);
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }
    if (EVP_EncryptInit_ex(ctx, NULL, NULL, key_data, nonce_out->data) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        free_blob(tag_out);
        free_blob(ciphertext_out);
        free_blob(nonce_out);
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }
    if (aad_size != 0) {
        if (EVP_EncryptUpdate(ctx, NULL, &len, aad_data, (int) aad_size) != 1) {
            EVP_CIPHER_CTX_free(ctx);
            free_blob(tag_out);
            free_blob(ciphertext_out);
            free_blob(nonce_out);
            return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
        }
    }
    if (plain_size != 0) {
        if (EVP_EncryptUpdate(ctx,
                              ciphertext_out->data,
                              &len,
                              plain_data,
                              (int) plain_size) != 1) {
            EVP_CIPHER_CTX_free(ctx);
            free_blob(tag_out);
            free_blob(ciphertext_out);
            free_blob(nonce_out);
            return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
        }
        ciphertext_size = len;
    }

    if (EVP_EncryptFinal_ex(ctx, ciphertext_out->data + ciphertext_size, &len) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        free_blob(tag_out);
        free_blob(ciphertext_out);
        free_blob(nonce_out);
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }
    ciphertext_size += len;

    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, (int) tag_out->size, tag_out->data) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        free_blob(tag_out);
        free_blob(ciphertext_out);
        free_blob(nonce_out);
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }

    EVP_CIPHER_CTX_free(ctx);
    ciphertext_out->size = (size_t) ciphertext_size;
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
    if (plain_out == NULL) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;

    clear_blob(plain_out);

#ifdef LIBIPC_SECURE_OPENSSL
    if (key_data == NULL) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (nonce_data == NULL && nonce_size != 0) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (ciphertext_data == NULL && ciphertext_size != 0) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (tag_data == NULL && tag_size != 0) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (aad_data == NULL && aad_size != 0) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (!is_supported_key_size(algorithm, key_size)) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (nonce_size != kNonceSize) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (tag_size != kTagSize) return LIBIPC_SECURE_STATUS_INVALID_ARGUMENT;
    if (!fits_int(ciphertext_size)) return LIBIPC_SECURE_STATUS_BUFFER_TOO_LARGE;
    if (!fits_int(aad_size)) return LIBIPC_SECURE_STATUS_BUFFER_TOO_LARGE;

    const EVP_CIPHER *cipher = resolve_cipher(algorithm);
    if (cipher == NULL) return LIBIPC_SECURE_STATUS_UNSUPPORTED;

    if (allocate_blob(ciphertext_size, plain_out) != LIBIPC_SECURE_STATUS_OK)
        return LIBIPC_SECURE_STATUS_ALLOCATION_FAILED;

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (ctx == NULL) {
        free_blob(plain_out);
        return LIBIPC_SECURE_STATUS_ALLOCATION_FAILED;
    }

    int len = 0;
    int plain_size = 0;

    if (EVP_DecryptInit_ex(ctx, cipher, NULL, NULL, NULL) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        free_blob(plain_out);
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }
    if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, (int) nonce_size, NULL) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        free_blob(plain_out);
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }
    if (EVP_DecryptInit_ex(ctx, NULL, NULL, key_data, nonce_data) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        free_blob(plain_out);
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }
    if (aad_size != 0) {
        if (EVP_DecryptUpdate(ctx, NULL, &len, aad_data, (int) aad_size) != 1) {
            EVP_CIPHER_CTX_free(ctx);
            free_blob(plain_out);
            return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
        }
    }
    if (ciphertext_size != 0) {
        if (EVP_DecryptUpdate(ctx,
                              plain_out->data,
                              &len,
                              ciphertext_data,
                              (int) ciphertext_size) != 1) {
            EVP_CIPHER_CTX_free(ctx);
            free_blob(plain_out);
            return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
        }
        plain_size = len;
    }

    if (EVP_CIPHER_CTX_ctrl(ctx,
                            EVP_CTRL_AEAD_SET_TAG,
                            (int) tag_size,
                            (void *) tag_data) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        free_blob(plain_out);
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }

    if (EVP_DecryptFinal_ex(ctx, plain_out->data + plain_size, &len) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        free_blob(plain_out);
        return LIBIPC_SECURE_STATUS_CRYPTO_ERROR;
    }

    plain_size += len;
    EVP_CIPHER_CTX_free(ctx);
    plain_out->size = (size_t) plain_size;
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
