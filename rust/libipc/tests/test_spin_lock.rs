// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Rust port of cpp-ipc/test/test_locks.cpp (SpinLock section).

use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use libipc::SpinLock;

// Port of SpinLockTest.BasicLockUnlock
#[test]
fn basic_lock_unlock() {
    let lock = SpinLock::new();
    lock.lock();
    lock.unlock();
}

// Port of SpinLockTest.MultipleCycles
#[test]
fn multiple_cycles() {
    let lock = SpinLock::new();
    for _ in 0..100 {
        lock.lock();
        lock.unlock();
    }
}

// Port of SpinLockTest.CriticalSection
#[test]
fn critical_section() {
    let lock = Arc::new(SpinLock::new());
    let counter = Arc::new(AtomicI32::new(0));
    let iterations = 1000;

    let handles: Vec<_> = (0..2)
        .map(|_| {
            let lock = Arc::clone(&lock);
            let counter = Arc::clone(&counter);
            thread::spawn(move || {
                for _ in 0..iterations {
                    lock.lock();
                    counter.fetch_add(1, Ordering::Relaxed);
                    lock.unlock();
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    assert_eq!(counter.load(Ordering::Relaxed), iterations * 2);
}

// Port of SpinLockTest.MutualExclusion
#[test]
fn mutual_exclusion() {
    let lock = Arc::new(SpinLock::new());
    let t1_in_cs = Arc::new(AtomicBool::new(false));
    let t2_in_cs = Arc::new(AtomicBool::new(false));
    let violation = Arc::new(AtomicBool::new(false));

    let make_task = |my_flag: Arc<AtomicBool>,
                     other_flag: Arc<AtomicBool>,
                     viol: Arc<AtomicBool>,
                     lk: Arc<SpinLock>| {
        thread::spawn(move || {
            for _ in 0..100 {
                lk.lock();
                my_flag.store(true, Ordering::SeqCst);
                if other_flag.load(Ordering::SeqCst) {
                    viol.store(true, Ordering::SeqCst);
                }
                thread::sleep(Duration::from_micros(10));
                my_flag.store(false, Ordering::SeqCst);
                lk.unlock();
                thread::yield_now();
            }
        })
    };

    let t1 = make_task(
        Arc::clone(&t1_in_cs),
        Arc::clone(&t2_in_cs),
        Arc::clone(&violation),
        Arc::clone(&lock),
    );
    let t2 = make_task(
        Arc::clone(&t2_in_cs),
        Arc::clone(&t1_in_cs),
        Arc::clone(&violation),
        Arc::clone(&lock),
    );

    t1.join().unwrap();
    t2.join().unwrap();

    assert!(!violation.load(Ordering::SeqCst));
}

// Port of SpinLockTest.ConcurrentAccess
#[test]
fn concurrent_access() {
    let lock = Arc::new(SpinLock::new());
    let shared_data = Arc::new(AtomicI32::new(0));
    let num_threads = 4;
    let ops_per_thread = 100;

    let handles: Vec<_> = (0..num_threads)
        .map(|_| {
            let lock = Arc::clone(&lock);
            let data = Arc::clone(&shared_data);
            thread::spawn(move || {
                for _ in 0..ops_per_thread {
                    lock.lock();
                    let temp = data.load(Ordering::Relaxed);
                    thread::yield_now();
                    data.store(temp + 1, Ordering::Relaxed);
                    lock.unlock();
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    assert_eq!(shared_data.load(Ordering::Relaxed), num_threads * ops_per_thread);
}

// Port of SpinLockTest.RapidLockUnlock
#[test]
fn rapid_lock_unlock() {
    let lock = Arc::new(SpinLock::new());

    let handles: Vec<_> = (0..2)
        .map(|_| {
            let lock = Arc::clone(&lock);
            thread::spawn(move || {
                for _ in 0..10000 {
                    lock.lock();
                    lock.unlock();
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }
}

// Port of SpinLockTest.Contention
#[test]
fn contention() {
    let lock = Arc::new(SpinLock::new());
    let work_done = Arc::new(AtomicI32::new(0));
    let num_threads = 8;

    let handles: Vec<_> = (0..num_threads)
        .map(|_| {
            let lock = Arc::clone(&lock);
            let wd = Arc::clone(&work_done);
            thread::spawn(move || {
                for _ in 0..50 {
                    lock.lock();
                    wd.fetch_add(1, Ordering::Relaxed);
                    thread::sleep(Duration::from_micros(100));
                    lock.unlock();
                    thread::yield_now();
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    assert_eq!(work_done.load(Ordering::Relaxed), num_threads * 50);
}
