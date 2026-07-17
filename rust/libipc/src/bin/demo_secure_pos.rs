// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Secure codec demo: a point-of-sale card pipeline.
//
// Domain: PCI-DSS P2PE mandates that cardholder data is encrypted at the
// point of capture and that intermediary software (the merchant's POS app)
// is cryptographically unable to read it — that is what keeps the POS out of
// PCI audit scope. On a BROADCAST route every receiver sees every message,
// so application-layer AEAD is the only way to separate privileges on a
// shared bus: the pinpad seals each card event, the POS app sees only opaque
// envelopes (fail-closed), and only the payment gateway holds the key.
//
// Usage (each role in its own terminal, any language mix — the C++
// counterpart is cpp/libipc/demo/secure_pos):
//   demo_secure_pos gateway [count]    payment gateway: opens sealed events
//   demo_secure_pos pos     [count]    merchant POS: has NO key, must reject
//   demo_secure_pos pinpad  [count]    card reader: seals + broadcasts events
//
// Start the receivers first; the pinpad waits for both. Build with:
//   cargo build --features secure-crypto-openssl,codec-protobuf --bin demo_secure_pos
//
// DEMO KEY ONLY: real deployments provision the key into the pinpad's secure
// element and the gateway's HSM/KMS — it never appears in source.

use std::process::exit;
use std::time::Duration;

use libipc::channel::Mode;
use libipc::proto::{
    OpenSslEvpKeyProvider, ProtobufBuilder, ProtobufWireMessage, SecureBuilder,
    SecureOpenSslEvpBackend, SecureOpenSslEvpCipherAes256Gcm, TypedRouteSecure,
};

const BUS: &str = "pos-bus";

/// Payment-processor key (DEMO ONLY — see header).
struct ProcessorKey;

impl OpenSslEvpKeyProvider for ProcessorKey {
    const KEY_ID: u32 = 0x50_4F_53_01; // "POS",1
    const KEY_BYTES: &'static [u8] = &[
        0x8f, 0x3a, 0x11, 0xc4, 0x5e, 0x92, 0x07, 0x6b, 0xd0, 0x24, 0xa9, 0x71, 0x3c, 0xe8,
        0x55, 0x1f, 0x60, 0xbb, 0x2d, 0x94, 0x48, 0x0e, 0xf3, 0x87, 0x19, 0xc2, 0x6d, 0xaa,
        0x35, 0x7e, 0x01, 0xd8,
    ];
}

/// What the merchant POS app holds: not the processor key. Same key id (it
/// knows WHICH key sealed the event) but no key material — every open must
/// fail closed.
struct MerchantNoKey;

impl OpenSslEvpKeyProvider for MerchantNoKey {
    const KEY_ID: u32 = ProcessorKey::KEY_ID;
    const KEY_BYTES: &'static [u8] = &[0u8; 32];
}

type Sealed<K> = TypedRouteSecure<CardEvent, libipc::proto::ProtobufCodec,
    SecureOpenSslEvpCipherAes256Gcm<K>>;

/// One card capture. Canonical protobuf wire (field 1 bytes pan, field 2
/// varint amount_cents, field 3 varint seq) — byte-identical with the C++
/// counterpart, so roles can be mixed across languages.
struct CardEvent {
    pan: String,
    amount_cents: u64,
    seq: u32,
}

fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v as u8) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

fn get_varint(data: &[u8], pos: &mut usize) -> Option<u64> {
    let (mut v, mut shift) = (0u64, 0);
    while *pos < data.len() {
        let b = data[*pos];
        *pos += 1;
        v |= u64::from(b & 0x7F) << shift;
        if b & 0x80 == 0 {
            return Some(v);
        }
        shift += 7;
        if shift > 63 {
            return None;
        }
    }
    None
}

