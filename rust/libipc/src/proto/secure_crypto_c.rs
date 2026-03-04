// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// FFI declarations for the optional secure crypto C ABI.

#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SecureStatus {
    Ok = 0,
    InvalidArgument = 1,
    BufferTooLarge = 2,
    CryptoError = 3,
    Unsupported = 4,
    AllocationFailed = 5,
}

#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SecureAlgorithmId {
    Aes256Gcm = 1,
    Chacha20Poly1305 = 2,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SecureBlob {
    pub data: *mut u8,
    pub size: usize,
}

unsafe extern "C" {
    pub fn libipc_secure_aead_encrypt(
        algorithm: SecureAlgorithmId,
        key_data: *const u8,
        key_size: usize,
        plain_data: *const u8,
        plain_size: usize,
        aad_data: *const u8,
        aad_size: usize,
        nonce_out: *mut SecureBlob,
        ciphertext_out: *mut SecureBlob,
        tag_out: *mut SecureBlob,
    ) -> SecureStatus;

    pub fn libipc_secure_aead_decrypt(
        algorithm: SecureAlgorithmId,
        key_data: *const u8,
        key_size: usize,
        nonce_data: *const u8,
        nonce_size: usize,
        ciphertext_data: *const u8,
        ciphertext_size: usize,
        tag_data: *const u8,
        tag_size: usize,
        aad_data: *const u8,
        aad_size: usize,
        plain_out: *mut SecureBlob,
    ) -> SecureStatus;

    pub fn libipc_secure_blob_free(blob: *mut SecureBlob);

    pub fn libipc_secure_crypto_available() -> u32;
}
