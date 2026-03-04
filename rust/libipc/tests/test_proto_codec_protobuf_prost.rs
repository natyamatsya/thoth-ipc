// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#![cfg(feature = "codec-protobuf-prost")]

use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;

use libipc::buffer::IpcBuffer;
use libipc::channel::Mode;
use libipc::proto::codec::Codec;
use libipc::proto::{ProtobufBuilder, ProtobufCodec, ProtobufMessage, ProtobufWireMessage, TypedRouteCodec};
use prost::Message as ProstMessage;

#[derive(Clone, PartialEq, prost::Message)]
struct ProstFake {
    #[prost(uint32, tag = "1")]
    value: u32,
}

static COUNTER: AtomicUsize = AtomicUsize::new(0);

fn unique_name(prefix: &str) -> String {
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}_prost_{}_{}", std::process::id(), n)
}

#[test]
fn prost_type_satisfies_protobuf_wire_trait() {
    fn assert_wire<T: ProtobufWireMessage>() {}
    assert_wire::<ProstFake>();
}

#[test]
fn protobuf_codec_decodes_prost_payload() {
    let payload = ProstFake { value: 123 }.encode_to_vec();
    let msg: ProtobufMessage<ProstFake> = ProtobufCodec::decode(IpcBuffer::from_vec(payload));

    assert!(ProtobufCodec::verify(&msg));
    assert_eq!(msg.root().map(|m| m.value), Some(123));
}

#[test]
fn typed_route_round_trip_with_prost_codec() {
    type ProstRoute = TypedRouteCodec<ProstFake, ProtobufCodec>;

    let name = unique_name("tr");
    ProstRoute::clear_storage(&name);

    let sender_name = name.clone();
    let sender = thread::spawn(move || {
        let mut tx = ProstRoute::connect(&sender_name, Mode::Sender).expect("sender connect");
        tx.raw().wait_for_recv(1, Some(1000)).expect("wait receiver");

        let builder = ProtobufBuilder::<ProstFake>::from_message(&ProstFake { value: 77 });
        tx.send_builder(&builder, 2000).expect("send");
    });

    let mut rx = ProstRoute::connect(&name, Mode::Receiver).expect("receiver connect");
    let message = rx.recv(Some(3000)).expect("recv");

    sender.join().expect("sender join");
    assert_eq!(message.root().map(|m| m.value), Some(77));

    ProstRoute::clear_storage(&name);
}
