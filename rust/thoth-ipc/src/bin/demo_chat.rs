// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Rust port of demo/chat/main.cpp
//
// Usage:
//   demo_chat                      interactive (run several in separate terminals)
//   demo_chat bot <lines> <peers>  scripted: wait for <peers> chatters (itself
//                                  included), send "cN> line-<i>" <lines> times
//                                  and exit once it has <lines> lines from every
//                                  other one
//   demo_chat clear                remove the channel and the id counter
//
// Each instance allocates a unique ID from a shared SHM counter, then
// simultaneously sends and receives messages on the "ipc-chat" channel.
// Type a message and press Enter to broadcast it.  Type "q" to quit.

use std::collections::HashMap;
use std::io::{self, BufRead, Write};
use std::process::exit;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;

use thoth_ipc::channel::{Channel, Mode};
use thoth_ipc::{ShmHandle, ShmOpenMode};

const CHANNEL_NAME: &str = "ipc-chat";
const QUIT: &str = "q";
const ACC_STORAGE: &str = "__CHAT_ACC_STORAGE__";

/// Returns the id AND the shm handle: like the C++ demo's `static` handle, it
/// must stay alive for the process lifetime, or the counter segment is
/// unlinked on drop and the next instance restarts numbering at 0.
fn calc_unique_id() -> (u64, ShmHandle) {
    let shm = ShmHandle::acquire(
        ACC_STORAGE,
        std::mem::size_of::<AtomicU64>(),
        ShmOpenMode::CreateOrOpen,
    )
    .expect("shm acquire");
    let counter = unsafe { &*(shm.get() as *const AtomicU64) };
    let id = counter.fetch_add(1, Ordering::Relaxed);
    (id, shm)
}

/// Scripted chatter: rendezvous with `peers` receivers, send `lines` lines,
/// then read until every other chatter's `lines` lines have arrived.
fn bot(lines: usize, peers: usize) -> i32 {
    let (unique, _shm_guard) = calc_unique_id();
    let id = format!("c{unique}");

    let mut sender = Channel::connect(CHANNEL_NAME, Mode::Sender).expect("sender");
    let mut receiver = Channel::connect(CHANNEL_NAME, Mode::Receiver).expect("receiver");
    println!("{id} is ready.");

    if !sender.wait_for_recv(peers, Some(10_000)).unwrap_or(false) {
        eprintln!("{id}: {peers} chatters did not show up within 10s");
        return 2;
    }
    for i in 0..lines {
        if !sender
            .send_str(&format!("{id}> line-{i}"), 2000)
            .unwrap_or(false)
        {
            eprintln!("{id}: send failed");
            return 4;
        }
    }

    let mut got: HashMap<String, usize> = HashMap::new(); // foreign id -> lines
    let mut done = 0; // foreign ids with all `lines` lines
    while lines > 0 && done + 1 < peers {
        let buf = match receiver.recv(Some(10_000)) {
            Ok(b) if !b.is_empty() => b,
            _ => {
                eprintln!("{id}: timed out waiting for chat lines");
                return 5;
            }
        };
        let dat = String::from_utf8_lossy(buf.data());
        let dat = dat.trim_end_matches('\0');
        if let Some((from_id, msg)) = dat.split_once("> ") {
            if from_id == id || msg == QUIT {
                continue;
            }
            let n = got.entry(from_id.to_string()).or_insert(0);
            *n += 1;
            if *n == lines {
                done += 1;
            }
        }
        println!("{dat}");
    }
    0
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        None => interactive(),
        Some("bot") if args.len() > 3 => exit(bot(
            args[2].parse().unwrap_or(0),
            args[3].parse().unwrap_or(0),
        )),
        Some("clear") => {
            Channel::clear_storage(CHANNEL_NAME);
            ShmHandle::clear_storage(ACC_STORAGE);
        }
        _ => {
            eprintln!("usage:\n  demo_chat\n  demo_chat bot <lines> <peers>\n  demo_chat clear");
            exit(1);
        }
    }
}

fn interactive() {
    let (unique, _shm_guard) = calc_unique_id();
    let id = format!("c{unique}");

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
        // send_str appends the null terminator a C++ receiver expects.
        sender
            .send_str(&format!("{id}> {trimmed}"), 0)
            .expect("send");
    }

    // Send quit marker so the recv thread exits.
    sender
        .send_str(&format!("{id}> {QUIT}"), 0)
        .expect("send quit");
    sender.disconnect();

    recv_thread.join().unwrap();
    println!("{id} sender is quit...");
}
