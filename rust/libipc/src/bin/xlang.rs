// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Cross-language round-trip harness (Rust endpoint). Shares the CLI contract
// of the C++ (xlang_ipc) and Swift (xlang) harnesses so the matrix driver
// (tools/xlang-runner) can pair any writer language with any reader language
// on the ipc::route wire.
//
// Verbs (see tools/xlang-runner/README.md for the scenario each serves):
//   write/read (route), cwrite/cread (multi-writer channel), aread (async),
//   twrite/tread (typed codec), swrite[-tamper]/sread[-reject|-badkey|-badkeyid]
//   (AEAD envelope), hold/count/probe (reaping), mhold/mtry/mlock + spost/swait
//   + cvwait/cvnotify (sync primitives), caps, clear.
//
// Payload pattern: byte[i] = 'A' + (i % 26).

use std::process::exit;

use libipc::channel::{Channel, Mode, Route};
use libipc::{IpcCondition, IpcMutex, IpcSemaphore};

fn pattern(n: usize) -> Vec<u8> {
    (0..n).map(|i| b'A' + (i % 26) as u8).collect()
}

/// Multi-writer endpoints on ipc::channel (N writers, N readers) — same wire
/// ABI as route, but exercises the multi-producer claim/CAS paths and cc_id
/// self-filtering with concurrent senders of different languages.
fn do_cwrite(name: &str, count: usize, size: usize) -> i32 {
    let mut w = match Channel::connect(name, Mode::Sender) {
        Ok(w) => w,
        Err(e) => { eprintln!("[rust-chan] connect(sender) failed: {e}"); return 3; }
    };
    match w.wait_for_recv(1, Some(5000)) {
        Ok(true) => {}
        _ => { eprintln!("[rust-chan] no receiver within 5s"); return 2; }
    }
    let msg = pattern(size);
    for i in 0..count {
        match w.send(&msg, 8000) {
            Ok(true) => {}
            _ => { eprintln!("[rust-chan] send {i} failed"); return 4; }
        }
    }
    eprintln!("[rust-chan] wrote {count} x {size}B on '{name}'");
    0
}

fn do_cread(name: &str, count: usize, size: usize) -> i32 {
    let mut r = match Channel::connect(name, Mode::Receiver) {
        Ok(r) => r,
        Err(e) => { eprintln!("[rust-chan] connect(receiver) failed: {e}"); return 3; }
    };
    let want = pattern(size);
    for i in 0..count {
        let buf = match r.recv(Some(8000)) {
            Ok(b) => b,
            Err(e) => { eprintln!("[rust-chan] recv {i} error: {e}"); return 5; }
        };
        if buf.is_empty() { eprintln!("[rust-chan] recv {i} timed out"); return 5; }
        if buf.len() != size {
            eprintln!("[rust-chan] recv {i} wrong size: got {} want {size}", buf.len());
            return 6;
        }
        if buf.data() != want.as_slice() {
            eprintln!("[rust-chan] recv {i} payload mismatch");
            return 7;
        }
    }
    eprintln!("[rust-chan] read {count} x {size}B on '{name}' OK");
    0
}

fn do_write(name: &str, count: usize, size: usize, minrecv: usize) -> i32 {
    let mut w = match Route::connect(name, Mode::Sender) {
        Ok(w) => w,
        Err(e) => { eprintln!("[rust] connect(sender) failed: {e}"); return 3; }
    };
    match w.wait_for_recv(minrecv, Some(5000)) {
        Ok(true) => {}
        _ => { eprintln!("[rust] fewer than {minrecv} receivers within 5s"); return 2; }
    }
    let msg = pattern(size);
    for i in 0..count {
        match w.send(&msg, 8000) {
            Ok(true) => {}
            _ => { eprintln!("[rust] send {i} failed"); return 4; }
        }
    }
    eprintln!("[rust] wrote {count} x {size}B on '{name}'");
    0
}

