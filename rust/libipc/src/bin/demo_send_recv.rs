// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Rust port of demo/send_recv/main.cpp
//
// Usage:
//   demo_send_recv send <size> <interval_ms>
//   demo_send_recv recv <interval_ms>
//
// Two processes share a channel named "ipc".
// The sender fills a buffer of <size> bytes with 'A' and sends it every
// <interval_ms> milliseconds.  The receiver polls with a <interval_ms>
// timeout and prints the received size.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use libipc::channel::{Channel, Mode};

fn do_send(size: usize, interval_ms: u64, quit: Arc<AtomicBool>) {
    let mut ipc = Channel::connect("ipc", Mode::Sender).expect("connect sender");
    println!("send: waiting for receiver...");
    ipc.wait_for_recv(1, None).expect("wait_for_recv");
    println!("send: receiver connected, starting");
    let buffer = vec![b'A'; size];
    while !quit.load(Ordering::Acquire) {
        println!("send size: {}", buffer.len());
        ipc.send(&buffer, 0).expect("send");
        thread::sleep(Duration::from_millis(interval_ms));
    }
}

fn do_recv(interval_ms: u64, quit: Arc<AtomicBool>) {
    let mut ipc = Channel::connect("ipc", Mode::Receiver).expect("connect receiver");
    let mut k = 1usize;
    while !quit.load(Ordering::Acquire) {
        println!("recv waiting... {k}");
        let buf = ipc.recv(Some(interval_ms)).expect("recv");
        if quit.load(Ordering::Acquire) {
            return;
        }
        if buf.is_empty() {
            k += 1;
            continue;
        }
        println!("recv size: {}", buf.len());
        k = 1;
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: demo_send_recv send <size> <interval_ms>");
        eprintln!("       demo_send_recv recv <interval_ms>");
        std::process::exit(1);
    }

    let quit = Arc::new(AtomicBool::new(false));

    // Install signal handler via a simple flag.
    {
        let q = Arc::clone(&quit);
        ctrlc_or_sigterm(move || q.store(true, Ordering::Release));
    }

    match args[1].as_str() {
        "send" => {
            if args.len() < 4 {
                eprintln!("usage: demo_send_recv send <size> <interval_ms>");
                std::process::exit(1);
            }
            let size: usize = args[2].parse().expect("size");
            let interval: u64 = args[3].parse().expect("interval");
            Channel::clear_storage("ipc");
            do_send(size, interval, quit); // clears first, then waits for receiver
        }
        "recv" => {
            let interval: u64 = args[2].parse().expect("interval");
            do_recv(interval, quit);
        }
        other => {
            eprintln!("unknown mode: {other}");
            std::process::exit(1);
        }
    }
}

// Minimal cross-platform signal hook: sets the flag on SIGINT / SIGTERM.
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
        // On Windows just ignore — Ctrl-C will terminate the process.
        let _ = f;
    }
}

#[cfg(unix)]
extern crate libc;
