// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of high-throughput prod_cons tests from cpp-ipc/test/archive/test_queue.cpp.
// Stress tests for the channel with varying sender/receiver counts and high message volumes.

use std::sync::atomic::{AtomicI32, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use libipc::{Channel, Mode, Route};

static COUNTER: AtomicI32 = AtomicI32::new(0);

fn unique_name(tag: &str) -> String {
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("stress_{tag}_{n}_{}", std::process::id())
}

// Port of Queue.prod_cons_1v1 — single sender, single receiver, many messages
#[test]
fn route_1v1_throughput() {
    let name = unique_name("r_1v1");
    Route::clear_storage(&name);

    let msg_count = 1000usize;
    let received = Arc::new(AtomicU64::new(0));

    let n = name.clone();
    let rc = Arc::clone(&received);
    let receiver = thread::spawn(move || {
        let mut r = Route::connect(&n, Mode::Receiver).expect("receiver");
        for _ in 0..msg_count {
            let buf = r.recv(Some(5000)).expect("recv");
            if !buf.is_empty() {
                rc.fetch_add(1, Ordering::Relaxed);
            }
        }
    });

    thread::sleep(Duration::from_millis(50));

    let mut sender = Route::connect(&name, Mode::Sender).expect("sender");
    sender.wait_for_recv(1, Some(2000)).expect("wait");

    let start = Instant::now();
    for i in 0..msg_count {
        let msg = i.to_le_bytes();
        assert!(sender.send(&msg, 5000).expect("send"));
    }
    let elapsed = start.elapsed();

    receiver.join().unwrap();

    assert_eq!(received.load(Ordering::Relaxed), msg_count as u64);
    eprintln!(
        "route 1v1: {msg_count} msgs in {:.1}ms ({:.0} msg/s)",
        elapsed.as_secs_f64() * 1000.0,
        msg_count as f64 / elapsed.as_secs_f64()
    );
}

// Port of Queue.prod_cons_1vN_broadcast — 1 sender, N receivers
#[test]
fn route_1vn_broadcast() {
    for num_receivers in [2, 4] {
        let name = unique_name("r_1vn");
        Route::clear_storage(&name);

        let msg_count = 500usize;
        let total_received = Arc::new(AtomicU64::new(0));

        let mut receivers = Vec::new();
        for _ in 0..num_receivers {
            let n = name.clone();
            let rc = Arc::clone(&total_received);
            receivers.push(thread::spawn(move || {
                let mut r = Route::connect(&n, Mode::Receiver).expect("receiver");
                for _ in 0..msg_count {
                    let buf = r.recv(Some(5000)).expect("recv");
                    if !buf.is_empty() {
                        rc.fetch_add(1, Ordering::Relaxed);
                    }
                }
            }));
        }

        thread::sleep(Duration::from_millis(100));

        let mut sender = Route::connect(&name, Mode::Sender).expect("sender");
        sender
            .wait_for_recv(num_receivers, Some(2000))
            .expect("wait");

        let start = Instant::now();
        for i in 0..msg_count {
            let msg = i.to_le_bytes();
            assert!(sender.send(&msg, 5000).expect("send"));
        }
        let elapsed = start.elapsed();

        for r in receivers {
            r.join().unwrap();
        }

        let total = total_received.load(Ordering::Relaxed);
        assert_eq!(total, (msg_count * num_receivers) as u64);
        eprintln!(
            "route 1v{num_receivers}: {msg_count} msgs in {:.1}ms ({:.0} msg/s, {total} total recvd)",
            elapsed.as_secs_f64() * 1000.0,
            msg_count as f64 / elapsed.as_secs_f64()
        );
    }
}

// Port of Queue.prod_cons_NvN_broadcast — N senders, N receivers
#[test]
fn channel_nvn_broadcast() {
    for n in [2, 3] {
        let name = unique_name("c_nvn");
        Channel::clear_storage(&name);

        let msg_per_sender = 100usize;
        let total_msgs = n * msg_per_sender;
        let total_sent = Arc::new(AtomicU64::new(0));
        let total_received = Arc::new(AtomicU64::new(0));

        let mut receivers = Vec::new();
        for _ in 0..n {
            let nm = name.clone();
            let rc = Arc::clone(&total_received);
            receivers.push(thread::spawn(move || {
                let mut ch = Channel::connect(&nm, Mode::Receiver).expect("receiver");
                for _ in 0..total_msgs {
                    let buf = ch.recv(Some(5000)).expect("recv");
                    if !buf.is_empty() {
                        rc.fetch_add(1, Ordering::Relaxed);
                    }
                }
            }));
        }

        thread::sleep(Duration::from_millis(200));

        let mut senders = Vec::new();
        for s in 0..n {
            let nm = name.clone();
            let sc = Arc::clone(&total_sent);
            senders.push(thread::spawn(move || {
                let mut ch = Channel::connect(&nm, Mode::Sender).expect("sender");
                ch.wait_for_recv(n, Some(3000)).expect("wait");
                for j in 0..msg_per_sender {
                    let msg = format!("S{s}M{j}");
                    if ch.send(msg.as_bytes(), 5000).expect("send") {
                        sc.fetch_add(1, Ordering::Relaxed);
                    }
                }
            }));
        }

        for s in senders {
            s.join().unwrap();
        }
        for r in receivers {
            r.join().unwrap();
        }

        let sent = total_sent.load(Ordering::Relaxed);
        let received = total_received.load(Ordering::Relaxed);
        assert_eq!(sent, total_msgs as u64);
        assert_eq!(received, (total_msgs * n) as u64);
        eprintln!("channel {n}v{n}: {total_msgs} msgs, sent={sent}, received={received}");
    }
}

// Port of IPC.Nv1 — N senders, 1 receiver broadcast
#[test]
fn channel_nv1_broadcast() {
    for num_senders in [2usize, 4] {
        let name = unique_name("c_nv1");
        Channel::clear_storage(&name);

        let msg_per_sender = 100usize;
        let total_msgs = num_senders * msg_per_sender;
        let total_received = Arc::new(AtomicU64::new(0));

        let nm = name.clone();
        let rc = Arc::clone(&total_received);
        let receiver = thread::spawn(move || {
            let mut ch = Channel::connect(&nm, Mode::Receiver).expect("receiver");
            for _ in 0..total_msgs {
                let buf = ch.recv(Some(5000)).expect("recv");
                if !buf.is_empty() {
                    rc.fetch_add(1, Ordering::Relaxed);
                }
            }
        });

        thread::sleep(Duration::from_millis(100));

        let total_sent = Arc::new(AtomicU64::new(0));
        let mut senders = Vec::new();
        for s in 0..num_senders {
            let nm = name.clone();
            let sc = Arc::clone(&total_sent);
            senders.push(thread::spawn(move || {
                let mut ch = Channel::connect(&nm, Mode::Sender).expect("sender");
                ch.wait_for_recv(1, Some(3000)).expect("wait");
                for j in 0..msg_per_sender {
                    let msg = format!("S{s}M{j}");
                    if ch.send(msg.as_bytes(), 5000).expect("send") {
                        sc.fetch_add(1, Ordering::Relaxed);
                    }
                }
            }));
        }

        for s in senders {
            s.join().unwrap();
        }
        receiver.join().unwrap();

        let sent = total_sent.load(Ordering::Relaxed);
        let received = total_received.load(Ordering::Relaxed);
        assert_eq!(sent, total_msgs as u64);
        assert_eq!(received, total_msgs as u64);
        eprintln!("channel {num_senders}v1: {total_msgs} msgs, sent={sent}, received={received}");
    }
}

// Stress: rapid connect/disconnect cycles
#[test]
fn channel_rapid_reconnect() {
    let name = unique_name("reconnect");
    Channel::clear_storage(&name);

    for i in 0..20 {
        let mut sender = Channel::connect(&name, Mode::Sender).expect("sender");
        let mut receiver = Channel::connect(&name, Mode::Receiver).expect("receiver");

        sender.wait_for_recv(1, Some(1000)).expect("wait");
        let msg = format!("iter{i}");
        assert!(sender.send(msg.as_bytes(), 1000).expect("send"));

        let buf = receiver.recv(Some(1000)).expect("recv");
        assert!(!buf.is_empty());
        assert_eq!(buf.data(), msg.as_bytes());
    }
}

// Stress: large messages with fragmentation under load
#[test]
fn route_large_messages_stress() {
    let name = unique_name("large_stress");
    Route::clear_storage(&name);

    let msg_count = 20usize;
    let msg_size = 1024usize; // 1KB — requires 16 ring slots per message

    let n = name.clone();
    let receiver = thread::spawn(move || {
        let mut r = Route::connect(&n, Mode::Receiver).expect("receiver");
        for i in 0..msg_count {
            let buf = r.recv(Some(10000)).expect("recv");
            assert_eq!(buf.len(), msg_size, "msg {i} wrong size");
            assert!(
                buf.data().iter().all(|&b| b == (i as u8)),
                "msg {i} corrupt"
            );
        }
    });

    thread::sleep(Duration::from_millis(50));

    let mut sender = Route::connect(&name, Mode::Sender).expect("sender");
    sender.wait_for_recv(1, Some(2000)).expect("wait");

    for i in 0..msg_count {
        let msg = vec![i as u8; msg_size];
        assert!(sender.send(&msg, 10000).expect("send"));
    }

    receiver.join().unwrap();
}
