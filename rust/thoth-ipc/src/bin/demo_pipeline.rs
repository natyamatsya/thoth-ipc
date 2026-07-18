// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Polyglot pipeline stage — one hop of a multi-language `thoth::route` pipeline.
//
// Usage:
//   demo_pipeline source <out> <count> <tag>
//   demo_pipeline stage  <in> <out> <count> <tag>
//   demo_pipeline sink   <in> <count> <tag>
//
// A pipeline is a chain of single-writer→single-reader `thoth::route` hops, each
// hop a separate process — and, because the wire format is byte-exact across
// the C++, Rust, Swift and Zig ports, each stage can be a *different language*.
// The `source` seeds items, every `stage` appends its tag, and the `sink` prints
// the fully-transformed item, so one printed line shows every language a message
// passed through. See `demo/pipeline/run.sh` and the repo README.

use thoth_ipc::channel::{Mode, Route};

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let n = |i: usize| a.get(i).and_then(|s| s.parse::<usize>().ok()).unwrap_or(0);
    let s = |i: usize| a.get(i).cloned().unwrap_or_default();

    match a.get(1).map(String::as_str) {
        Some("source") if a.len() >= 5 => source(&s(2), n(3), &s(4)),
        Some("stage") if a.len() >= 6 => stage(&s(2), &s(3), n(4), &s(5)),
        Some("sink") if a.len() >= 5 => sink(&s(2), n(3), &s(4)),
        _ => {
            eprintln!(
                "usage:\n  demo_pipeline source <out> <count> <tag>\n  \
                 demo_pipeline stage <in> <out> <count> <tag>\n  \
                 demo_pipeline sink <in> <count> <tag>"
            );
            std::process::exit(1);
        }
    }
}

fn decode(data: &[u8]) -> String {
    String::from_utf8_lossy(data).trim_end_matches('\0').to_string()
}

/// Head of the pipeline: emit `count` seed items into `out`.
fn source(out: &str, count: usize, tag: &str) {
    let mut tx = Route::connect(out, Mode::Sender).expect("connect sender");
    if !tx.wait_for_recv(1, Some(5_000)).unwrap_or(false) {
        eprintln!("[source {tag}] no downstream on '{out}' within 5s");
        std::process::exit(2);
    }
    for k in 0..count {
        let msg = format!("item-{k} [{tag}]");
        while !tx.send_str(&msg, 2_000).unwrap_or(false) {}
    }
    eprintln!("[source {tag}] emitted {count} items → '{out}'");
}

/// A middle hop: read from `in`, append this stage's tag, forward to `out`.
fn stage(in_: &str, out: &str, count: usize, tag: &str) {
    let mut rx = Route::connect(in_, Mode::Receiver).expect("connect receiver");
    let mut tx = Route::connect(out, Mode::Sender).expect("connect sender");
    if !tx.wait_for_recv(1, Some(5_000)).unwrap_or(false) {
        eprintln!("[stage {tag}] no downstream on '{out}' within 5s");
        std::process::exit(2);
    }
    for _ in 0..count {
        let buf = rx.recv(Some(10_000)).expect("recv");
        if buf.is_empty() {
            eprintln!("[stage {tag}] upstream stalled");
            std::process::exit(5);
        }
        let msg = format!("{} -> {tag}", decode(buf.data()));
        while !tx.send_str(&msg, 2_000).unwrap_or(false) {}
    }
    eprintln!("[stage {tag}] forwarded {count} items '{in_}' → '{out}'");
}

/// Tail of the pipeline: print the fully-transformed items.
fn sink(in_: &str, count: usize, tag: &str) {
    let mut rx = Route::connect(in_, Mode::Receiver).expect("connect receiver");
    eprintln!("[sink {tag}] ready on '{in_}', expecting {count} items");
    for i in 0..count {
        let buf = rx.recv(Some(10_000)).expect("recv");
        if buf.is_empty() {
            eprintln!("[sink {tag}] upstream stalled after {i}/{count}");
            break;
        }
        println!("{} -> [{tag} sink]", decode(buf.data()));
    }
}
