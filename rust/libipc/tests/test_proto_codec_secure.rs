// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#![cfg(feature = "codec-protobuf")]

use std::sync::atomic::{AtomicUsize, Ordering};

use libipc::buffer::IpcBuffer;
use libipc::channel::Mode;
use libipc::proto::codec::Codec;
use libipc::proto::codecs::protobuf::{
    ProtobufBuilder, ProtobufCodec, ProtobufMessage, ProtobufWireMessage,
};
#[cfg(feature = "secure-crypto-c")]
use libipc::proto::{
    OpenSslEvpKeyProvider, SecureOpenSslEvpBackend, SecureOpenSslEvpCipherAes256Gcm,
};
use libipc::proto::{
    SecureBuilder, SecureCipher, SecureCodec, TypedChannelSecure, TypedRouteSecure,
};

#[derive(Debug, Clone, PartialEq, Eq)]
struct FakeProto {
    value: u32,
}

impl ProtobufWireMessage for FakeProto {
    fn encode(&self) -> Vec<u8> {
        self.value.to_le_bytes().to_vec()
    }

    fn decode(bytes: &[u8]) -> Option<Self> {
        if bytes.len() != std::mem::size_of::<u32>() {
            return None;
        }
        let value = u32::from_le_bytes(bytes.try_into().ok()?);
        Some(Self { value })
    }
}

struct AeadXorCipherOpenFailure;

impl SecureCipher for AeadXorCipherOpenFailure {
    fn algorithm_id() -> u16 {
        AeadXorCipher::algorithm_id()
    }

    fn key_id() -> u32 {
        AeadXorCipher::key_id()
    }

    fn seal(
        plain: &[u8],
        nonce: &mut Vec<u8>,
        ciphertext: &mut Vec<u8>,
        tag: &mut Vec<u8>,
    ) -> bool {
        AeadXorCipher::seal(plain, nonce, ciphertext, tag)
    }

    fn open(_nonce: &[u8], ciphertext: &[u8], _tag: &[u8], plain: &mut Vec<u8>) -> bool {
        *plain = ciphertext.to_vec();
        false
    }
}

static COUNTER: AtomicUsize = AtomicUsize::new(0);

fn unique_name(prefix: &str) -> String {
    let id = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}_{}_{}", std::process::id(), id)
}

struct AeadXorCipher;

impl SecureCipher for AeadXorCipher {
    fn algorithm_id() -> u16 {
        0x4210
    }

    fn key_id() -> u32 {
        0x1234_5678
    }

    fn seal(
        plain: &[u8],
        nonce: &mut Vec<u8>,
        ciphertext: &mut Vec<u8>,
        tag: &mut Vec<u8>,
    ) -> bool {
        *nonce = vec![
            0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B,
        ];
        *ciphertext = plain.iter().map(|byte| byte ^ 0x5A).collect();

        let checksum = ciphertext.iter().fold(0u8, |acc, byte| acc ^ byte);
        *tag = vec![
            checksum,
            (ciphertext.len() & 0xFF) as u8,
            ((ciphertext.len() >> 8) & 0xFF) as u8,
            nonce.len() as u8,
        ];
        true
    }

    fn open(nonce: &[u8], ciphertext: &[u8], tag: &[u8], plain: &mut Vec<u8>) -> bool {
        if nonce.len() != 12 {
            return false;
        }
        if tag.len() != 4 {
            return false;
        }

        let checksum = ciphertext.iter().fold(0u8, |acc, byte| acc ^ byte);
        if tag[0] != checksum {
            return false;
        }
        if tag[1] != (ciphertext.len() & 0xFF) as u8 {
            return false;
        }
        if tag[2] != ((ciphertext.len() >> 8) & 0xFF) as u8 {
            return false;
        }
        if tag[3] != nonce.len() as u8 {
            return false;
        }

        *plain = ciphertext.iter().map(|byte| byte ^ 0x5A).collect();
        true
    }
}

struct AeadXorCipherAlgorithmMismatch;

impl SecureCipher for AeadXorCipherAlgorithmMismatch {
    fn algorithm_id() -> u16 {
        AeadXorCipher::algorithm_id() + 1
    }

    fn key_id() -> u32 {
        AeadXorCipher::key_id()
    }

