// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Rust port of demo/linux_service/service/main.cpp
//
// Usage (start the client first, then the service):
//   demo_linux_service            send "Hello, World!" every 3 s, forever
//   demo_linux_service <count>    exchange <count> messages with the client, then exit
//   demo_linux_service clear      remove both channels, so the next run starts fresh
//
// The service sends on "service ipc r" and receives the client's "Copy." reply
// on "service ipc w" (both multi-writer `thoth::channel`). Strings go on the
// wire with their trailing NUL (`send_str`), byte-exact with the C++ and Zig
// ports, so the service and the client can be any mix of languages.

use std::process::exit;
use std::thread;
use std::time::Duration;

use thoth_ipc::buffer::IpcBuffer;
use thoth_ipc::channel::{Channel, Mode};

const NAME_R: &str = "service ipc r";
const NAME_W: &str = "service ipc w";

/// The payload without the trailing NUL the senders append.
fn text(buf: &IpcBuffer) -> String {
    let d = buf.data();
    let d = d.strip_suffix(&[0]).unwrap_or(d);
    String::from_utf8_lossy(d).into_owned()
}

fn run_forever(ipc_r: &mut Channel, ipc_w: &mut Channel) -> ! {
    loop {
        if !ipc_r.send_str("Hello, World!", 100).unwrap_or(false) {
            println!("My Sample Service: send failed.");
        } else {
            println!("My Sample Service: send [Hello, World!]");
            match ipc_w.recv(Some(1000)) {
                Ok(msg) if !msg.is_empty() => println!("My Sample Service: recv [{}]", text(&msg)),
                _ => println!("My Sample Service: recv error"),
            }
        }
        thread::sleep(Duration::from_secs(3));
    }
}

fn run_count(ipc_r: &mut Channel, ipc_w: &mut Channel, count: u64) {
    if !ipc_r.wait_for_recv(1, Some(5_000)).unwrap_or(false) {
        eprintln!("My Sample Service: no client within 5s - start the client first");
        exit(2);
    }
    for _ in 0..count {
        if !ipc_r.send_str("Hello, World!", 100).unwrap_or(false) {
            eprintln!("My Sample Service: send failed.");
            exit(4);
        }
        println!("My Sample Service: send [Hello, World!]");
        let msg = ipc_w.recv(Some(5_000)).unwrap_or_default();
        if msg.is_empty() {
            eprintln!("My Sample Service: recv timed out");
            exit(5);
        }
        let reply = text(&msg);
        if reply != "Copy." {
            eprintln!("My Sample Service: unexpected reply [{reply}]");
            exit(6);
        }
        println!("My Sample Service: recv [{reply}]");
        thread::sleep(Duration::from_millis(100));
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let count = match args.get(1).map(String::as_str) {
        Some("clear") if args.len() == 2 => {
            Channel::clear_storage(NAME_R);
            Channel::clear_storage(NAME_W);
            return;
        }
        None => None,
        Some(n) if args.len() == 2 && n.parse::<u64>().is_ok() => n.parse().ok(),
        _ => {
            eprintln!(
                "usage:\n  demo_linux_service\n  demo_linux_service <count>\n  \
                 demo_linux_service clear"
            );
            exit(1);
        }
    };

    println!("My Sample Service: Main: Entry");
    let mut ipc_r = Channel::connect(NAME_R, Mode::Sender).expect("connect sender");
    let mut ipc_w = Channel::connect(NAME_W, Mode::Receiver).expect("connect receiver");

    match count {
        None => run_forever(&mut ipc_r, &mut ipc_w),
        Some(n) => run_count(&mut ipc_r, &mut ipc_w, n),
    }
    println!("My Sample Service: Main: Exit");
}