fn do_read(name: &str, count: usize, size: usize) -> i32 {
    let mut r = match Route::connect(name, Mode::Receiver) {
        Ok(r) => r,
        Err(e) => { eprintln!("[rust] connect(receiver) failed: {e}"); return 3; }
    };
    let want = pattern(size);
    for i in 0..count {
        let buf = match r.recv(Some(8000)) {
            Ok(b) => b,
            Err(e) => { eprintln!("[rust] recv {i} error: {e}"); return 5; }
        };
        if buf.is_empty() { eprintln!("[rust] recv {i} timed out"); return 5; }
        if buf.len() != size {
            eprintln!("[rust] recv {i} wrong size: got {} want {size}", buf.len());
            return 6;
        }
        if buf.data() != want.as_slice() {
            eprintln!("[rust] recv {i} payload mismatch");
            return 7;
        }
    }
    eprintln!("[rust] read {count} x {size}B on '{name}' OK");
    0
}

/// Secure (AEAD envelope v1) endpoints. The writer seals each pattern payload
/// with the shared xlang test key and sends the SIPC envelope; the reader
/// parses/opens it and verifies the plaintext. A raw identity inner codec
/// keeps the plaintext byte-exact with the other harnesses, so the pairing
/// proves envelope framing + AEAD interop and nothing else.
#[cfg(feature = "secure-crypto-c")]
mod secure {
    use libipc::buffer::IpcBuffer;
    use libipc::channel::{Mode, Route};
    use libipc::proto::codec::{Codec, CodecId};
    use libipc::proto::{
        OpenSslEvpKeyProvider, SecureBuilder, SecureCodec, SecureOpenSslEvpBackend,
        SecureOpenSslEvpCipherAes256Gcm, SecureOpenSslEvpCipherChacha20Poly1305,
    };

    use super::pattern;

    pub struct RawBuilder(pub Vec<u8>);
    pub struct RawMessage(pub Vec<u8>);
    pub struct RawCodec;

    impl Codec<Vec<u8>> for RawCodec {
        type Message = RawMessage;
        type Builder = RawBuilder;

        // Metadata only: these bytes never travel through the typed layer.
        const CODEC_ID: CodecId = CodecId::Protobuf;

        fn encode(builder: &RawBuilder) -> &[u8] {
            &builder.0
        }

        fn decode(buf: IpcBuffer) -> RawMessage {
            RawMessage(buf.data().to_vec())
        }

        fn verify(message: &RawMessage) -> bool {
            !message.0.is_empty()
        }
    }

    /// Shared xlang test key — must stay byte-identical across the C++, Rust
    /// and Swift harnesses (same values as the per-language secure codec tests).
    pub struct XlangTestKey;

