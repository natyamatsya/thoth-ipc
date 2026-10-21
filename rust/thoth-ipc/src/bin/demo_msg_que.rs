// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Rust port of demo/msg_que/main.cpp
//
// Usage:
//   demo_msg_que s    (sender — measures throughput)
//   demo_msg_que r    (receiver — measures throughput)
//   demo_msg_que s <count>   (sender — count mode, see below)
//   demo_msg_que r <count>   (receiver — count mode, see below)
//   demo_msg_que clear       (remove the route's IPC objects)
//
// Uses thoth::route (single-producer, multi-consumer broadcast).
// The sender sends random-sized messages (128 B – 16 KB) as fast as
// possible and prints throughput every second.  The receiver does the same.
//
// Count mode is bounded and verifiable (wire- and output-identical across the
// C++/Rust/Swift/Zig ports): the sender waits up to 5 s for a receiver (else
// exit 2), then sends <count> messages, the k-th being size_k bytes all equal to
// k % 251, size_k = 128 + (k * 7919) % 16257 (2 s send timeout, else exit 4),
// and prints `do_send: sent <count> messages, <bytes> bytes`. The receiver
// prints `do_recv: ready`, checks every message (10 s recv timeout: exit 5;
// wrong size or bytes: exit 6) and prints
// `do_recv: received <count> messages, <bytes> bytes`.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use thoth_ipc::channel::{Mode, Route};

const CHANNEL_NAME: &str = "ipc-msg-que";
const MIN_SZ: usize = 128;
const MAX_SZ: usize = 1024 * 16;

fn str_of_size(sz: usize) -> String {
    if sz > 1024 * 1024 {
        format!("{} MB", sz / (1024 * 1024))
    } else if sz > 1024 {
        format!("{} KB", sz / 1024)
    } else {
        format!("{sz} bytes")
    }
}

fn speed_of(sz: usize) -> String {
    format!("{}/s", str_of_size(sz))
}

fn counting_thread(quit: Arc<AtomicBool>, counter: Arc<AtomicUsize>) {
    let mut i = 1usize;
    while !quit.load(Ordering::Acquire) {
        thread::sleep(Duration::from_millis(100));
        i += 1;
        if i % 10 != 0 {
            continue;
        }
        i = 0;
        let bytes = counter.swap(0, Ordering::Relaxed);
        println!("{}", speed_of(bytes));
    }
}

fn do_send(quit: Arc<AtomicBool>) {
    println!(
        "do_send: start [{} - {}]...",
        str_of_size(MIN_SZ),
        str_of_size(MAX_SZ)
    );

    Route::clear_storage(CHANNEL_NAME);
    let mut que = Route::connect(CHANNEL_NAME, Mode::Sender).expect("connect sender");

    println!("do_send: waiting for receiver...");
    que.wait_for_recv(1, None).expect("wait_for_recv");
    println!("do_send: receiver connected, starting");

    let counter = Arc::new(AtomicUsize::new(0));

    let q2 = Arc::clone(&quit);
    let c2 = Arc::clone(&counter);
    let counting = thread::spawn(move || counting_thread(q2, c2));

    // Simple LCG for fast pseudo-random sizes without external deps.
    let mut rng_state: u64 = 0xdeadbeef_cafebabe;
    let buf = vec![0u8; MAX_SZ];

    while !quit.load(Ordering::Acquire) {
        rng_state = rng_state
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let sz = MIN_SZ + (rng_state >> 32) as usize % (MAX_SZ - MIN_SZ + 1);

        que.send(&buf[..sz], 0).expect("send");
        counter.fetch_add(sz, Ordering::Relaxed);
        thread::yield_now();
    }

    counting.join().unwrap();
    println!("do_send: quit...");
}

fn do_recv(quit: Arc<AtomicBool>) {
    println!(
        "do_recv: start [{} - {}]...",
        str_of_size(MIN_SZ),
        str_of_size(MAX_SZ)
    );

    let mut que = Route::connect(CHANNEL_NAME, Mode::Receiver).expect("connect receiver");
    let counter = Arc::new(AtomicUsize::new(0));

    let q2 = Arc::clone(&quit);
    let c2 = Arc::clone(&counter);
    let counting = thread::spawn(move || counting_thread(q2, c2));

    while !quit.load(Ordering::Acquire) {
        let msg = que.recv(Some(200)).expect("recv");
        if msg.is_empty() {
            continue;
        }
        counter.fetch_add(msg.len(), Ordering::Relaxed);
    }

    counting.join().unwrap();
    println!("do_recv: quit...");
}

