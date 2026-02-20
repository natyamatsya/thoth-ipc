// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Rust port of demo/chat/main.cpp
//
// Usage: demo_chat   (run multiple instances in separate terminals)
//
// Each instance allocates a unique ID from a shared SHM counter, then
// simultaneously sends and receives messages on the "ipc-chat" channel.
// Type a message and press Enter to broadcast it.  Type "q" to quit.

use std::io::{self, BufRead, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;

use libipc::channel::{Channel, Mode};
use libipc::{ShmHandle, ShmOpenMode};

const CHANNEL_NAME: &str = "ipc-chat";
const QUIT: &str = "q";

fn calc_unique_id() -> u64 {
    let shm = ShmHandle::acquire(
        "__CHAT_ACC_STORAGE__",
        std::mem::size_of::<AtomicU64>(),
        ShmOpenMode::CreateOrOpen,
    )
    .expect("shm acquire");
    let counter = unsafe { &*(shm.get() as *const AtomicU64) };
    counter.fetch_add(1, Ordering::Relaxed)
}

fn main() {
    let id = format!("c{}", calc_unique_id());

    let mut sender = Channel::connect(CHANNEL_NAME, Mode::Sender).expect("sender");
    let mut receiver = Channel::connect(CHANNEL_NAME, Mode::Receiver).expect("receiver");

    let id_recv = id.clone();
    let recv_thread = thread::spawn(move || {
        println!("{id_recv} is ready.");
        loop {
            let buf = receiver.recv(None).expect("recv");
            if buf.is_empty() {
                break;
            }
            let dat = String::from_utf8_lossy(buf.data());
            // Strip null terminator if present.
            let dat = dat.trim_end_matches('\0');

            // Parse "cN> message" format.
            if let Some((from_id, msg)) = dat.split_once("> ") {
                if from_id == id_recv {
                    if msg == QUIT {
                        break;
                    }
                    continue; // skip own messages
                }
            }
            println!("{dat}");
        }
        println!("{id_recv} receiver is quit...");
    });

    let stdin = io::stdin();
    loop {
        print!("> ");
        io::stdout().flush().ok();
        let mut line = String::new();
        if stdin.lock().read_line(&mut line).is_err() || line.trim().is_empty() {
            break;
        }
        let trimmed = line.trim();
        if trimmed == QUIT {
            break;
        }
        let msg = format!("{id}> {trimmed}\0");
        sender.send(msg.as_bytes(), 0).expect("send");
    }

    // Send quit marker so the recv thread exits.
    let quit_msg = format!("{id}> {QUIT}\0");
    sender.send(quit_msg.as_bytes(), 0).expect("send quit");
    sender.disconnect();

    recv_thread.join().unwrap();
    println!("{id} sender is quit...");
}