    fn seal(
        plain: &[u8],
        nonce: &mut Vec<u8>,
        ciphertext: &mut Vec<u8>,
        tag: &mut Vec<u8>,
    ) -> bool {
        AeadXorCipher::seal(plain, nonce, ciphertext, tag)
    }

    fn open(nonce: &[u8], ciphertext: &[u8], tag: &[u8], plain: &mut Vec<u8>) -> bool {
        AeadXorCipher::open(nonce, ciphertext, tag, plain)
    }
}

struct AeadXorCipherKeyMismatch;

impl SecureCipher for AeadXorCipherKeyMismatch {
    fn algorithm_id() -> u16 {
        AeadXorCipher::algorithm_id()
    }

    fn key_id() -> u32 {
        AeadXorCipher::key_id() + 1
    }

    fn seal(
        plain: &[u8],
        nonce: &mut Vec<u8>,
        ciphertext: &mut Vec<u8>,
        tag: &mut Vec<u8>,
    ) -> bool {
        AeadXorCipher::seal(plain, nonce, ciphertext, tag)
    }

    fn open(nonce: &[u8], ciphertext: &[u8], tag: &[u8], plain: &mut Vec<u8>) -> bool {
        AeadXorCipher::open(nonce, ciphertext, tag, plain)
    }
}

type SecureAeadCodec = SecureCodec<ProtobufCodec, AeadXorCipher>;
type SecureAeadFailOpenCodec = SecureCodec<ProtobufCodec, AeadXorCipherOpenFailure>;

type SecureAeadBuilder = SecureBuilder<ProtobufCodec, AeadXorCipher, FakeProto>;
type SecureAeadFailOpenBuilder = SecureBuilder<ProtobufCodec, AeadXorCipherOpenFailure, FakeProto>;
type SecureAeadAlgorithmMismatchBuilder =
    SecureBuilder<ProtobufCodec, AeadXorCipherAlgorithmMismatch, FakeProto>;
type SecureAeadKeyMismatchBuilder =
    SecureBuilder<ProtobufCodec, AeadXorCipherKeyMismatch, FakeProto>;

type SecureAeadRoute = TypedRouteSecure<FakeProto, ProtobufCodec, AeadXorCipher>;
type SecureAeadChannel = TypedChannelSecure<FakeProto, ProtobufCodec, AeadXorCipher>;

#[cfg(feature = "secure-crypto-c")]
struct OpenSslKeyProvider;

#[cfg(feature = "secure-crypto-c")]
impl OpenSslEvpKeyProvider for OpenSslKeyProvider {
    const KEY_ID: u32 = 0x0A0B_0C0D;
    const KEY_BYTES: &'static [u8] = &[
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E,
        0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D,
        0x1E, 0x1F,
    ];
}

#[cfg(feature = "secure-crypto-c")]
struct OpenSslWrongKeyProvider;

#[cfg(feature = "secure-crypto-c")]
impl OpenSslEvpKeyProvider for OpenSslWrongKeyProvider {
    const KEY_ID: u32 = OpenSslKeyProvider::KEY_ID;
    const KEY_BYTES: &'static [u8] = &[
        0xF0, 0xE1, 0xD2, 0xC3, 0xB4, 0xA5, 0x96, 0x87, 0x78, 0x69, 0x5A, 0x4B, 0x3C, 0x2D, 0x1E,
        0x0F, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD,
        0xEE, 0xFF,
    ];
}

#[cfg(feature = "secure-crypto-c")]
struct OpenSslMismatchedKeyIdProvider;

#[cfg(feature = "secure-crypto-c")]
impl OpenSslEvpKeyProvider for OpenSslMismatchedKeyIdProvider {
    const KEY_ID: u32 = OpenSslKeyProvider::KEY_ID + 1;
    const KEY_BYTES: &'static [u8] = OpenSslKeyProvider::KEY_BYTES;
}

#[cfg(feature = "secure-crypto-c")]
type SecureOpenSslCodec =
    SecureCodec<ProtobufCodec, SecureOpenSslEvpCipherAes256Gcm<OpenSslKeyProvider>>;
#[cfg(feature = "secure-crypto-c")]
type SecureOpenSslWrongKeyCodec =
    SecureCodec<ProtobufCodec, SecureOpenSslEvpCipherAes256Gcm<OpenSslWrongKeyProvider>>;