impl ProtobufWireMessage for CardEvent {
    fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.push(0x0A); // field 1, length-delimited
        put_varint(&mut out, self.pan.len() as u64);
        out.extend_from_slice(self.pan.as_bytes());
        out.push(0x10); // field 2, varint
        put_varint(&mut out, self.amount_cents);
        out.push(0x18); // field 3, varint
        put_varint(&mut out, u64::from(self.seq));
        out
    }

    fn decode(bytes: &[u8]) -> Option<Self> {
        let mut pos = 0;
        if bytes.get(pos) != Some(&0x0A) {
            return None;
        }
        pos += 1;
        let len = get_varint(bytes, &mut pos)? as usize;
        let pan = String::from_utf8(bytes.get(pos..pos + len)?.to_vec()).ok()?;
        pos += len;
        if bytes.get(pos) != Some(&0x10) {
            return None;
        }
        pos += 1;
        let amount_cents = get_varint(bytes, &mut pos)?;
        if bytes.get(pos) != Some(&0x18) {
            return None;
        }
        pos += 1;
        let seq = u32::try_from(get_varint(bytes, &mut pos)?).ok()?;
        Some(CardEvent { pan, amount_cents, seq })
    }
}

fn mask(pan: &str) -> String {
    if pan.len() < 4 {
        return "****".into();
    }
    format!("****-****-****-{}", &pan[pan.len() - 4..])
}

/// Card reader: seals every event at the point of capture, then broadcasts.
fn pinpad(count: u32) -> i32 {
    let mut bus = Sealed::<ProcessorKey>::connect(BUS, Mode::Sender).expect("connect");
    println!("[pinpad] waiting for POS + gateway to subscribe...");
    bus.raw().wait_for_recv(2, Some(30_000)).expect("wait_for_recv");
    for seq in 0..count {
        let event = CardEvent {
            pan: "4111111111111111".into(),
            amount_cents: 1250 + u64::from(seq) * 100,
            seq,
        };
        // Seal per event: fresh nonce, AEAD tag, envelope v1 framing.
        let sealed = SecureBuilder::from_inner(&ProtobufBuilder::from_message(&event));
        assert!(!sealed.is_empty(), "seal failed");
        let wire_len = sealed.bytes().len();
        bus.send_builder(&sealed, 5000).expect("send");
        println!(
            "[pinpad] captured {} for {}c -> sealed event #{seq} ({wire_len}B on the bus)",
            mask(&event.pan),
            event.amount_cents,
        );
        std::thread::sleep(Duration::from_millis(400));
    }
    println!("[pinpad] done.");
    0
}

/// Payment gateway: the only key holder — opens and processes each event.
fn gateway(count: u32) -> i32 {
    let mut bus = Sealed::<ProcessorKey>::connect(BUS, Mode::Receiver).expect("connect");
    println!("[gateway] subscribed (holds the processor key).");
    for _ in 0..count {
        let msg = bus.recv(Some(30_000)).expect("recv");
        match msg.root() {
            Some(ev) => println!(
                "[gateway] authorised {} for {}c (event #{})",
                mask(&ev.pan),
                ev.amount_cents,
                ev.seq
            ),
            None => {
                eprintln!("[gateway] REJECTED an event (bad envelope?)");
                return 1;
            }
        }
    }
    println!("[gateway] done.");
    0
}

/// Merchant POS app: subscribed to the same bus, but with no key material —
/// AEAD must fail closed on every event. It can meter/route the opaque
/// envelopes, which is exactly what keeps it out of PCI scope.
fn pos(count: u32) -> i32 {
    let mut bus = Sealed::<MerchantNoKey>::connect(BUS, Mode::Receiver).expect("connect");
    println!("[pos] subscribed (no processor key).");
    for i in 0..count {
        let msg = bus.recv(Some(30_000)).expect("recv");
        if msg.root().is_some() {
            eprintln!("[pos] SECURITY FAILURE: opened a sealed event without the key!");
            return 1;
        }
        println!("[pos] event #{i}: sealed envelope observed — cannot decrypt (as required)");
    }
    println!("[pos] done.");
    0
}

fn main() {
    if !SecureOpenSslEvpBackend::is_available() {
        eprintln!("crypto backend unavailable — build with --features secure-crypto-openssl");
        exit(2);
    }
    let args: Vec<String> = std::env::args().collect();
    let count: u32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(5);
    let code = match args.get(1).map(String::as_str) {
        Some("pinpad") => pinpad(count),
        Some("gateway") => gateway(count),
        Some("pos") => pos(count),
        _ => {
            eprintln!("usage: demo_secure_pos <pinpad|gateway|pos> [count]");
            2
        }
    };
    exit(code);
}
