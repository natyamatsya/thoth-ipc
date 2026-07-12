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
    if args.len() < 5 {
        eprintln!("write/read need <count> <size>");
        exit(1);
    }
    let count: usize = args[3].parse().unwrap_or(0);
    let size: usize = args[4].parse().unwrap_or(0);
    let code = match verb {
        "write" => do_write(name, count, size),
        "read" => do_read(name, count, size),
        other => { eprintln!("unknown verb '{other}'"); 1 }
    };
    exit(code);
}
