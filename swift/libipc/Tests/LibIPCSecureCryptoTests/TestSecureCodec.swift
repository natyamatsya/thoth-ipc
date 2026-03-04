// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

import Testing
import LibIPC
@testable import LibIPCSecureCrypto

private struct FakeProtoMessage: ProtobufWireMessage, Equatable {
    let value: UInt32

    init(value: UInt32) {
        self.value = value
    }

    init?(serializedBytes: [UInt8]) {
        if serializedBytes.count != MemoryLayout<UInt32>.size { return nil }
        let value = UInt32(serializedBytes[0])
            | UInt32(serializedBytes[1]) << 8
            | UInt32(serializedBytes[2]) << 16
            | UInt32(serializedBytes[3]) << 24
        self.init(value: value)
    }

    func serializedBytes() -> [UInt8] {
        let le = value.littleEndian
        return [
            UInt8(truncatingIfNeeded: le),
            UInt8(truncatingIfNeeded: le >> 8),
            UInt8(truncatingIfNeeded: le >> 16),
            UInt8(truncatingIfNeeded: le >> 24),
        ]
    }
}

private struct LegacyXorCipher: SecureCipherLegacy {
    static func seal(_ plain: [UInt8], out: inout [UInt8]) -> Bool {
        out = plain.map { $0 ^ 0xA5 }
        return true
    }

    static func open(_ ciphertext: [UInt8], out: inout [UInt8]) -> Bool {
        seal(ciphertext, out: &out)
    }
}

private struct FailingLegacyXorCipher: SecureCipherLegacy {
    static func seal(_ plain: [UInt8], out: inout [UInt8]) -> Bool {
        out = plain.map { $0 ^ 0xA5 }
        return true
    }

    static func open(_ ciphertext: [UInt8], out: inout [UInt8]) -> Bool {
        out = ciphertext
        return false
    }
}

private struct AeadXorCipher: SecureCipher {
    static let algorithmId: UInt16 = 0x4210
    static let keyId: UInt32 = 0x1234_5678

    static func seal(_ plain: [UInt8],
                     nonce: inout [UInt8],
                     ciphertext: inout [UInt8],
                     tag: inout [UInt8]) -> Bool {
        nonce = [0x10, 0x11, 0x12, 0x13, 0x14, 0x15,
                 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B]
        ciphertext = plain.map { $0 ^ 0x5A }
        var checksum: UInt8 = 0
        for byte in ciphertext {
            checksum ^= byte
        }
        tag = [
            checksum,
            UInt8(truncatingIfNeeded: ciphertext.count),
            UInt8(truncatingIfNeeded: ciphertext.count >> 8),
            UInt8(nonce.count),
        ]
        return true
    }

    static func open(nonce: [UInt8],
                     ciphertext: [UInt8],
                     tag: [UInt8],
                     plain: inout [UInt8]) -> Bool {
        if nonce.count != 12 { return false }
        if tag.count != 4 { return false }

        var checksum: UInt8 = 0
        for byte in ciphertext {
            checksum ^= byte
        }

        if tag[0] != checksum { return false }
        if tag[1] != UInt8(truncatingIfNeeded: ciphertext.count) { return false }
        if tag[2] != UInt8(truncatingIfNeeded: ciphertext.count >> 8) { return false }
        if tag[3] != UInt8(nonce.count) { return false }

        plain = ciphertext.map { $0 ^ 0x5A }
        return true
    }
}

private struct AeadXorCipherAlgorithmMismatch: SecureCipher {
    static let algorithmId: UInt16 = AeadXorCipher.algorithmId + 1
    static let keyId: UInt32 = AeadXorCipher.keyId

    static func seal(_ plain: [UInt8],
                     nonce: inout [UInt8],
                     ciphertext: inout [UInt8],
                     tag: inout [UInt8]) -> Bool {
        AeadXorCipher.seal(plain, nonce: &nonce, ciphertext: &ciphertext, tag: &tag)
    }

    static func open(nonce: [UInt8],
                     ciphertext: [UInt8],
                     tag: [UInt8],
                     plain: inout [UInt8]) -> Bool {
        AeadXorCipher.open(nonce: nonce, ciphertext: ciphertext, tag: tag, plain: &plain)
    }
}

