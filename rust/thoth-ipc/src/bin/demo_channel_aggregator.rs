// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Multi-writer `thoth::channel` fan-in aggregator.
//
// Usage (run the collector first, then one or more producers):
//   demo_channel_aggregator collect <total>
//   demo_channel_aggregator produce <id> <count>
//
// N producer processes each `send` into ONE shared `thoth::channel`; a single
// collector `recv`s the merged, correctly-reassembled stream and tallies it by
// producer. This is the pattern a single-writer `thoth::route` cannot express —
// a `channel` has multiple committing writers. Because the wire format is
// byte-exact across the C++, Rust, Swift and Zig ports, the producers and the
// collector can be any mix of languages (see the repo README).

use std::collections::BTreeMap;

use thoth_ipc::channel::{Channel, Mode};

const CHANNEL: &str = "ipc-aggregator";

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("collect") => collect(parse(&args, 2, 0)),
        Some("produce") => {
            let id = args.get(2).cloned().unwrap_or_else(|| "p".into());
            produce(&id, parse(&args, 3, 0));
        }
        _ => {
            eprintln!(
                "usage:\n  demo_channel_aggregator collect <total>\n  \
                 demo_channel_aggregator produce <id> <count>"
            );
            std::process::exit(1);
        }
    }
}

fn parse(args: &[String], i: usize, default: usize) -> usize {
    args.get(i).and_then(|s| s.parse().ok()).unwrap_or(default)
}

/// The single reader: drains `total` messages from every producer and tallies.
fn collect(total: usize) {
    let mut ch = Channel::connect(CHANNEL, Mode::Receiver).expect("connect receiver");
    println!("[collector] ready on '{CHANNEL}', expecting {total} messages from any number of producers");

    let mut tally: BTreeMap<String, usize> = BTreeMap::new();
    let mut got = 0usize;
    while got < total {
        let buf = ch.recv(Some(10_000)).expect("recv");
        if buf.is_empty() {
            eprintln!("[collector] timed out with {got}/{total} received");
            break;
        }
        let msg = String::from_utf8_lossy(buf.data());
        let msg = msg.trim_end_matches('\0');
        let producer = msg.split(" #").next().unwrap_or("?").to_string();
        *tally.entry(producer).or_default() += 1;
        got += 1;
        println!("[collector] {got:>4}/{total}  {msg}");
    }

    println!("\n[collector] summary — {got} messages from {} producer(s):", tally.len());
    for (p, n) in &tally {
        println!("    {p:<16} {n}");
    }
}

/// One of N concurrent writers: sends `count` tagged messages into the channel.
fn produce(id: &str, count: usize) {
    let mut ch = Channel::connect(CHANNEL, Mode::Sender).expect("connect sender");
    // A channel `send` reaches no one without a receiver — wait for the collector.
    if !ch.wait_for_recv(1, Some(5_000)).unwrap_or(false) {
        eprintln!("[producer {id}] no collector within 5s — start the collector first");
        std::process::exit(2);
    }
    for k in 0..count {
        let msg = format!("{id} #{k}");
        // `send` returns false only if the ring is momentarily full (a reader is
        // catching up) or times out; retry until the message is committed.
        while !ch.send_str(&msg, 2_000).unwrap_or(false) {}
    }
    println!("[producer {id}] sent {count} messages into '{CHANNEL}'");
    ch.disconnect();
}
