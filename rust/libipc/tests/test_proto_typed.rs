// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Tests for proto::message, proto::typed_channel, proto::typed_route.
//
// We use raw bytes for send/recv (the typed layer is a thin wrapper) and test
// Message/Builder with the raw flatbuffers API — no flatc required.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;
use std::time::Duration;

use libipc::buffer::IpcBuffer;
use libipc::channel::Mode;
use libipc::proto::{Builder, Message, TypedChannel, TypedRoute};

// ---------------------------------------------------------------------------
// Opaque marker type — used as the T parameter when we only care about the
// raw bytes, not typed access.
// ---------------------------------------------------------------------------
struct RawMsg;

// ---------------------------------------------------------------------------
// Unique name helper
// ---------------------------------------------------------------------------

static COUNTER: AtomicUsize = AtomicUsize::new(0);

fn unique_name(prefix: &str) -> String {
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}_typed_{n}_{}", std::process::id())
}

// ---------------------------------------------------------------------------
// A minimal valid FlatBuffer: just a root u32 scalar (simplest possible).
// Layout: [4-byte little-endian offset=4][4-byte little-endian value]
// This is NOT a table — just a raw scalar root, which is valid FlatBuffers.
// We use it only to test that bytes flow through correctly.
// ---------------------------------------------------------------------------
fn make_raw_payload(tag: u32) -> Vec<u8> {
    // Encode tag as 4 LE bytes prefixed by a 4-byte root offset pointing to itself.
    let mut v = Vec::with_capacity(8);
    // root offset = 4 (points 4 bytes forward from start of offset field)
    v.extend_from_slice(&4u32.to_le_bytes());
    v.extend_from_slice(&tag.to_le_bytes());
    v
}

fn read_raw_payload(data: &[u8]) -> u32 {
    assert!(data.len() >= 8);
    u32::from_le_bytes(data[4..8].try_into().unwrap())
}

// ===========================================================================
// Message<RawMsg> — basic wrapper tests (no typed access needed)
// ===========================================================================

#[test]
fn message_empty() {
    let msg: Message<RawMsg> = Message::empty();
    assert!(msg.is_empty());
    assert_eq!(msg.size(), 0);
    assert_eq!(msg.data(), &[] as &[u8]);
}

#[test]
fn message_from_buffer() {
    let payload = make_raw_payload(42);
    let buf = IpcBuffer::from_slice(&payload);
    let msg: Message<RawMsg> = Message::new(buf);
    assert!(!msg.is_empty());
    assert_eq!(msg.size(), 8);
    assert_eq!(read_raw_payload(msg.data()), 42);
}

#[test]
fn message_data_roundtrip() {
    let payload = b"hello flatbuffers".to_vec();
    let buf = IpcBuffer::from_slice(&payload);
    let msg: Message<RawMsg> = Message::new(buf);
    assert_eq!(msg.data(), payload.as_slice());
}

// ===========================================================================
// Builder — tests that don't require a typed table
// ===========================================================================

#[test]
fn builder_default_empty() {
    // Just verify construction doesn't panic.
    let _b = Builder::default();
}

#[test]
fn builder_new_empty() {
    // Just verify construction doesn't panic.
    let _b = Builder::new(256);
}

#[test]
fn builder_clear_resets() {
    let mut b = Builder::new(64);
    let off = b.fbb().push(99u32);
    b.finish(off);
    assert!(b.size() > 0);
    b.clear();
    assert_eq!(b.size(), 0);
}

#[test]
fn builder_finish_with_id() {
    let mut b = Builder::new(64);
    let off = b.fbb().push(7u32);
    b.finish_with_id(off, "TEST");
    assert!(b.size() > 0);
}

// ===========================================================================
// TypedRoute — send/recv raw bytes through the typed wrapper
// ===========================================================================

#[test]
fn typed_route_connect_sender() {
    let name = unique_name("tr_conn");
    TypedRoute::<RawMsg>::clear_storage(&name);
    let _rt = TypedRoute::<RawMsg>::connect(&name, Mode::Sender).expect("sender");
    TypedRoute::<RawMsg>::clear_storage(&name);
}

#[test]
fn typed_route_connect_receiver() {
    let name = unique_name("tr_conn_r");
    TypedRoute::<RawMsg>::clear_storage(&name);
    let _rt = TypedRoute::<RawMsg>::connect(&name, Mode::Receiver).expect("receiver");
    TypedRoute::<RawMsg>::clear_storage(&name);
}