private struct AeadXorCipherKeyMismatch: SecureCipher {
    static let algorithmId: UInt16 = AeadXorCipher.algorithmId
    static let keyId: UInt32 = AeadXorCipher.keyId + 1

    static func seal(_ plain: [UInt8],
                     nonce: inout [UInt8],
                     ciphertext: inout [UInt8],
                     tag: inout [UInt8]) -> Bool {
        AeadXorCipher.seal(plain, nonce: &nonce, ciphertext: &ciphertext, tag: &tag)
    }

    static func open(nonce: [UInt8],
                     ciphertext: [UInt8],
                     tag: [UInt8],
                     plain: inout [UInt8]) -> Bool {
        AeadXorCipher.open(nonce: nonce, ciphertext: ciphertext, tag: tag, plain: &plain)
    }
}

private typealias SecureLegacyCodec = SecureCodec<ProtobufCodec<FakeProtoMessage>, LegacyXorCipher>
private typealias SecureLegacyFailOpenCodec = SecureCodec<ProtobufCodec<FakeProtoMessage>, FailingLegacyXorCipher>
private typealias SecureAEADCodec = SecureCodec<ProtobufCodec<FakeProtoMessage>, AeadXorCipher>
private typealias SecureAEADAlgorithmMismatchCodec = SecureCodec<ProtobufCodec<FakeProtoMessage>, AeadXorCipherAlgorithmMismatch>
private typealias SecureAEADKeyMismatchCodec = SecureCodec<ProtobufCodec<FakeProtoMessage>, AeadXorCipherKeyMismatch>

private struct OpenSSLKeyProvider: OpenSSLEVPKeyProvider {
    static let keyId: UInt32 = 0x0A0B_0C0D
    static let keyBytes: [UInt8] = [
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
    ]
}

private struct OpenSSLWrongKeyProvider: OpenSSLEVPKeyProvider {
    static let keyId: UInt32 = OpenSSLKeyProvider.keyId
    static let keyBytes: [UInt8] = [
        0xF0, 0xE1, 0xD2, 0xC3, 0xB4, 0xA5, 0x96, 0x87,
        0x78, 0x69, 0x5A, 0x4B, 0x3C, 0x2D, 0x1E, 0x0F,
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
    ]
}

private struct OpenSSLMismatchedKeyIdProvider: OpenSSLEVPKeyProvider {
    static let keyId: UInt32 = OpenSSLKeyProvider.keyId + 1
    static let keyBytes: [UInt8] = OpenSSLKeyProvider.keyBytes
}

private typealias SecureOpenSSLCodec = SecureCodec<ProtobufCodec<FakeProtoMessage>, SecureOpenSSLEVPCipherAES256GCM<OpenSSLKeyProvider>>
private typealias SecureOpenSSLWrongKeyCodec = SecureCodec<ProtobufCodec<FakeProtoMessage>, SecureOpenSSLEVPCipherAES256GCM<OpenSSLWrongKeyProvider>>
private typealias SecureOpenSSLMismatchedKeyIdCodec = SecureCodec<ProtobufCodec<FakeProtoMessage>, SecureOpenSSLEVPCipherAES256GCM<OpenSSLMismatchedKeyIdProvider>>

@Suite("Secure codec parity")
struct TestSecureCodec {

    @Test("legacy secure codec round-trip")
    func legacyRoundTrip() {
        let inner = ProtobufBuilder(message: FakeProtoMessage(value: 42))
        let secureBuilder = SecureBuilder<ProtobufCodec<FakeProtoMessage>, LegacyXorCipher>(inner: inner)
        #expect(secureBuilder.bytes.count > inner.bytes.count)

        let decoded = SecureLegacyCodec.decode(buffer: IpcBuffer(bytes: secureBuilder.bytes))
        #expect(decoded.isValid)
        #expect(decoded.root()?.value == 42)
    }

    @Test("legacy open failure is fail-closed")
    func legacyOpenFailClosed() {
        let inner = ProtobufBuilder(message: FakeProtoMessage(value: 7))
        let secureBuilder = SecureBuilder<ProtobufCodec<FakeProtoMessage>, FailingLegacyXorCipher>(inner: inner)

        let decoded = SecureLegacyFailOpenCodec.decode(buffer: IpcBuffer(bytes: secureBuilder.bytes))
        #expect(decoded.isEmpty)
        #expect(!decoded.isValid)
    }