// --- Count mode (deterministic, verifiable; used by the cross-language runner) ---

/// Size of the k-th count-mode message: 128 B .. 16 KB, spread by a prime stride.
fn size_of_k(k: usize) -> usize {
    MIN_SZ + (k * 7919) % (MAX_SZ - MIN_SZ + 1)
}

/// Fill byte of the k-th count-mode message.
fn byte_of_k(k: usize) -> u8 {
    (k % 251) as u8
}

fn do_send_count(count: usize) -> i32 {
    let mut que = match Route::connect(CHANNEL_NAME, Mode::Sender) {
        Ok(q) => q,
        Err(e) => {
            eprintln!("do_send: connect failed: {e}");
            return 3;
        }
    };
    if !que.wait_for_recv(1, Some(5000)).unwrap_or(false) {
        eprintln!("do_send: no receiver within 5 s.");
        return 2;
    }
    let mut buf = vec![0u8; MAX_SZ];
    let mut total = 0usize;
    for k in 0..count {
        let sz = size_of_k(k);
        buf[..sz].fill(byte_of_k(k));
        if !que.send(&buf[..sz], 2000).unwrap_or(false) {
            eprintln!("do_send: send of message {k} failed.");
            return 4;
        }
        total += sz;
    }
    println!("do_send: sent {count} messages, {total} bytes");
    0
}

fn do_recv_count(count: usize) -> i32 {
    let mut que = match Route::connect(CHANNEL_NAME, Mode::Receiver) {
        Ok(q) => q,
        Err(e) => {
            eprintln!("do_recv: connect failed: {e}");
            return 3;
        }
    };
    println!("do_recv: ready");
    let mut total = 0usize;
    for k in 0..count {
        let msg = match que.recv(Some(10_000)) {
            Ok(m) if !m.is_empty() => m,
            _ => {
                eprintln!("do_recv: timed out after {k}/{count} messages.");
                return 5;
            }
        };
        let data = msg.data();
        let ok = (MIN_SZ..=MAX_SZ).contains(&data.len())
            && data.len() == size_of_k(k)
            && data[0] == byte_of_k(k)
            && data.iter().all(|&b| b == data[0]);
        if !ok {
            eprintln!(
                "do_recv: message {k} is corrupt ({} bytes, expected {} bytes of {}).",
                data.len(),
                size_of_k(k),
                byte_of_k(k)
            );
            return 6;
        }
        total += data.len();
    }
    println!("do_recv: received {count} messages, {total} bytes");
    0
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: demo_msg_que s|r [<count>] | clear");
        std::process::exit(1);
    }

    if args[1] == "clear" {
        Route::clear_storage(CHANNEL_NAME);
        return;
    }
    if args.len() >= 3 && (args[1] == "s" || args[1] == "r") {
        let Ok(count) = args[2].parse::<usize>() else {
            eprintln!("invalid count: {}", args[2]);
            std::process::exit(1);
        };
        let code = if args[1] == "s" {
            do_send_count(count)
        } else {
            do_recv_count(count)
        };
        std::process::exit(code);
    }

    let quit = Arc::new(AtomicBool::new(false));

    {
        let q = Arc::clone(&quit);
        ctrlc_or_sigterm(move || q.store(true, Ordering::Release));
    }

    match args[1].as_str() {
        "s" => do_send(quit),
        "r" => do_recv(quit),
        other => {
            eprintln!("unknown mode: {other}  (use 's' or 'r')");
            std::process::exit(1);
        }
    }
}

fn ctrlc_or_sigterm(f: impl Fn() + Send + 'static) {
    #[cfg(unix)]
    {
        use std::sync::Mutex;
        static CB: std::sync::OnceLock<Mutex<Box<dyn Fn() + Send>>> = std::sync::OnceLock::new();
        CB.get_or_init(|| Mutex::new(Box::new(f)));
        extern "C" fn handler(_: libc::c_int) {
            if let Some(cb) = CB.get() {
                if let Ok(g) = cb.lock() {
                    g();
                }
            }
        }
        unsafe {
            libc::signal(libc::SIGINT, handler as *const () as libc::sighandler_t);
            libc::signal(libc::SIGTERM, handler as *const () as libc::sighandler_t);
            libc::signal(libc::SIGHUP, handler as *const () as libc::sighandler_t);
        }
    }
    #[cfg(not(unix))]
    {
        let _ = f;
    }
}

#[cfg(unix)]
extern crate libc;