    impl OpenSslEvpKeyProvider for XlangTestKey {
        const KEY_ID: u32 = 0x0A0B_0C0D;
        const KEY_BYTES: &'static [u8] = &[
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
            0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B,
            0x1C, 0x1D, 0x1E, 0x1F,
        ];
    }

    /// Same key id, different key material: the envelope's key_id check passes
    /// and the AEAD open itself must fail (fail-closed path).
    pub struct XlangWrongKey;

    impl OpenSslEvpKeyProvider for XlangWrongKey {
        const KEY_ID: u32 = XlangTestKey::KEY_ID;
        const KEY_BYTES: &'static [u8] = &[
            0xF0, 0xE1, 0xD2, 0xC3, 0xB4, 0xA5, 0x96, 0x87, 0x78, 0x69, 0x5A, 0x4B, 0x3C, 0x2D,
            0x1E, 0x0F, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB,
            0xCC, 0xDD, 0xEE, 0xFF,
        ];
    }

    /// Same key material, different key id: the envelope's key_id check itself
    /// must reject the message before any AEAD work.
    pub struct XlangWrongIdKey;

    impl OpenSslEvpKeyProvider for XlangWrongIdKey {
        const KEY_ID: u32 = XlangTestKey::KEY_ID + 1;
        const KEY_BYTES: &'static [u8] = XlangTestKey::KEY_BYTES;
    }

    fn do_swrite<Cipher: libipc::proto::SecureCipher>(
        name: &str,
        count: usize,
        size: usize,
        tamper: bool,
    ) -> i32 {
        let mut w = match Route::connect(name, Mode::Sender) {
            Ok(w) => w,
            Err(e) => { eprintln!("[rust-secure] connect(sender) failed: {e}"); return 3; }
        };
        match w.wait_for_recv(1, Some(5000)) {
            Ok(true) => {}
            _ => { eprintln!("[rust-secure] no receiver within 5s"); return 2; }
        }
        let plain = pattern(size);
        for i in 0..count {
            // Seal per message so every envelope carries a fresh nonce.
            let sealed =
                SecureBuilder::<RawCodec, Cipher, Vec<u8>>::from_inner(&RawBuilder(plain.clone()));
            if sealed.is_empty() {
                eprintln!("[rust-secure] seal {i} failed");
                return 9;
            }
            let mut bytes = sealed.bytes().to_vec();
            if tamper {
                // Flip a bit in the trailing AEAD tag: a correctly keyed reader
                // must still reject every message.
                let last = bytes.len() - 1;
                bytes[last] ^= 0x7F;
            }
            match w.send(&bytes, 8000) {
                Ok(true) => {}
                _ => { eprintln!("[rust-secure] send {i} failed"); return 4; }
            }
        }
        let how = if tamper { "tamper-sealed" } else { "sealed" };
        eprintln!("[rust-secure] wrote {count} x {size}B {how} on '{name}'");
        0
    }

    fn do_sread<Cipher: libipc::proto::SecureCipher>(
        name: &str,
        count: usize,
        size: usize,
        expect_open: bool,
    ) -> i32 {
        let mut r = match Route::connect(name, Mode::Receiver) {
            Ok(r) => r,
            Err(e) => { eprintln!("[rust-secure] connect(receiver) failed: {e}"); return 3; }
        };
        let want = pattern(size);
        for i in 0..count {
            let buf = match r.recv(Some(8000)) {
                Ok(b) => b,
                Err(e) => { eprintln!("[rust-secure] recv {i} error: {e}"); return 5; }
            };
            if buf.is_empty() { eprintln!("[rust-secure] recv {i} timed out"); return 5; }
            if buf.data() == want.as_slice() {
                eprintln!("[rust-secure] recv {i} arrived as plaintext");
                return 10;
            }
            let msg = SecureCodec::<RawCodec, Cipher>::decode(buf);
            if !expect_open {
                if !msg.0.is_empty() {
                    eprintln!("[rust-secure] recv {i} opened under the WRONG key");
                    return 11;
                }
                continue;
            }
            if msg.0.is_empty() { eprintln!("[rust-secure] recv {i} open failed"); return 8; }
            if msg.0.len() != size {
                eprintln!("[rust-secure] recv {i} wrong size: got {} want {size}", msg.0.len());
                return 6;
            }
            if msg.0 != want {
                eprintln!("[rust-secure] recv {i} plaintext mismatch");
                return 7;
            }
        }
        let what = if expect_open { "opened+verified" } else { "rejected (wrong key)" };
        eprintln!("[rust-secure] {what} {count} x {size}B on '{name}' OK");
        0
    }

    fn backend_ready() -> bool {
        if SecureOpenSslEvpBackend::is_available() {
            return true;
        }
        eprintln!("[rust-secure] crypto backend unavailable (built without secure-crypto-openssl?)");
        false
    }

    pub fn swrite(name: &str, count: usize, size: usize, alg: &str, tamper: bool) -> i32 {
        if !backend_ready() { return 12; }
        match alg {
            "aes256gcm" => do_swrite::<SecureOpenSslEvpCipherAes256Gcm<XlangTestKey>>(
                name, count, size, tamper,
            ),
            "chacha20poly1305" => do_swrite::<SecureOpenSslEvpCipherChacha20Poly1305<XlangTestKey>>(
                name, count, size, tamper,
            ),
            other => { eprintln!("[rust-secure] unknown algorithm '{other}'"); 1 }
        }
    }

    /// Reader dispatch over key provider x expectation:
    ///   sread          — correct key, every open must succeed
    ///   sread-reject   — correct key, every open must FAIL (tampered or
    ///                    algorithm-mismatched envelopes)
    ///   sread-badkey   — wrong key material (same id), must fail in AEAD open
    ///   sread-badkeyid — wrong key id, must fail the envelope key_id check
    pub fn sread(name: &str, count: usize, size: usize, alg: &str, verb: &str) -> i32 {
        if !backend_ready() { return 12; }
        let expect_open = verb == "sread";
        match (alg, verb) {
            ("aes256gcm", "sread" | "sread-reject") => {
                do_sread::<SecureOpenSslEvpCipherAes256Gcm<XlangTestKey>>(
                    name, count, size, expect_open,
                )
            }
            ("aes256gcm", "sread-badkey") => {
                do_sread::<SecureOpenSslEvpCipherAes256Gcm<XlangWrongKey>>(
                    name, count, size, false,
                )
            }
            ("aes256gcm", "sread-badkeyid") => {
                do_sread::<SecureOpenSslEvpCipherAes256Gcm<XlangWrongIdKey>>(
                    name, count, size, false,
                )
            }
            ("chacha20poly1305", "sread" | "sread-reject") => {
                do_sread::<SecureOpenSslEvpCipherChacha20Poly1305<XlangTestKey>>(
                    name, count, size, expect_open,
                )
            }
            ("chacha20poly1305", "sread-badkey") => {
                do_sread::<SecureOpenSslEvpCipherChacha20Poly1305<XlangWrongKey>>(
                    name, count, size, false,
                )
            }
            ("chacha20poly1305", "sread-badkeyid") => {
                do_sread::<SecureOpenSslEvpCipherChacha20Poly1305<XlangWrongIdKey>>(
                    name, count, size, false,
                )
            }
            (other, _) => { eprintln!("[rust-secure] unknown algorithm '{other}'"); 1 }
        }
    }

    pub fn caps() -> Vec<&'static str> {
        if SecureOpenSslEvpBackend::is_available() {
            vec!["secure", "secure:aes256gcm", "secure:chacha20poly1305"]
        } else {
            Vec::new()
        }
    }
}