#[cfg(feature = "secure-crypto-c")]
type SecureOpenSslMismatchedKeyIdCodec =
    SecureCodec<ProtobufCodec, SecureOpenSslEvpCipherAes256Gcm<OpenSslMismatchedKeyIdProvider>>;
#[cfg(feature = "secure-crypto-c")]
type SecureOpenSslBuilder =
    SecureBuilder<ProtobufCodec, SecureOpenSslEvpCipherAes256Gcm<OpenSslKeyProvider>, FakeProto>;

#[test]
fn aead_secure_codec_round_trip() {
    let inner = ProtobufBuilder::from_message(&FakeProto { value: 42 });
    let secure_builder = SecureAeadBuilder::from_inner(&inner);
    assert!(secure_builder.bytes().len() > inner.bytes().len());

    let decoded: ProtobufMessage<FakeProto> =
        SecureAeadCodec::decode(IpcBuffer::from_slice(secure_builder.bytes()));
    assert!(SecureAeadCodec::verify(&decoded));
    assert_eq!(decoded.root().map(|message| message.value), Some(42));
}

#[test]
fn aead_open_failure_is_fail_closed() {
    let inner = ProtobufBuilder::from_message(&FakeProto { value: 7 });
    let secure_builder = SecureAeadFailOpenBuilder::from_inner(&inner);

    let decoded: ProtobufMessage<FakeProto> =
        SecureAeadFailOpenCodec::decode(IpcBuffer::from_slice(secure_builder.bytes()));
    assert!(decoded.is_empty());
    assert!(!decoded.is_valid());
}

#[test]
fn missing_envelope_fails_closed() {
    let decoded: ProtobufMessage<FakeProto> =
        SecureAeadCodec::decode(IpcBuffer::from_slice(&[0x01, 0x02, 0x03, 0x04]));
    assert!(decoded.is_empty());
    assert!(!decoded.is_valid());
}

#[test]
fn aead_algorithm_mismatch_fails_closed() {
    let inner = ProtobufBuilder::from_message(&FakeProto { value: 13 });
    let secure_builder = SecureAeadAlgorithmMismatchBuilder::from_inner(&inner);

    let decoded: ProtobufMessage<FakeProto> =
        SecureAeadCodec::decode(IpcBuffer::from_slice(secure_builder.bytes()));
    assert!(decoded.is_empty());
    assert!(!decoded.is_valid());
}

#[test]
fn aead_key_mismatch_fails_closed() {
    let inner = ProtobufBuilder::from_message(&FakeProto { value: 21 });
    let secure_builder = SecureAeadKeyMismatchBuilder::from_inner(&inner);

    let decoded: ProtobufMessage<FakeProto> =
        SecureAeadCodec::decode(IpcBuffer::from_slice(secure_builder.bytes()));
    assert!(decoded.is_empty());
    assert!(!decoded.is_valid());
}

#[test]
fn aead_tampered_tag_fails_closed() {
    let inner = ProtobufBuilder::from_message(&FakeProto { value: 77 });
    let secure_builder = SecureAeadBuilder::from_inner(&inner);

    let mut tampered = secure_builder.bytes().to_vec();
    let last = tampered.len() - 1;
    tampered[last] ^= 0x7F;

    let decoded: ProtobufMessage<FakeProto> =
        SecureAeadCodec::decode(IpcBuffer::from_vec(tampered));
    assert!(decoded.is_empty());
    assert!(!decoded.is_valid());
}

#[test]
fn aead_truncated_envelope_fails_closed() {
    let inner = ProtobufBuilder::from_message(&FakeProto { value: 88 });
    let secure_builder = SecureAeadBuilder::from_inner(&inner);

    let mut truncated = secure_builder.bytes().to_vec();
    truncated.pop();

    let decoded: ProtobufMessage<FakeProto> =
        SecureAeadCodec::decode(IpcBuffer::from_vec(truncated));
    assert!(decoded.is_empty());
    assert!(!decoded.is_valid());
}

