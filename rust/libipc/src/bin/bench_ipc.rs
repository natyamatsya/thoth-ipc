// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use libipc::channel::{Channel, Mode, Route};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

struct Stats {
    total_ms: f64,
    count: usize,
}

impl Stats {
    fn us_per_datum(&self) -> f64 {
        (self.total_ms * 1000.0) / self.count as f64
    }
}

// ---------------------------------------------------------------------------
// ipc::route  —  1 sender, N receivers  (random msg_lo–msg_hi bytes × count)
// ---------------------------------------------------------------------------

fn bench_route(n_receivers: usize, count: usize, msg_lo: usize, msg_hi: usize) -> Stats {
    let name = "bench_route";

    let mut threads = Vec::new();

    // prepare random payloads
    let mut sizes = Vec::with_capacity(count);
    let mut rng_state: u64 = 42;
    for _ in 0..count {
        rng_state = rng_state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let s = msg_lo + (rng_state >> 32) as usize % (msg_hi - msg_lo + 1);
        sizes.push(s);
    }
    let payload = vec![b'X'; msg_hi];

    // sender (created first so shm exists for receivers)
    Route::clear_storage(name);
    let mut sender = Route::connect(name, Mode::Sender).unwrap();

    let ready = Arc::new(AtomicBool::new(false));
    let done = Arc::new(AtomicBool::new(false));

    // receivers
    for _ in 0..n_receivers {
        let ready_clone = ready.clone();
        let done_clone = done.clone();
        threads.push(thread::spawn(move || {
            let mut r = Route::connect(name, Mode::Receiver).unwrap();
            while !ready_clone.load(Ordering::Acquire) {
                thread::yield_now();
            }
            while !done_clone.load(Ordering::Acquire) {
                let _buf = r.recv(Some(100));
            }
        }));
    }

    // let receivers connect
    thread::sleep(Duration::from_millis(100));
    ready.store(true, Ordering::Release);

    let t0 = Instant::now();

    for &size in &sizes {
        sender.send(&payload[..size], 0).unwrap();
    }

    let t1 = Instant::now();
    let total_ms = t1.duration_since(t0).as_secs_f64() * 1000.0;

    // signal done, disconnect sender to unblock receivers, then join
    done.store(true, Ordering::Release);
    sender.disconnect();
    for t in threads {
        t.join().unwrap();
    }

    Stats { total_ms, count }
}

// ---------------------------------------------------------------------------
// ipc::channel  —  pattern  (random msg_lo–msg_hi bytes × count)
//   pattern: "1-N"  = 1 sender,  N receivers
//            "N-1"  = N senders, 1 receiver
//            "N-N"  = N senders, N receivers
// ---------------------------------------------------------------------------

fn bench_channel(pattern: &str, n: usize, count: usize, msg_lo: usize, msg_hi: usize) -> Stats {
    let name = "bench_chan";

    let n_senders = if pattern == "N-1" || pattern == "N-N" { n } else { 1 };
    let n_receivers = if pattern == "1-N" || pattern == "N-N" { n } else { 1 };

    let per_sender = count / n_senders;

    // prepare random payloads
    let mut sizes = Vec::with_capacity(count);
    let mut rng_state: u64 = 42;
    for _ in 0..count {
        rng_state = rng_state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let s = msg_lo + (rng_state >> 32) as usize % (msg_hi - msg_lo + 1);
        sizes.push(s);
    }
    let payload = vec![b'X'; msg_hi];

    // a "control" channel to keep shm alive; also used to disconnect receivers
    Channel::clear_storage(name);
    let mut ctrl = Channel::connect(name, Mode::Sender).unwrap();

    let ready = Arc::new(AtomicBool::new(false));
    let done = Arc::new(AtomicBool::new(false));

    let mut recv_threads = Vec::new();

    // receivers
    for _ in 0..n_receivers {
        let ready_clone = ready.clone();
        let done_clone = done.clone();
        recv_threads.push(thread::spawn(move || {
            let mut ch = Channel::connect(name, Mode::Receiver).unwrap();
            while !ready_clone.load(Ordering::Acquire) {
                thread::yield_now();
            }
            while !done_clone.load(Ordering::Acquire) {
                let _buf = ch.recv(Some(100));
            }
        }));
    }

    thread::sleep(Duration::from_millis(100));
    ready.store(true, Ordering::Release);

    let t0 = Instant::now();

    // senders
    let mut sender_threads = Vec::new();
    let sizes_arc = Arc::new(sizes);
    for s in 0..n_senders {
        let sizes_clone = sizes_arc.clone();
        let p = payload.clone();
        sender_threads.push(thread::spawn(move || {
            let mut ch = Channel::connect(name, Mode::Sender).unwrap();
            let base = s * per_sender;
            for i in 0..per_sender {
                ch.send(&p[..sizes_clone[base + i]], 0).unwrap();
            }
        }));
    }
    for t in sender_threads {
        t.join().unwrap();
    }

    let t1 = Instant::now();
    let total_ms = t1.duration_since(t0).as_secs_f64() * 1000.0;

    done.store(true, Ordering::Release);
    ctrl.disconnect();
    for t in recv_threads {
        t.join().unwrap();
    }

    Stats { total_ms, count }
}