#[test]
fn typed_route_send_raw_bytes() {
    let name = unique_name("tr_send");
    TypedRoute::<RawMsg>::clear_storage(&name);

    let name2 = name.clone();
    let sender = thread::spawn(move || {
        let mut rt = TypedRoute::<RawMsg>::connect(&name2, Mode::Sender).expect("sender");
        rt.raw().wait_for_recv(1, Some(1000)).expect("wait");
        let payload = make_raw_payload(77);
        rt.send(&payload, 2000).expect("send")
    });

    // Receive via the raw channel to avoid needing Follow+Verifiable on RawMsg.
    let mut rt = TypedRoute::<RawMsg>::connect(&name, Mode::Receiver).expect("receiver");
    let buf = rt.raw().recv(Some(3000)).expect("recv");

    let sent = sender.join().unwrap();
    assert!(sent);
    assert!(!buf.is_empty());
    assert_eq!(read_raw_payload(buf.data()), 77);

    TypedRoute::<RawMsg>::clear_storage(&name);
}

#[test]
fn typed_route_send_builder_bytes() {
    let name = unique_name("tr_builder");
    TypedRoute::<RawMsg>::clear_storage(&name);

    let name2 = name.clone();
    let sender = thread::spawn(move || {
        let mut rt = TypedRoute::<RawMsg>::connect(&name2, Mode::Sender).expect("sender");
        rt.raw().wait_for_recv(1, Some(1000)).expect("wait");
        let mut b = Builder::new(64);
        let off = b.fbb().push(55u32);
        b.finish(off);
        rt.send_builder(&b, 2000).expect("send")
    });

    let mut rt = TypedRoute::<RawMsg>::connect(&name, Mode::Receiver).expect("receiver");
    let buf = rt.raw().recv(Some(3000)).expect("recv");

    sender.join().unwrap();
    assert!(!buf.is_empty());

    TypedRoute::<RawMsg>::clear_storage(&name);
}

#[test]
fn typed_route_clear_storage() {
    let name = unique_name("tr_clear");
    TypedRoute::<RawMsg>::clear_storage(&name);
    // Just verify it doesn't panic.
}

// ===========================================================================
// TypedChannel — send/recv raw bytes through the typed wrapper
// ===========================================================================

#[test]
fn typed_channel_connect_sender() {
    let name = unique_name("tc_conn");
    TypedChannel::<RawMsg>::clear_storage(&name);
    let _ch = TypedChannel::<RawMsg>::connect(&name, Mode::Sender).expect("sender");
    TypedChannel::<RawMsg>::clear_storage(&name);
}

#[test]
fn typed_channel_connect_receiver() {
    let name = unique_name("tc_conn_r");
    TypedChannel::<RawMsg>::clear_storage(&name);
    let _ch = TypedChannel::<RawMsg>::connect(&name, Mode::Receiver).expect("receiver");
    TypedChannel::<RawMsg>::clear_storage(&name);
}

#[test]
fn typed_channel_send_raw_bytes() {
    let name = unique_name("tc_send");
    TypedChannel::<RawMsg>::clear_storage(&name);

    let name2 = name.clone();
    let sender = thread::spawn(move || {
        let mut ch = TypedChannel::<RawMsg>::connect(&name2, Mode::Sender).expect("sender");
        ch.raw().wait_for_recv(1, Some(1000)).expect("wait");
        let payload = make_raw_payload(99);
        ch.send(&payload, 2000).expect("send")
    });

    let mut ch = TypedChannel::<RawMsg>::connect(&name, Mode::Receiver).expect("receiver");
    let buf = ch.raw().recv(Some(3000)).expect("recv");

    let sent = sender.join().unwrap();
    assert!(sent);
    assert_eq!(read_raw_payload(buf.data()), 99);

    TypedChannel::<RawMsg>::clear_storage(&name);
}

#[test]
fn typed_channel_multiple_receivers() {
    let name = unique_name("tc_multi");
    TypedChannel::<RawMsg>::clear_storage(&name);

    let n_receivers = 3usize;
    let mut receivers = Vec::new();
    for _ in 0..n_receivers {
        let nm = name.clone();
        receivers.push(thread::spawn(move || {
            let mut ch = TypedChannel::<RawMsg>::connect(&nm, Mode::Receiver).expect("recv");
            ch.raw().recv(Some(3000)).expect("recv msg")
        }));
    }

    thread::sleep(Duration::from_millis(50));

    let mut ch = TypedChannel::<RawMsg>::connect(&name, Mode::Sender).expect("sender");
    ch.raw()
        .wait_for_recv(n_receivers, Some(1000))
        .expect("wait");
    let payload = make_raw_payload(33);
    ch.send(&payload, 2000).expect("send");

    for r in receivers {
        let buf = r.join().unwrap();
        assert_eq!(read_raw_payload(buf.data()), 33);
    }

    TypedChannel::<RawMsg>::clear_storage(&name);
}

#[test]
fn typed_channel_clear_storage() {
    let name = unique_name("tc_clear");
    TypedChannel::<RawMsg>::clear_storage(&name);
    // Just verify it doesn't panic.
}
