// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#![cfg(feature = "codec-capnp")]

use std::sync::atomic::{AtomicUsize, Ordering};

use libipc::buffer::IpcBuffer;
use libipc::channel::Mode;
use libipc::proto::codec::Codec;
use libipc::proto::codecs::capnp::{CapnpBuilder, CapnpCodec, CapnpMessage, CapnpWireMessage};
use libipc::proto::{TypedChannelCapnp, TypedRouteCapnp};

#[derive(Debug, Clone, PartialEq, Eq)]
struct FakeCapnp {
    value: u32,
}

static COUNTER: AtomicUsize = AtomicUsize::new(0);

fn unique_name(prefix: &str) -> String {
    let id = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}_{}_{}", std::process::id(), id)
}

type CapnpChannel = TypedChannelCapnp<FakeCapnp>;
type CapnpRoute = TypedRouteCapnp<FakeCapnp>;

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

#[test]
fn capnp_typed_route_round_trip() {
    let name = unique_name("capnp_route");
    CapnpRoute::clear_storage(&name);

    let mut sender = CapnpRoute::connect(&name, Mode::Sender).expect("sender");
    let mut receiver = CapnpRoute::connect(&name, Mode::Receiver).expect("receiver");

    sender
        .raw()
        .wait_for_recv(1, Some(1000))
        .expect("wait_for_recv");

    let builder = CapnpBuilder::from_message(&FakeCapnp { value: 0xA1B2_C3D4 });
    assert!(sender.send_builder(&builder, 1000).expect("send_builder"));

    let msg = receiver.recv(Some(1000)).expect("recv");
    assert!(CapnpCodec::verify(&msg));
    assert_eq!(msg.root().map(|m| m.value), Some(0xA1B2_C3D4));

    drop(sender);
    drop(receiver);
    CapnpRoute::clear_storage(&name);
}

#[test]
fn capnp_typed_channel_round_trip() {
    let name = unique_name("capnp_channel");
    CapnpChannel::clear_storage(&name);

    let mut sender = CapnpChannel::connect(&name, Mode::Sender).expect("sender");
    let mut receiver = CapnpChannel::connect(&name, Mode::Receiver).expect("receiver");

    sender
        .raw()
        .wait_for_recv(1, Some(1000))
        .expect("wait_for_recv");

    let builder = CapnpBuilder::from_message(&FakeCapnp { value: 0x0BAD_F00D });
    assert!(sender.send_builder(&builder, 1000).expect("send_builder"));

    let msg = receiver.recv(Some(1000)).expect("recv");
    assert!(CapnpCodec::verify(&msg));
    assert_eq!(msg.root().map(|m| m.value), Some(0x0BAD_F00D));

    drop(sender);
    drop(receiver);
    CapnpChannel::clear_storage(&name);
}