fn print_header(title: &str) {
    println!("\n=== {} ===", title);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let max_threads = if args.len() > 1 {
        args[1].parse().unwrap_or(8)
    } else {
        8
    };

    println!("cpp-ipc benchmark (Rust port)");
    let os = if cfg!(target_os = "macos") {
        "macOS"
    } else if cfg!(target_os = "linux") {
        "Linux"
    } else if cfg!(target_os = "windows") {
        "Windows"
    } else {
        "Unknown"
    };
    println!("Platform: {}, {} hardware threads\n", os, std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1));

    // -----------------------------------------------------------------------
    print_header("ipc::route — 1 sender, N receivers (random 2-256 bytes x 100000)");
    println!("{:>10}  {:>12}  {:>12}", "Receivers", "RTT (ms)", "us/datum");
    println!("{:>10}  {:>12}  {:>12}", "----------", "----------", "----------");

    let mut n = 1;
    while n <= max_threads {
        let s = bench_route(n, 100000, 2, 256);
        println!("{:>10}  {:>12.2}  {:>12.3}", n, s.total_ms, s.us_per_datum());
        n *= 2;
    }

    // -----------------------------------------------------------------------
    print_header("ipc::channel — 1-N (random 2-256 bytes x 100000)");
    println!("{:>10}  {:>12}  {:>12}", "Receivers", "RTT (ms)", "us/datum");
    println!("{:>10}  {:>12}  {:>12}", "----------", "----------", "----------");

    let mut n = 1;
    while n <= max_threads {
        let s = bench_channel("1-N", n, 100000, 2, 256);
        println!("{:>10}  {:>12.2}  {:>12.3}", n, s.total_ms, s.us_per_datum());
        n *= 2;
    }

    // -----------------------------------------------------------------------
    print_header("ipc::channel — N-1 (random 2-256 bytes x 100000)");
    println!("{:>10}  {:>12}  {:>12}", "Senders", "RTT (ms)", "us/datum");
    println!("{:>10}  {:>12}  {:>12}", "----------", "----------", "----------");

    let mut n = 1;
    while n <= max_threads {
        let s = bench_channel("N-1", n, 100000, 2, 256);
        println!("{:>10}  {:>12.2}  {:>12.3}", n, s.total_ms, s.us_per_datum());
        n *= 2;
    }

    // -----------------------------------------------------------------------
    print_header("ipc::channel — N-N (random 2-256 bytes x 100000)");
    println!("{:>10}  {:>12}  {:>12}", "Threads", "RTT (ms)", "us/datum");
    println!("{:>10}  {:>12}  {:>12}", "----------", "----------", "----------");

    let mut n = 1;
    while n <= max_threads {
        let s = bench_channel("N-N", n, 100000, 2, 256);
        println!("{:>10}  {:>12.2}  {:>12.3}", n, s.total_ms, s.us_per_datum());
        n *= 2;
    }

    println!("\nDone.");
}
