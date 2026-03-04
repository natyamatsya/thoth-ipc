// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#![cfg(feature = "codec-capnp")]

use libipc::buffer::IpcBuffer;
use libipc::proto::codec::Codec;
use libipc::proto::codecs::capnp::{CapnpBuilder, CapnpCodec, CapnpMessage, CapnpWireMessage};

#[derive(Debug, Clone, PartialEq, Eq)]
struct FakeCapnp {
    value: u32,
}

impl CapnpWireMessage for FakeCapnp {
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

#[test]
fn capnp_builder_from_message_encodes_payload() {
    let message = FakeCapnp { value: 42 };
    let builder = CapnpBuilder::<FakeCapnp>::from_message(&message);
    assert_eq!(builder.bytes(), &42u32.to_le_bytes());
}

#[test]
fn capnp_codec_decode_and_verify_valid_payload() {
    let bytes = 7u32.to_le_bytes().to_vec();
    let msg: CapnpMessage<FakeCapnp> = CapnpCodec::decode(IpcBuffer::from_vec(bytes));

    assert!(CapnpCodec::verify(&msg));
    assert_eq!(msg.root().map(|m| m.value), Some(7));
}

#[test]
fn capnp_codec_decode_invalid_payload() {
    let msg: CapnpMessage<FakeCapnp> = CapnpCodec::decode(IpcBuffer::from_slice(&[1, 2, 3]));

    assert!(!CapnpCodec::verify(&msg));
    assert_eq!(msg.root(), None);
}
