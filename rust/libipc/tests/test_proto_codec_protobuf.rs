// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#![cfg(feature = "codec-protobuf")]

use libipc::buffer::IpcBuffer;
use libipc::proto::codec::Codec;
use libipc::proto::codecs::protobuf::{
    ProtobufBuilder, ProtobufCodec, ProtobufMessage, ProtobufWireMessage,
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

#[test]
fn protobuf_builder_from_message_encodes_payload() {
    let message = FakeProto { value: 42 };
    let builder = ProtobufBuilder::<FakeProto>::from_message(&message);
    assert_eq!(builder.bytes(), &42u32.to_le_bytes());
}

#[test]
fn protobuf_codec_decode_and_verify_valid_payload() {
    let bytes = 7u32.to_le_bytes().to_vec();
    let msg: ProtobufMessage<FakeProto> = ProtobufCodec::decode(IpcBuffer::from_vec(bytes));

    assert!(ProtobufCodec::verify(&msg));
    assert_eq!(msg.root().map(|m| m.value), Some(7));
}

#[test]
fn protobuf_codec_decode_invalid_payload() {
    let msg: ProtobufMessage<FakeProto> = ProtobufCodec::decode(IpcBuffer::from_slice(&[1, 2, 3]));

    assert!(!ProtobufCodec::verify(&msg));
    assert_eq!(msg.root(), None);
}
