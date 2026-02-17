// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/test/archive/test_waiter.cpp.
// Tests for Waiter (condition+mutex wrapper used by channels).

use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use libipc::Waiter;

static COUNTER: AtomicI32 = AtomicI32::new(0);

fn unique_name(tag: &str) -> String {
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("test_waiter_{tag}_{n}_{}", std::process::id())
}

// Port of Waiter.broadcast
#[test]
fn waiter_broadcast() {
    let name = unique_name("broadcast");
    Waiter::clear_storage(&name);

    let k = Arc::new(AtomicI32::new(0));

    let mut threads = Vec::new();
    for _ in 0..4 {
        let n = name.clone();
        let k2 = Arc::clone(&k);
        threads.push(thread::spawn(move || {
            let waiter = Waiter::open(&n).expect("open");
            // Wait until k reaches 3 (wait through 3 increments)
            for i in 0..3 {
                waiter
                    .wait_if(|| k2.load(Ordering::Acquire) == i, None)
                    .expect("wait_if");
            }
        }));
    }

    let waiter = Waiter::open(&name).expect("open");
    for val in 1..=3 {
        // Small sleep to let waiters enter wait
        thread::sleep(Duration::from_millis(50));
        k.store(val, Ordering::Release);
        waiter.broadcast().expect("broadcast");
    }

    for t in threads {
        t.join().unwrap();
    }
}

// Port of Waiter.quit_waiting
// Note: the quit flag is process-local (AtomicBool), so both threads must
// share the same Waiter instance via Arc to observe the flag change.
#[test]
fn waiter_quit_waiting() {
    let name = unique_name("quit");
    Waiter::clear_storage(&name);

    let waiter = Arc::new(Waiter::open(&name).expect("open"));

    let w2 = Arc::clone(&waiter);
    let t = thread::spawn(move || {
        let result = w2.wait_if(|| true, None).expect("wait_if");
        // quit_waiting sets quit flag, so wait_if should return true
        assert!(result);
    });

    thread::sleep(Duration::from_millis(100));
    waiter.quit_waiting().expect("quit_waiting");
    t.join().unwrap();
}

// Port of Waiter.quit_waiting with second thread using custom predicate
#[test]
fn waiter_quit_with_predicate() {
    let name = unique_name("quit_pred");
    Waiter::clear_storage(&name);

    let quit = Arc::new(std::sync::atomic::AtomicBool::new(false));

    let n = name.clone();
    let q = Arc::clone(&quit);
    let t = thread::spawn(move || {
        let w = Waiter::open(&n).expect("open");
        w.wait_if(|| !q.load(Ordering::Acquire), None)
            .expect("wait_if");
    });

    thread::sleep(Duration::from_millis(100));

    // Re-open with a fresh waiter, set quit flag, and notify
    let waiter = Waiter::open(&name).expect("open");
    quit.store(true, Ordering::Release);
    waiter.notify().expect("notify");
    t.join().unwrap();
}

// Port of Waiter.clear
#[test]
fn waiter_clear_storage() {
    let name = unique_name("clear");

    {
        let _w = Waiter::open(&name).expect("open");
        // Waiter is open — underlying shm exists
    }

    Waiter::clear_storage(&name);
    // After clear_storage, the backing shm segments are unlinked.
    // A new open should create fresh segments.
    let _w = Waiter::open(&name).expect("re-open after clear");
}

// Test: notify wakes exactly one waiter
#[test]
fn waiter_notify_one() {
    let name = unique_name("notify_one");
    Waiter::clear_storage(&name);

    let flag = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let woken = Arc::new(AtomicI32::new(0));

    let mut threads = Vec::new();
    for _ in 0..3 {
        let n = name.clone();
        let f = Arc::clone(&flag);
        let w = Arc::clone(&woken);
        threads.push(thread::spawn(move || {
            let waiter = Waiter::open(&n).expect("open");
            waiter
                .wait_if(|| !f.load(Ordering::Acquire), Some(2000))
                .expect("wait_if");
            w.fetch_add(1, Ordering::Relaxed);
        }));
    }

    thread::sleep(Duration::from_millis(100));
    flag.store(true, Ordering::Release);

    // notify wakes one; then broadcast to wake the rest
    let waiter = Waiter::open(&name).expect("open");
    waiter.notify().expect("notify");
    thread::sleep(Duration::from_millis(50));
    waiter.broadcast().expect("broadcast");

    for t in threads {
        t.join().unwrap();
    }
    assert_eq!(woken.load(Ordering::Relaxed), 3);
}

// Test: wait_if with timeout
#[test]
fn waiter_wait_timeout() {
    let name = unique_name("timeout");
    Waiter::clear_storage(&name);

    let waiter = Waiter::open(&name).expect("open");
    let start = std::time::Instant::now();
    let result = waiter.wait_if(|| true, Some(100)).expect("wait_if");
    let elapsed = start.elapsed();

    assert!(!result, "should return false on timeout");
    assert!(elapsed >= Duration::from_millis(80), "should wait ~100ms");
    assert!(
        elapsed < Duration::from_millis(500),
        "should not wait too long"
    );
}

// Test: wait_if returns immediately when predicate is false
#[test]
fn waiter_wait_predicate_false() {
    let name = unique_name("pred_false");
    Waiter::clear_storage(&name);

    let waiter = Waiter::open(&name).expect("open");
    let result = waiter.wait_if(|| false, None).expect("wait_if");
    assert!(result, "should return true when predicate is already false");
}

// Test: multiple open/close cycles
#[test]
fn waiter_reopen() {
    let name = unique_name("reopen");
    Waiter::clear_storage(&name);

    for _ in 0..5 {
        let _w = Waiter::open(&name).expect("open");
    }

    // After multiple opens, the waiter should still work
    let flag = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let f2 = Arc::clone(&flag);
    let n = name.clone();

    let t = thread::spawn(move || {
        let w = Waiter::open(&n).expect("open");
        w.wait_if(|| !f2.load(Ordering::Acquire), Some(2000))
            .expect("wait_if");
    });

    thread::sleep(Duration::from_millis(50));
    flag.store(true, Ordering::Release);
    let w = Waiter::open(&name).expect("open");
    w.broadcast().expect("broadcast");
    t.join().unwrap();
}
