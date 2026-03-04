// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

import LibIPCSecureCryptoC

public enum SecureOpenSSLEVPBackend {
    public static var isAvailable: Bool {
        libipc_secure_crypto_available() != 0
    }
}

public protocol OpenSSLEVPKeyProvider: Sendable {
    static var keyId: UInt32 { get }
    static var keyBytes: [UInt8] { get }
}

private func withOptionalUnsafeBytes<R>(_ bytes: [UInt8],
                                        _ body: (UnsafePointer<UInt8>?, Int) -> R) -> R {
    bytes.withUnsafeBufferPointer { buffer in
        body(buffer.baseAddress, buffer.count)
    }
}

private func toBytes(_ blob: libipc_secure_blob) -> [UInt8] {
    if blob.size == 0 { return [] }
    guard let base = blob.data else { return [] }
    return Array(UnsafeBufferPointer(start: base, count: Int(blob.size)))
}

private func statusIsOK(_ status: libipc_secure_status) -> Bool {
    UInt32(status) == UInt32(LIBIPC_SECURE_STATUS_OK)
}

private func sealOpenSSL(algorithm: libipc_secure_algorithm_id,
                         keyBytes: [UInt8],
                         plain: [UInt8],
                         nonce: inout [UInt8],
                         ciphertext: inout [UInt8],
                         tag: inout [UInt8]) -> Bool {
    var nonceBlob = libipc_secure_blob(data: nil, size: 0)
    var ciphertextBlob = libipc_secure_blob(data: nil, size: 0)
    var tagBlob = libipc_secure_blob(data: nil, size: 0)

    defer {
        libipc_secure_blob_free(&tagBlob)
        libipc_secure_blob_free(&ciphertextBlob)
        libipc_secure_blob_free(&nonceBlob)
    }

    let status = withOptionalUnsafeBytes(keyBytes) { keyPtr, keyCount in
        withOptionalUnsafeBytes(plain) { plainPtr, plainCount in
            libipc_secure_aead_encrypt(
                algorithm,
                keyPtr,
                keyCount,
                plainPtr,
                plainCount,
                nil,
                0,
                &nonceBlob,
                &ciphertextBlob,
                &tagBlob)
        }
    }

    if !statusIsOK(status) {
        nonce.removeAll(keepingCapacity: true)
        ciphertext.removeAll(keepingCapacity: true)
        tag.removeAll(keepingCapacity: true)
        return false
    }

    nonce = toBytes(nonceBlob)
    ciphertext = toBytes(ciphertextBlob)
    tag = toBytes(tagBlob)
    return true
}

private func openOpenSSL(algorithm: libipc_secure_algorithm_id,
                         keyBytes: [UInt8],
                         nonce: [UInt8],
                         ciphertext: [UInt8],
                         tag: [UInt8],
                         plain: inout [UInt8]) -> Bool {
    var plainBlob = libipc_secure_blob(data: nil, size: 0)
    defer { libipc_secure_blob_free(&plainBlob) }

    let status = withOptionalUnsafeBytes(keyBytes) { keyPtr, keyCount in
        withOptionalUnsafeBytes(nonce) { noncePtr, nonceCount in
            withOptionalUnsafeBytes(ciphertext) { ciphertextPtr, ciphertextCount in
                withOptionalUnsafeBytes(tag) { tagPtr, tagCount in
                    libipc_secure_aead_decrypt(
                        algorithm,
                        keyPtr,
                        keyCount,
                        noncePtr,
                        nonceCount,
                        ciphertextPtr,
                        ciphertextCount,
                        tagPtr,
                        tagCount,
                        nil,
                        0,
                        &plainBlob)
                }
            }
        }
    }

    if !statusIsOK(status) {
        plain.removeAll(keepingCapacity: true)
        return false
    }

    plain = toBytes(plainBlob)
    return true
}

public struct SecureOpenSSLEVPCipherAES256GCM<KeyProvider: OpenSSLEVPKeyProvider>: SecureCipher {
    public static var algorithmId: UInt16 {
        UInt16(LIBIPC_SECURE_ALG_AES_256_GCM)
    }

    public static var keyId: UInt32 {
        KeyProvider.keyId
    }

    public static func seal(_ plain: [UInt8],
                            nonce: inout [UInt8],
                            ciphertext: inout [UInt8],
                            tag: inout [UInt8]) -> Bool {
        sealOpenSSL(algorithm: UInt32(LIBIPC_SECURE_ALG_AES_256_GCM),
                    keyBytes: KeyProvider.keyBytes,
                    plain: plain,
                    nonce: &nonce,
                    ciphertext: &ciphertext,
                    tag: &tag)
    }

    public static func open(nonce: [UInt8],
                            ciphertext: [UInt8],
                            tag: [UInt8],
                            plain: inout [UInt8]) -> Bool {
        openOpenSSL(algorithm: UInt32(LIBIPC_SECURE_ALG_AES_256_GCM),
                    keyBytes: KeyProvider.keyBytes,
                    nonce: nonce,
                    ciphertext: ciphertext,
                    tag: tag,
                    plain: &plain)
    }
}

public struct SecureOpenSSLEVPCipherChaCha20Poly1305<KeyProvider: OpenSSLEVPKeyProvider>: SecureCipher {
    public static var algorithmId: UInt16 {
        UInt16(LIBIPC_SECURE_ALG_CHACHA20_POLY1305)
    }

    public static var keyId: UInt32 {
        KeyProvider.keyId
    }

    public static func seal(_ plain: [UInt8],
                            nonce: inout [UInt8],
                            ciphertext: inout [UInt8],
                            tag: inout [UInt8]) -> Bool {
        sealOpenSSL(algorithm: UInt32(LIBIPC_SECURE_ALG_CHACHA20_POLY1305),
                    keyBytes: KeyProvider.keyBytes,
                    plain: plain,
                    nonce: &nonce,
                    ciphertext: &ciphertext,
                    tag: &tag)
    }

    public static func open(nonce: [UInt8],
                            ciphertext: [UInt8],
                            tag: [UInt8],
                            plain: inout [UInt8]) -> Bool {
        openOpenSSL(algorithm: UInt32(LIBIPC_SECURE_ALG_CHACHA20_POLY1305),
                    keyBytes: KeyProvider.keyBytes,
                    nonce: nonce,
                    ciphertext: ciphertext,
                    tag: tag,
                    plain: &plain)
    }
}
