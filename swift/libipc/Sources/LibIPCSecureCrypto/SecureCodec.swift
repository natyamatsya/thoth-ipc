// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

import LibIPC

public protocol SecureCipher: Sendable {
    static var algorithmId: UInt16 { get }
    static var keyId: UInt32 { get }

    static func seal(_ plain: [UInt8],
                     nonce: inout [UInt8],
                     ciphertext: inout [UInt8],
                     tag: inout [UInt8]) -> Bool

    static func open(nonce: [UInt8],
                     ciphertext: [UInt8],
                     tag: [UInt8],
                     plain: inout [UInt8]) -> Bool
}

public extension SecureCipher {
    static var algorithmId: UInt16 { 0 }
    static var keyId: UInt32 { 0 }
}

private enum SecureEnvelopeV1 {
    static let magic: [UInt8] = [0x53, 0x49, 0x50, 0x43] // "SIPC"
    static let version: UInt8 = 1

    static let offsetVersion = 4
    static let offsetAlgorithmId = 5
    static let offsetKeyId = 7
    static let offsetNonceSize = 11
    static let offsetTagSize = 13
    static let offsetCiphertextSize = 15
    static let fixedHeaderSize = 19

    struct View {
        let algorithmId: UInt16
        let keyId: UInt32
        let nonce: [UInt8]
        let ciphertext: [UInt8]
        let tag: [UInt8]
    }

    static func appendU16LE(_ value: UInt16, to out: inout [UInt8]) {
        out.append(UInt8(truncatingIfNeeded: value))
        out.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    static func appendU32LE(_ value: UInt32, to out: inout [UInt8]) {
        out.append(UInt8(truncatingIfNeeded: value))
        out.append(UInt8(truncatingIfNeeded: value >> 8))
        out.append(UInt8(truncatingIfNeeded: value >> 16))
        out.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    static func readU16LE(_ bytes: [UInt8], offset: Int) -> UInt16? {
        if offset > bytes.count { return nil }
        if bytes.count - offset < 2 { return nil }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    static func readU32LE(_ bytes: [UInt8], offset: Int) -> UInt32? {
        if offset > bytes.count { return nil }
        if bytes.count - offset < 4 { return nil }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    static func build(algorithmId: UInt16,
                      keyId: UInt32,
                      nonce: [UInt8],
                      ciphertext: [UInt8],
                      tag: [UInt8]) -> [UInt8]? {
        if nonce.count > Int(UInt16.max) { return nil }
        if tag.count > Int(UInt16.max) { return nil }
        if ciphertext.count > Int(UInt32.max) { return nil }

        var out: [UInt8] = []
        out.reserveCapacity(fixedHeaderSize + nonce.count + ciphertext.count + tag.count)
        out.append(contentsOf: magic)
        out.append(version)
        appendU16LE(algorithmId, to: &out)
        appendU32LE(keyId, to: &out)
        appendU16LE(UInt16(nonce.count), to: &out)
        appendU16LE(UInt16(tag.count), to: &out)
        appendU32LE(UInt32(ciphertext.count), to: &out)
        out.append(contentsOf: nonce)
        out.append(contentsOf: ciphertext)
        out.append(contentsOf: tag)
        return out
    }

    static func parse(_ bytes: [UInt8]) -> View? {
        if bytes.count < fixedHeaderSize { return nil }
        if Array(bytes[0..<magic.count]) != magic { return nil }
        if bytes[offsetVersion] != version { return nil }

        guard let algorithmId = readU16LE(bytes, offset: offsetAlgorithmId) else { return nil }
        guard let keyId = readU32LE(bytes, offset: offsetKeyId) else { return nil }
        guard let nonceSize = readU16LE(bytes, offset: offsetNonceSize) else { return nil }
        guard let tagSize = readU16LE(bytes, offset: offsetTagSize) else { return nil }
        guard let ciphertextSize = readU32LE(bytes, offset: offsetCiphertextSize) else { return nil }

        let nonceCount = Int(nonceSize)
        let tagCount = Int(tagSize)
        let ciphertextCount = Int(ciphertextSize)
        let payloadCount = nonceCount + ciphertextCount + tagCount
        if payloadCount < 0 { return nil }
        if bytes.count - fixedHeaderSize != payloadCount { return nil }

        let nonceStart = fixedHeaderSize
        let nonceEnd = nonceStart + nonceCount
        let ciphertextEnd = nonceEnd + ciphertextCount
        let tagEnd = ciphertextEnd + tagCount

        let nonce = Array(bytes[nonceStart..<nonceEnd])
        let ciphertext = Array(bytes[nonceEnd..<ciphertextEnd])
        let tag = Array(bytes[ciphertextEnd..<tagEnd])
        return View(algorithmId: algorithmId,
                    keyId: keyId,
                    nonce: nonce,
                    ciphertext: ciphertext,
                    tag: tag)
    }
}

public struct SecureBuilder<InnerCodec: TypedCodec, Cipher: SecureCipher> {
    public let bytes: [UInt8]

    public init() {
        bytes = []
    }

    public init(inner: InnerCodec.BuilderType) {
        let plain = InnerCodec.encode(builder: inner)
        if plain.isEmpty {
            bytes = []
            return
        }

        var nonce: [UInt8] = []
        var ciphertext: [UInt8] = []
        var tag: [UInt8] = []
        if !Cipher.seal(plain, nonce: &nonce, ciphertext: &ciphertext, tag: &tag) {
            bytes = []
            return
        }

        guard let encoded = SecureEnvelopeV1.build(algorithmId: Cipher.algorithmId,
                                                   keyId: Cipher.keyId,
                                                   nonce: nonce,
                                                   ciphertext: ciphertext,
                                                   tag: tag) else {
            bytes = []
            return
        }
        bytes = encoded
    }

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }
}

public enum SecureCodec<InnerCodec: TypedCodec, Cipher: SecureCipher>: TypedCodec {
    public typealias Root = InnerCodec.Root
    public typealias MessageType = InnerCodec.MessageType
    public typealias BuilderType = SecureBuilder<InnerCodec, Cipher>

    public static var codecId: CodecId { InnerCodec.codecId }

    public static func encode(builder: BuilderType) -> [UInt8] {
        builder.bytes
    }

    public static func decode(buffer: IpcBuffer) -> MessageType {
        guard let envelope = SecureEnvelopeV1.parse(buffer.bytes) else {
            return InnerCodec.decode(buffer: IpcBuffer())
        }
        if envelope.algorithmId != Cipher.algorithmId {
            return InnerCodec.decode(buffer: IpcBuffer())
        }
        if envelope.keyId != Cipher.keyId {
            return InnerCodec.decode(buffer: IpcBuffer())
        }

        var plain: [UInt8] = []
        if !Cipher.open(nonce: envelope.nonce,
                        ciphertext: envelope.ciphertext,
                        tag: envelope.tag,
                        plain: &plain) {
            return InnerCodec.decode(buffer: IpcBuffer())
        }
        return InnerCodec.decode(buffer: IpcBuffer(bytes: plain))
    }

    public static func verify(message: MessageType) -> Bool {
        InnerCodec.verify(message: message)
    }
}

public typealias TypedChannelSecure<T,
                                    InnerCodec: TypedCodec,
                                    Cipher: SecureCipher> =
    TypedChannelCodec<T, SecureCodec<InnerCodec, Cipher>>
where InnerCodec.Root == T

public typealias TypedRouteSecure<T,
                                  InnerCodec: TypedCodec,
                                  Cipher: SecureCipher> =
    TypedRouteCodec<T, SecureCodec<InnerCodec, Cipher>>
where InnerCodec.Root == T
