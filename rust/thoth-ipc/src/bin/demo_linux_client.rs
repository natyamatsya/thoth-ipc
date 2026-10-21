// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Rust port of demo/linux_service/client/main.cpp
//
// Usage (start the client first, then the service):
//   demo_linux_client            answer every "Hello, World!" with "Copy.", forever
//   demo_linux_client <count>    answer <count> messages, then exit
//
// The client receives on "service ipc r" and replies on "service ipc w" (both
// multi-writer `thoth::channel`). Strings go on the wire with their trailing
// NUL (`send_str`), byte-exact with the C++ and Zig ports, so the client and
// the service can be any mix of languages. `demo_linux_service clear` removes
// both channels.

use std::process::exit;
use std::thread;
use std::time::Duration;

use thoth_ipc::buffer::IpcBuffer;
use thoth_ipc::channel::{Channel, Mode};

/// The payload without the trailing NUL the senders append.
fn text(buf: &IpcBuffer) -> String {
    let d = buf.data();
    let d = d.strip_suffix(&[0]).unwrap_or(d);
    String::from_utf8_lossy(d).into_owned()
}

fn run_forever(ipc_r: &mut Channel, ipc_w: &mut Channel) {
    loop {
        let msg = ipc_r.recv(None).unwrap_or_default();
        if msg.is_empty() {
            println!("My Sample Client: message recv error");
            exit(-1);
        }
        println!("My Sample Client: message recv: [{}]", text(&msg));
        while !ipc_w.send_str("Copy.", 100).unwrap_or(false) {
            println!("My Sample Client: message send error");
            thread::sleep(Duration::from_secs(1));
        }
        println!("My Sample Client: message send [Copy]");
    }
}

fn run_count(ipc_r: &mut Channel, ipc_w: &mut Channel, count: u64) {
    for k in 0..count {
        let msg = ipc_r.recv(Some(10_000)).unwrap_or_default();
        if msg.is_empty() {
            eprintln!("My Sample Client: message recv timed out");
            exit(5);
        }
        println!("My Sample Client: message recv: [{}]", text(&msg));
        // The service's receiver must be there before the first reply.
        if k == 0 && !ipc_w.wait_for_recv(1, Some(5_000)).unwrap_or(false) {
            eprintln!("My Sample Client: no service receiver within 5s");
            exit(2);
        }
        if !ipc_w.send_str("Copy.", 100).unwrap_or(false) {
            eprintln!("My Sample Client: message send error");
            exit(4);
        }
        println!("My Sample Client: message send [Copy]");
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let count = match args.get(1).map(String::as_str) {
        None => None,
        Some(n) if args.len() == 2 && n.parse::<u64>().is_ok() => n.parse().ok(),
        _ => {
            eprintln!("usage:\n  demo_linux_client\n  demo_linux_client <count>");
            exit(1);
        }
    };

    println!("My Sample Client: Entry");
    let mut ipc_r = Channel::connect("service ipc r", Mode::Receiver).expect("connect receiver");
    let mut ipc_w = Channel::connect("service ipc w", Mode::Sender).expect("connect sender");

    match count {
        None => run_forever(&mut ipc_r, &mut ipc_w),
        Some(n) => run_count(&mut ipc_r, &mut ipc_w, n),
    }
    println!("My Sample Client: Exit");
}