    @Test("missing envelope fails closed")
    func missingEnvelopeFailClosed() {
        let decoded = SecureLegacyCodec.decode(buffer: IpcBuffer(bytes: [0x01, 0x02, 0x03, 0x04]))
        #expect(decoded.isEmpty)
        #expect(!decoded.isValid)
    }

    @Test("aead secure codec round-trip")
    func aeadRoundTrip() {
        let inner = ProtobufBuilder(message: FakeProtoMessage(value: 99))
        let secureBuilder = SecureBuilder<ProtobufCodec<FakeProtoMessage>, AeadXorCipher>(inner: inner)
        #expect(secureBuilder.bytes.count > inner.bytes.count)

        let decoded = SecureAEADCodec.decode(buffer: IpcBuffer(bytes: secureBuilder.bytes))
        #expect(decoded.isValid)
        #expect(decoded.root()?.value == 99)
    }

    @Test("aead algorithm mismatch fails closed")
    func aeadAlgorithmMismatchFailClosed() {
        let inner = ProtobufBuilder(message: FakeProtoMessage(value: 13))
        let secureBuilder = SecureBuilder<ProtobufCodec<FakeProtoMessage>, AeadXorCipherAlgorithmMismatch>(inner: inner)

        let decoded = SecureAEADCodec.decode(buffer: IpcBuffer(bytes: secureBuilder.bytes))
        #expect(decoded.isEmpty)
        #expect(!decoded.isValid)
    }

    @Test("aead key mismatch fails closed")
    func aeadKeyMismatchFailClosed() {
        let inner = ProtobufBuilder(message: FakeProtoMessage(value: 21))
        let secureBuilder = SecureBuilder<ProtobufCodec<FakeProtoMessage>, AeadXorCipherKeyMismatch>(inner: inner)

        let decoded = SecureAEADCodec.decode(buffer: IpcBuffer(bytes: secureBuilder.bytes))
        #expect(decoded.isEmpty)
        #expect(!decoded.isValid)
    }

    @Test("aead tampered tag fails closed")
    func aeadTamperedTagFailClosed() {
        let inner = ProtobufBuilder(message: FakeProtoMessage(value: 77))
        let secureBuilder = SecureBuilder<ProtobufCodec<FakeProtoMessage>, AeadXorCipher>(inner: inner)
        var tampered = secureBuilder.bytes
        tampered[tampered.count - 1] ^= 0x7F

        let decoded = SecureAEADCodec.decode(buffer: IpcBuffer(bytes: tampered))
        #expect(decoded.isEmpty)
        #expect(!decoded.isValid)
    }

    @Test("aead truncated envelope fails closed")
    func aeadTruncatedEnvelopeFailClosed() {
        let inner = ProtobufBuilder(message: FakeProtoMessage(value: 88))
        let secureBuilder = SecureBuilder<ProtobufCodec<FakeProtoMessage>, AeadXorCipher>(inner: inner)
        var truncated = secureBuilder.bytes
        truncated.removeLast()

        let decoded = SecureAEADCodec.decode(buffer: IpcBuffer(bytes: truncated))
        #expect(decoded.isEmpty)
        #expect(!decoded.isValid)
    }

    @Test("typed route secure round-trip")
    func typedRouteSecureRoundTrip() async throws {
        let name = "swift_secure_route_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await TypedRouteSecure<FakeProtoMessage, ProtobufCodec<FakeProtoMessage>, AeadXorCipher>.clearStorage(name: name) } }

        let sender = try await TypedRouteSecure<FakeProtoMessage, ProtobufCodec<FakeProtoMessage>, AeadXorCipher>.connect(name: name, mode: .sender)
        let receiver = try await TypedRouteSecure<FakeProtoMessage, ProtobufCodec<FakeProtoMessage>, AeadXorCipher>.connect(name: name, mode: .receiver)

        _ = try sender.waitForRecv(count: 1, timeout: .seconds(1))
        let inner = ProtobufBuilder(message: FakeProtoMessage(value: 123))
        let secureBuilder = SecureBuilder<ProtobufCodec<FakeProtoMessage>, AeadXorCipher>(inner: inner)
        _ = try sender.send(builder: secureBuilder, timeout: .seconds(1))

        let message = try receiver.recv(timeout: .seconds(1))
        #expect(message.root()?.value == 123)

        sender.disconnect()
        receiver.disconnect()
    }