/// Typed protocol endpoints (scenario: typed): the real TypedRouteCodec +
/// ProtobufCodec path with a hand-rolled canonical wire message
/// (field 1 varint seq, field 2 bytes payload — no protobuf library needed),
/// verified field-by-field on the reader.
#[cfg(feature = "codec-protobuf")]
mod typed {
    use libipc::channel::Mode;
    use libipc::proto::{ProtobufBuilder, ProtobufCodec, ProtobufWireMessage, TypedRouteCodec};

    use super::pattern;

    #[derive(Debug, PartialEq, Eq)]
    pub struct XlangMsg {
        pub seq: u32,
        pub payload: Vec<u8>,
    }

    fn put_varint(out: &mut Vec<u8>, mut v: u64) {
        while v >= 0x80 {
            out.push((v as u8) | 0x80);
            v >>= 7;
        }
        out.push(v as u8);
    }

    fn get_varint(data: &[u8], pos: &mut usize) -> Option<u64> {
        let mut v = 0u64;
        let mut shift = 0;
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

    impl ProtobufWireMessage for XlangMsg {
        fn encode(&self) -> Vec<u8> {
            let mut out = Vec::with_capacity(self.payload.len() + 12);
            out.push(0x08); // field 1, varint
            put_varint(&mut out, u64::from(self.seq));
            out.push(0x12); // field 2, length-delimited
            put_varint(&mut out, self.payload.len() as u64);
            out.extend_from_slice(&self.payload);
            out
        }

        fn decode(bytes: &[u8]) -> Option<Self> {
            let mut pos = 0;
            if bytes.get(pos) != Some(&0x08) {
                return None;
            }
            pos += 1;
            let seq = u32::try_from(get_varint(bytes, &mut pos)?).ok()?;
            if bytes.get(pos) != Some(&0x12) {
                return None;
            }
            pos += 1;
            let len = get_varint(bytes, &mut pos)? as usize;
            if bytes.len() - pos != len {
                return None;
            }
            Some(XlangMsg {
                seq,
                payload: bytes[pos..].to_vec(),
            })
        }
    }

    pub fn twrite(name: &str, count: usize, size: usize) -> i32 {
        let mut w = match TypedRouteCodec::<XlangMsg, ProtobufCodec>::connect(name, Mode::Sender) {
            Ok(w) => w,
            Err(e) => { eprintln!("[rust-typed] connect(sender) failed: {e}"); return 3; }
        };
        match w.raw().wait_for_recv(1, Some(5000)) {
            Ok(true) => {}
            _ => { eprintln!("[rust-typed] no receiver within 5s"); return 2; }
        }
        for i in 0..count {
            let msg = XlangMsg { seq: i as u32, payload: pattern(size) };
            let b = ProtobufBuilder::from_message(&msg);
            match w.send_builder(&b, 8000) {
                Ok(true) => {}
                _ => { eprintln!("[rust-typed] send {i} failed"); return 4; }
            }
        }
        eprintln!("[rust-typed] wrote {count} x {size}B typed on '{name}'");
        0
    }

    pub fn tread(name: &str, count: usize, size: usize) -> i32 {
        let mut r = match TypedRouteCodec::<XlangMsg, ProtobufCodec>::connect(name, Mode::Receiver) {
            Ok(r) => r,
            Err(e) => { eprintln!("[rust-typed] connect(receiver) failed: {e}"); return 3; }
        };
        let want = pattern(size);
        for i in 0..count {
            let msg = match r.recv(Some(8000)) {
                Ok(m) => m,
                Err(e) => { eprintln!("[rust-typed] recv {i} error: {e}"); return 5; }
            };
            let Some(root) = msg.root() else {
                eprintln!("[rust-typed] recv {i} empty/undecodable");
                return 8;
            };
            if root.seq != i as u32 {
                eprintln!("[rust-typed] recv {i} wrong seq {}", root.seq);
                return 6;
            }
            if root.payload != want {
                eprintln!("[rust-typed] recv {i} payload mismatch");
                return 7;
            }
        }
        eprintln!("[rust-typed] read {count} x {size}B typed on '{name}' OK");
        0
    }
}

/// Async-style receive driven purely by the Layer-1 readiness fd
/// (native_wait_handle), with no blocking recv — a manual reactor loop that
/// validates the notify sink wakes cross-process. Requires the `notify` feature.
#[cfg(all(unix, feature = "notify"))]
fn do_arecv(name: &str, count: usize, size: usize) -> i32 {
    let mut r = match Route::connect(name, Mode::Receiver) {
        Ok(r) => r,
        Err(e) => { eprintln!("[rust-async] connect(receiver) failed: {e}"); return 3; }
    };
    let fd = r.native_wait_handle();
    if fd < 0 { eprintln!("[rust-async] no readiness handle (build without notify?)"); return 8; }
    let want = pattern(size);
    let mut got = 0usize;
    while got < count {
        // Drain everything currently queued (fast path).
        loop {
            match r.try_recv() {
                Ok(b) if !b.is_empty() => {
                    if b.len() != size { eprintln!("[rust-async] wrong size {}", b.len()); return 6; }
                    if b.data() != want.as_slice() { eprintln!("[rust-async] mismatch"); return 7; }
                    got += 1;
                    if got == count { break; }
                }
                Ok(_) => break,
                Err(e) => { eprintln!("[rust-async] try_recv error: {e}"); return 5; }
            }
        }
        if got == count { break; }
        // Park on the readiness fd until a sender's notify wakes it.
        let mut pfd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        let n = unsafe { libc::poll(&mut pfd, 1, 8000) };
        if n <= 0 { eprintln!("[rust-async] readiness fd timed out ({got}/{count})"); return 5; }
        r.drain_wait_handle();
    }
    eprintln!("[rust-async] async-read {count} x {size}B on '{name}' OK");
    0
}

/// Async receive via the shipped `AsyncRoute::recv().await` on a tokio runtime.
/// Validates the Layer-2 ergonomic API end-to-end. Requires `async-tokio`.
#[cfg(feature = "async-tokio")]
fn do_arecv_tokio(name: &str, count: usize, size: usize) -> i32 {
    use libipc::async_recv::AsyncRoute;
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_io()
        .build()
        .expect("tokio runtime");
    rt.block_on(async move {
        let mut r = match AsyncRoute::connect(name) {
            Ok(r) => r,
            Err(e) => { eprintln!("[rust-tokio] connect failed: {e}"); return 3; }
        };
        let want = pattern(size);
        for i in 0..count {
            let b = match r.recv().await {
                Ok(b) => b,
                Err(e) => { eprintln!("[rust-tokio] recv {i} error: {e}"); return 5; }
            };
            if b.len() != size { eprintln!("[rust-tokio] wrong size {}", b.len()); return 6; }
            if b.data() != want.as_slice() { eprintln!("[rust-tokio] mismatch"); return 7; }
        }
        eprintln!("[rust-tokio] async-read {count} x {size}B on '{name}' OK");
        0
    })
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: {} <write|read|clear> <name> [count] [size]", args[0]);
        exit(1);
    }
    let (verb, name) = (args[1].as_str(), args[2].as_str());
    if verb == "clear" {
        // One clearer for everything a case may have created under <name>:
        // the ring (route and channel share storage) plus the primitives'
        // derived objects (mutex <name>_m, semaphore <name>_s, cond <name>_c).
        Route::clear_storage(name);
        IpcMutex::clear_storage(&format!("{name}_m"));
        IpcSemaphore::clear_storage(&format!("{name}_s"));
        IpcCondition::clear_storage(&format!("{name}_c"));
        exit(0);
    }
    // --- Cross-language sync primitive endpoints (scenario: primitives) ----
    // Lock the mutex and hold it (READY once held), so a peer can probe
    // contention (mtry) or, after SIGKILL, robust dead-holder recovery (mlock).
    if verb == "mhold" {
        let secs: u64 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(20);
        let m = IpcMutex::open(&format!("{name}_m")).expect("open mutex");
        m.lock().expect("lock");
        println!("READY");
        use std::io::Write;
        let _ = std::io::stdout().flush();
        std::thread::sleep(std::time::Duration::from_secs(secs));
        let _ = m.unlock();
        exit(0);
    }
    if verb == "mtry" {
        let m = IpcMutex::open(&format!("{name}_m")).expect("open mutex");
        match m.try_lock() {
            Ok(true) => {
                let _ = m.unlock();
                println!("acquired");
            }
            Ok(false) => println!("busy"),
            Err(e) => {
                eprintln!("[rust-prim] try_lock error: {e}");
                println!("error");
            }
        }
        exit(0);
    }
    if verb == "mlock" {
        let ms: u64 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(5000);
        let m = IpcMutex::open(&format!("{name}_m")).expect("open mutex");
        match m.lock_timeout(ms) {
            Ok(true) => {
                let _ = m.unlock();
                println!("acquired");
            }
            Ok(false) => println!("timeout"),
            Err(e) => {
                eprintln!("[rust-prim] lock error: {e}");
                println!("error");
            }
        }
        exit(0);
    }
    if verb == "spost" {
        let n: u32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(1);
        let s = IpcSemaphore::open(&format!("{name}_s"), 0).expect("open semaphore");
        s.post(n).expect("post");
        eprintln!("[rust-prim] posted {n} on '{name}_s'");
        exit(0);
    }
    // Wait for exactly <n> posts: all must arrive within the timeout, and no
    // surplus token may remain afterwards (count exactness cross-language).
    if verb == "swait" {
        let n: u32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(1);
        let ms: u64 = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(8000);
        let s = IpcSemaphore::open(&format!("{name}_s"), 0).expect("open semaphore");
        for i in 0..n {
            match s.wait(Some(ms)) {
                Ok(true) => {}
                _ => {
                    eprintln!("[rust-prim] sem wait {i} timed out");
                    exit(5);
                }
            }
        }
        if let Ok(true) = s.wait(Some(500)) {
            eprintln!("[rust-prim] sem had a surplus token after {n} waits");
            exit(6);
        }
        eprintln!("[rust-prim] waited {n} posts on '{name}_s' OK");
        exit(0);
    }
    if verb == "cvwait" {
        let ms: u64 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(8000);
        let m = IpcMutex::open(&format!("{name}_m")).expect("open mutex");
        let c = IpcCondition::open(&format!("{name}_c")).expect("open condition");
        m.lock().expect("lock");
        let woke = c.wait(&m, Some(ms));
        let _ = m.unlock();
        match woke {
            Ok(true) => {
                eprintln!("[rust-prim] condition woke on '{name}_c'");
                exit(0);
            }
            _ => {
                eprintln!("[rust-prim] condition wait timed out");
                exit(5);
            }
        }
    }
    // Broadcast repeatedly (the waiter needs only one wake; looping avoids a
    // notify-before-wait race without a side channel).
    if verb == "cvnotify" {
        let m = IpcMutex::open(&format!("{name}_m")).expect("open mutex");
        let c = IpcCondition::open(&format!("{name}_c")).expect("open condition");
        for _ in 0..30 {
            m.lock().expect("lock");
            let _ = c.broadcast();
            let _ = m.unlock();
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        exit(0);
    }
    // Report build capabilities so the matrix driver can fail fast (rather than
    // hang) if this harness was built without the notify/async features.
    if verb == "caps" {
        // "prim" = the sync-primitive verbs (mhold/mtry/mlock/spost/swait/
        // cvwait/cvnotify) are available.
        let mut caps: Vec<&str> = vec!["prim"];
        if cfg!(feature = "codec-protobuf") { caps.push("typed:protobuf"); }
        if cfg!(feature = "notify") { caps.push("notify"); }
        if cfg!(feature = "async-tokio") { caps.push("async"); }
        #[cfg(feature = "secure-crypto-c")]
        caps.extend(secure::caps());
        println!("{}", caps.join(" "));
        exit(0);
    }
    // Connect a receiver and hold it (populating the LV_CONN__ owner table), so a
    // test can SIGKILL this process and check a reaper reclaims the slot. Prints
    // READY once connected. Optional arg: hold seconds (default 30).
    if verb == "hold" {
        let secs: u64 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(30);
        let _r = Route::connect(name, Mode::Receiver).expect("connect receiver");
        println!("READY");
        use std::io::Write;
        let _ = std::io::stdout().flush();
        std::thread::sleep(std::time::Duration::from_secs(secs));
        exit(0);
    }
    // Observe the receiver count without side effects (a sender neither claims a
    // slot nor reaps).
    if verb == "probe" {
        let r = Route::connect(name, Mode::Sender).expect("connect sender");
        println!("{}", r.recv_count());
        exit(0);
    }
    // Connect a RECEIVER (reap-on-connect runs), then report the count.
    if verb == "count" {
        let r = Route::connect(name, Mode::Receiver).expect("connect receiver");
        println!("{}", r.recv_count());
        exit(0);
    }
    if args.len() < 5 {
        eprintln!("write/read need <count> <size>");
        exit(1);
    }
    let count: usize = args[3].parse().unwrap_or(0);
    let size: usize = args[4].parse().unwrap_or(0);
    #[cfg(feature = "secure-crypto-c")]
    let alg = args.get(5).map(String::as_str).unwrap_or("aes256gcm");
    let code = match verb {
        // Optional 6th arg: wait for that many receivers before sending
        // (fanout cases start N readers of mixed languages).
        "write" => {
            let minrecv = args.get(5).and_then(|s| s.parse().ok()).unwrap_or(1);
            do_write(name, count, size, minrecv)
        }
        "read" => do_read(name, count, size),
        "cwrite" => do_cwrite(name, count, size),
        "cread" => do_cread(name, count, size),
        #[cfg(feature = "codec-protobuf")]
        "twrite" => typed::twrite(name, count, size),
        #[cfg(feature = "codec-protobuf")]
        "tread" => typed::tread(name, count, size),
        #[cfg(feature = "secure-crypto-c")]
        "swrite" => secure::swrite(name, count, size, alg, false),
        #[cfg(feature = "secure-crypto-c")]
        "swrite-tamper" => secure::swrite(name, count, size, alg, true),
        #[cfg(feature = "secure-crypto-c")]
        v @ ("sread" | "sread-reject" | "sread-badkey" | "sread-badkeyid") => {
            secure::sread(name, count, size, alg, v)
        }
        #[cfg(all(unix, feature = "notify"))]
        "arecv" => do_arecv(name, count, size),
        // Canonical async receiver = the shipped AsyncRoute::recv().await.
        #[cfg(feature = "async-tokio")]
        "aread" => do_arecv_tokio(name, count, size),
        other => { eprintln!("unknown verb '{other}'"); 1 }
    };
    exit(code);
}
