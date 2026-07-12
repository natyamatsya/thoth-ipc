// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Cross-language round-trip harness (Rust endpoint). Shares the CLI contract
// of the C++ (xlang_ipc) and Swift (xlang) harnesses so tools/xlang_matrix.py
// can pair any writer language with any reader language on the ipc::route wire.
//
//   xlang write <name> <count> <size>   send <count> pattern messages
//   xlang read  <name> <count> <size>   recv+verify; exit 0 iff all match
//   xlang clear <name>                  unlink the channel's shm segments
//
// Payload pattern: byte[i] = 'A' + (i % 26).

use std::process::exit;

use libipc::channel::{Mode, Route};

fn pattern(n: usize) -> Vec<u8> {
    (0..n).map(|i| b'A' + (i % 26) as u8).collect()
}

fn do_write(name: &str, count: usize, size: usize) -> i32 {
    let mut w = match Route::connect(name, Mode::Sender) {
        Ok(w) => w,
        Err(e) => { eprintln!("[rust] connect(sender) failed: {e}"); return 3; }
    };
    match w.wait_for_recv(1, Some(5000)) {
        Ok(true) => {}
        _ => { eprintln!("[rust] no receiver within 5s"); return 2; }
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
#[cfg(all(unix, feature = "async-tokio"))]
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
        Route::clear_storage(name);
        exit(0);
    }
    // Report build capabilities so the matrix driver can fail fast (rather than
    // hang) if this harness was built without the notify/async features.
    if verb == "caps" {
        let mut caps: Vec<&str> = Vec::new();
        if cfg!(feature = "notify") { caps.push("notify"); }
        if cfg!(feature = "async-tokio") { caps.push("async"); }
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
    let code = match verb {
        "write" => do_write(name, count, size),
        "read" => do_read(name, count, size),
        #[cfg(all(unix, feature = "notify"))]
        "arecv" => do_arecv(name, count, size),
        // Canonical async receiver = the shipped AsyncRoute::recv().await.
        #[cfg(all(unix, feature = "async-tokio"))]
        "aread" => do_arecv_tokio(name, count, size),
        other => { eprintln!("unknown verb '{other}'"); 1 }
    };
    exit(code);
}
