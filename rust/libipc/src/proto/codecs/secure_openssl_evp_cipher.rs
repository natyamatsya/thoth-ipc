// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// OpenSSL EVP-backed secure cipher adapter using the secure crypto C ABI.

use std::marker::PhantomData;

use super::super::secure_crypto_c::{
    libipc_secure_aead_decrypt, libipc_secure_aead_encrypt, libipc_secure_blob_free,
    libipc_secure_crypto_available, SecureAlgorithmId, SecureBlob, SecureStatus,
};
use super::secure_codec::SecureCipher;

pub trait OpenSslEvpKeyProvider {
    const KEY_ID: u32;
    const KEY_BYTES: &'static [u8];
}

pub struct SecureOpenSslEvpBackend;

impl SecureOpenSslEvpBackend {
    pub fn is_available() -> bool {
        // SAFETY: The function has no arguments, no side effects, and returns a POD value.
        unsafe { libipc_secure_crypto_available() != 0 }
    }
}

trait OpenSslEvpAlgorithm {
    const ABI_ID: SecureAlgorithmId;
    const WIRE_ID: u16;
}

pub struct Aes256GcmAlgorithm;

impl OpenSslEvpAlgorithm for Aes256GcmAlgorithm {
    const ABI_ID: SecureAlgorithmId = SecureAlgorithmId::Aes256Gcm;
    const WIRE_ID: u16 = 1;
}

pub struct Chacha20Poly1305Algorithm;

impl OpenSslEvpAlgorithm for Chacha20Poly1305Algorithm {
    const ABI_ID: SecureAlgorithmId = SecureAlgorithmId::Chacha20Poly1305;
    const WIRE_ID: u16 = 2;
}

pub struct SecureOpenSslEvpCipher<Algorithm, KeyProvider>(PhantomData<(Algorithm, KeyProvider)>);

pub type SecureOpenSslEvpCipherAes256Gcm<KeyProvider> =
    SecureOpenSslEvpCipher<Aes256GcmAlgorithm, KeyProvider>;
pub type SecureOpenSslEvpCipherChacha20Poly1305<KeyProvider> =
    SecureOpenSslEvpCipher<Chacha20Poly1305Algorithm, KeyProvider>;

impl<Algorithm, KeyProvider> SecureCipher for SecureOpenSslEvpCipher<Algorithm, KeyProvider>
where
    Algorithm: OpenSslEvpAlgorithm,
    KeyProvider: OpenSslEvpKeyProvider,
{
    fn algorithm_id() -> u16 {
        Algorithm::WIRE_ID
    }

    fn key_id() -> u32 {
        KeyProvider::KEY_ID
    }

    fn seal(
        plain: &[u8],
        nonce: &mut Vec<u8>,
        ciphertext: &mut Vec<u8>,
        tag: &mut Vec<u8>,
    ) -> bool {
        seal_with_algorithm::<Algorithm, KeyProvider>(plain, nonce, ciphertext, tag)
    }

    fn open(nonce: &[u8], ciphertext: &[u8], tag: &[u8], plain: &mut Vec<u8>) -> bool {
        open_with_algorithm::<Algorithm, KeyProvider>(nonce, ciphertext, tag, plain)
    }
}

fn empty_blob() -> SecureBlob {
    SecureBlob {
        data: std::ptr::null_mut(),
        size: 0,
    }
}

fn ptr_or_null(bytes: &[u8]) -> *const u8 {
    if bytes.is_empty() {
        return std::ptr::null();
    }
    bytes.as_ptr()
}

fn free_blob(blob: &mut SecureBlob) {
    // SAFETY: `blob` points to a valid `SecureBlob` and the ABI contract allows
    // freeing null/empty blobs.
    unsafe { libipc_secure_blob_free(blob as *mut SecureBlob) };
}

fn copy_and_free_blob(blob: &mut SecureBlob) -> Vec<u8> {
    if blob.data.is_null() || blob.size == 0 {
        free_blob(blob);
        return Vec::new();
    }

    // SAFETY: On success the C ABI returns a valid allocation of `size` bytes in
    // `data`. We copy the bytes into a Rust-owned Vec before freeing via the ABI.
    let bytes = unsafe { std::slice::from_raw_parts(blob.data, blob.size) }.to_vec();
    free_blob(blob);
    bytes
}

fn seal_with_algorithm<Algorithm, KeyProvider>(
    plain: &[u8],
    nonce: &mut Vec<u8>,
    ciphertext: &mut Vec<u8>,
    tag: &mut Vec<u8>,
) -> bool
where
    Algorithm: OpenSslEvpAlgorithm,
    KeyProvider: OpenSslEvpKeyProvider,
{
    let key = KeyProvider::KEY_BYTES;
    let mut nonce_blob = empty_blob();
    let mut ciphertext_blob = empty_blob();
    let mut tag_blob = empty_blob();

    // SAFETY: All pointers are either null with size 0 or valid for the passed
    // length. Output blob pointers reference valid mutable stack values.
    let status = unsafe {
        libipc_secure_aead_encrypt(
            Algorithm::ABI_ID,
            ptr_or_null(key),
            key.len(),
            ptr_or_null(plain),
            plain.len(),
            std::ptr::null(),
            0,
            &mut nonce_blob,
            &mut ciphertext_blob,
            &mut tag_blob,
        )
    };

    if status != SecureStatus::Ok {
        free_blob(&mut tag_blob);
        free_blob(&mut ciphertext_blob);
        free_blob(&mut nonce_blob);
        nonce.clear();
        ciphertext.clear();
        tag.clear();
        return false;
    }

    *nonce = copy_and_free_blob(&mut nonce_blob);
    *ciphertext = copy_and_free_blob(&mut ciphertext_blob);
    *tag = copy_and_free_blob(&mut tag_blob);
    true
}

fn open_with_algorithm<Algorithm, KeyProvider>(
    nonce: &[u8],
    ciphertext: &[u8],
    tag: &[u8],
    plain: &mut Vec<u8>,
) -> bool
where
    Algorithm: OpenSslEvpAlgorithm,
    KeyProvider: OpenSslEvpKeyProvider,
{
    let key = KeyProvider::KEY_BYTES;
    let mut plain_blob = empty_blob();

    // SAFETY: All pointers are either null with size 0 or valid for the passed
    // length. Output blob pointer references a valid mutable stack value.
    let status = unsafe {
        libipc_secure_aead_decrypt(
            Algorithm::ABI_ID,
            ptr_or_null(key),
            key.len(),
            ptr_or_null(nonce),
            nonce.len(),
            ptr_or_null(ciphertext),
            ciphertext.len(),
            ptr_or_null(tag),
            tag.len(),
            std::ptr::null(),
            0,
            &mut plain_blob,
        )
    };

    if status != SecureStatus::Ok {
        free_blob(&mut plain_blob);
        plain.clear();
        return false;
    }

    *plain = copy_and_free_blob(&mut plain_blob);
    true
}