    @Test("typed channel secure round-trip")
    func typedChannelSecureRoundTrip() async throws {
        let name = "swift_secure_channel_\(UInt32.random(in: 0..<UInt32.max))"
        defer { Task { await TypedChannelSecure<FakeProtoMessage, ProtobufCodec<FakeProtoMessage>, AeadXorCipher>.clearStorage(name: name) } }

        let sender = try await TypedChannelSecure<FakeProtoMessage, ProtobufCodec<FakeProtoMessage>, AeadXorCipher>.connect(name: name, mode: .sender)
        let receiver = try await TypedChannelSecure<FakeProtoMessage, ProtobufCodec<FakeProtoMessage>, AeadXorCipher>.connect(name: name, mode: .receiver)

        _ = try sender.waitForRecv(count: 1, timeout: .seconds(1))
        let inner = ProtobufBuilder(message: FakeProtoMessage(value: 456))
        let secureBuilder = SecureBuilder<ProtobufCodec<FakeProtoMessage>, AeadXorCipher>(inner: inner)
        _ = try sender.send(builder: secureBuilder, timeout: .seconds(1))

        let message = try receiver.recv(timeout: .seconds(1))
        #expect(message.root()?.value == 456)

        sender.disconnect()
        receiver.disconnect()
    }

    @Test("openssl aes256gcm round-trip")
    func openSslRoundTrip() {
        if !SecureOpenSSLEVPBackend.isAvailable { return }

        let inner = ProtobufBuilder(message: FakeProtoMessage(value: 0x10203040))
        let secureBuilder = SecureBuilder<ProtobufCodec<FakeProtoMessage>, SecureOpenSSLEVPCipherAES256GCM<OpenSSLKeyProvider>>(inner: inner)

        let decoded = SecureOpenSSLCodec.decode(buffer: IpcBuffer(bytes: secureBuilder.bytes))
        #expect(decoded.isValid)
        #expect(decoded.root()?.value == 0x10203040)
    }

    @Test("openssl key-id mismatch fails closed")
    func openSslKeyIdMismatchFailClosed() {
        if !SecureOpenSSLEVPBackend.isAvailable { return }

        let inner = ProtobufBuilder(message: FakeProtoMessage(value: 0x55667788))
        let secureBuilder = SecureBuilder<ProtobufCodec<FakeProtoMessage>, SecureOpenSSLEVPCipherAES256GCM<OpenSSLKeyProvider>>(inner: inner)

        let decoded = SecureOpenSSLMismatchedKeyIdCodec.decode(buffer: IpcBuffer(bytes: secureBuilder.bytes))
        #expect(decoded.isEmpty)
        #expect(!decoded.isValid)
    }

    @Test("openssl wrong key material fails closed")
    func openSslWrongKeyFailClosed() {
        if !SecureOpenSSLEVPBackend.isAvailable { return }

        let inner = ProtobufBuilder(message: FakeProtoMessage(value: 0x66778899))
        let secureBuilder = SecureBuilder<ProtobufCodec<FakeProtoMessage>, SecureOpenSSLEVPCipherAES256GCM<OpenSSLKeyProvider>>(inner: inner)

        let decoded = SecureOpenSSLWrongKeyCodec.decode(buffer: IpcBuffer(bytes: secureBuilder.bytes))
        #expect(decoded.isEmpty)
        #expect(!decoded.isValid)
    }

    @Test("openssl tampered tag fails closed")
    func openSslTamperedTagFailClosed() {
        if !SecureOpenSSLEVPBackend.isAvailable { return }

        let inner = ProtobufBuilder(message: FakeProtoMessage(value: 0xABCDEF12))
        let secureBuilder = SecureBuilder<ProtobufCodec<FakeProtoMessage>, SecureOpenSSLEVPCipherAES256GCM<OpenSSLKeyProvider>>(inner: inner)
        var tampered = secureBuilder.bytes
        tampered[tampered.count - 1] ^= 0x7F

        let decoded = SecureOpenSSLCodec.decode(buffer: IpcBuffer(bytes: tampered))
        #expect(decoded.isEmpty)
        #expect(!decoded.isValid)
    }
}
