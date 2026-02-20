// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Rust port of demo/msg_que/main.cpp
//
// Usage:
//   demo_msg_que s    (sender — measures throughput)
//   demo_msg_que r    (receiver — measures throughput)
//
// Uses ipc::route (single-producer, multi-consumer broadcast).
// The sender sends random-sized messages (128 B – 16 KB) as fast as
// possible and prints throughput every second.  The receiver does the same.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use libipc::channel::{Mode, Route};

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

    let mut que = Route::connect(CHANNEL_NAME, Mode::Sender).expect("connect sender");
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

        if !que.send(&buf[..sz], 0).expect("send") {
            eprintln!("do_send: send failed — waiting for receiver...");
            if !que.wait_for_recv(1, None).expect("wait_for_recv") {
                eprintln!("do_send: wait receiver failed.");
                quit.store(true, Ordering::Release);
                break;
            }
        }
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

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: demo_msg_que s|r");
        std::process::exit(1);
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