#[test]
fn typed_route_secure_round_trip() {
    let name = unique_name("secure_route");
    SecureAeadRoute::clear_storage(&name);

    let mut sender = SecureAeadRoute::connect(&name, Mode::Sender).expect("sender");
    let mut receiver = SecureAeadRoute::connect(&name, Mode::Receiver).expect("receiver");

    sender
        .raw()
        .wait_for_recv(1, Some(1000))
        .expect("wait_for_recv");

    let inner = ProtobufBuilder::from_message(&FakeProto { value: 123 });
    let secure_builder = SecureAeadBuilder::from_inner(&inner);
    assert!(sender
        .send_builder(&secure_builder, 1000)
        .expect("send_builder"));

    let message = receiver.recv(Some(1000)).expect("recv");
    assert_eq!(message.root().map(|msg| msg.value), Some(123));

    drop(sender);
    drop(receiver);
    SecureAeadRoute::clear_storage(&name);
}

#[test]
fn typed_channel_secure_round_trip() {
    let name = unique_name("secure_channel");
    SecureAeadChannel::clear_storage(&name);

    let mut sender = SecureAeadChannel::connect(&name, Mode::Sender).expect("sender");
    let mut receiver = SecureAeadChannel::connect(&name, Mode::Receiver).expect("receiver");

    sender
        .raw()
        .wait_for_recv(1, Some(1000))
        .expect("wait_for_recv");

    let inner = ProtobufBuilder::from_message(&FakeProto { value: 456 });
    let secure_builder = SecureAeadBuilder::from_inner(&inner);
    assert!(sender
        .send_builder(&secure_builder, 1000)
        .expect("send_builder"));

    let message = receiver.recv(Some(1000)).expect("recv");
    assert_eq!(message.root().map(|msg| msg.value), Some(456));

    drop(sender);
    drop(receiver);
    SecureAeadChannel::clear_storage(&name);
}

#[cfg(feature = "secure-crypto-c")]
#[test]
fn openssl_aes256gcm_round_trip() {
    if !SecureOpenSslEvpBackend::is_available() {
        return;
    }

    let inner = ProtobufBuilder::from_message(&FakeProto { value: 0x1020_3040 });
    let secure_builder = SecureOpenSslBuilder::from_inner(&inner);

    let decoded: ProtobufMessage<FakeProto> =
        SecureOpenSslCodec::decode(IpcBuffer::from_slice(secure_builder.bytes()));
    assert!(decoded.is_valid());
    assert_eq!(
        decoded.root().map(|message| message.value),
        Some(0x1020_3040)
    );
}

#[cfg(feature = "secure-crypto-c")]
#[test]
fn openssl_key_id_mismatch_fails_closed() {
    if !SecureOpenSslEvpBackend::is_available() {
        return;
    }

    let inner = ProtobufBuilder::from_message(&FakeProto { value: 0x5566_7788 });
    let secure_builder = SecureOpenSslBuilder::from_inner(&inner);

    let decoded: ProtobufMessage<FakeProto> =
        SecureOpenSslMismatchedKeyIdCodec::decode(IpcBuffer::from_slice(secure_builder.bytes()));
    assert!(decoded.is_empty());
    assert!(!decoded.is_valid());
}

#[cfg(feature = "secure-crypto-c")]
#[test]
fn openssl_wrong_key_material_fails_closed() {
    if !SecureOpenSslEvpBackend::is_available() {
        return;
    }

    let inner = ProtobufBuilder::from_message(&FakeProto { value: 0x6677_8899 });
    let secure_builder = SecureOpenSslBuilder::from_inner(&inner);

    let decoded: ProtobufMessage<FakeProto> =
        SecureOpenSslWrongKeyCodec::decode(IpcBuffer::from_slice(secure_builder.bytes()));
    assert!(decoded.is_empty());
    assert!(!decoded.is_valid());
}

#[cfg(feature = "secure-crypto-c")]
#[test]
fn openssl_tampered_tag_fails_closed() {
    if !SecureOpenSslEvpBackend::is_available() {
        return;
    }

    let inner = ProtobufBuilder::from_message(&FakeProto { value: 0xABCD_EF12 });
    let secure_builder = SecureOpenSslBuilder::from_inner(&inner);

    let mut tampered = secure_builder.bytes().to_vec();
    let last = tampered.len() - 1;
    tampered[last] ^= 0x7F;

    let decoded: ProtobufMessage<FakeProto> =
        SecureOpenSslCodec::decode(IpcBuffer::from_vec(tampered));
    assert!(decoded.is_empty());
    assert!(!decoded.is_valid());
}
