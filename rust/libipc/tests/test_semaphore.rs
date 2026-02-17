// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Rust port of cpp-ipc/test/test_semaphore.cpp

use std::sync::atomic::{AtomicBool, AtomicI32, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use libipc::IpcSemaphore;

static COUNTER: AtomicUsize = AtomicUsize::new(0);

fn unique_name(prefix: &str) -> String {
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}_sem_{n}")
}

// Port of SemaphoreTest.NamedConstructorWithCount
#[test]
fn named_constructor_with_count() {
    let name = unique_name("named_count");
    IpcSemaphore::clear_storage(&name);

    let sem = IpcSemaphore::open(&name, 5).expect("open");
    drop(sem);
}

// Port of SemaphoreTest.NamedConstructorZeroCount
#[test]
fn named_constructor_zero_count() {
    let name = unique_name("zero_count");
    IpcSemaphore::clear_storage(&name);

    let sem = IpcSemaphore::open(&name, 0).expect("open");
    drop(sem);
}

// Port of SemaphoreTest.Open
#[test]
fn open() {
    let name = unique_name("open");
    IpcSemaphore::clear_storage(&name);

    let sem = IpcSemaphore::open(&name, 3);
    assert!(sem.is_ok());
}

// Port of SemaphoreTest.ClearStorage
#[test]
fn clear_storage() {
    let name = unique_name("clear_storage");
    IpcSemaphore::clear_storage(&name);

    {
        let _sem = IpcSemaphore::open(&name, 1).expect("open");
    }

    IpcSemaphore::clear_storage(&name);
}

// Port of SemaphoreTest.WaitPost
#[test]
fn wait_post() {
    let name = unique_name("wait_post");
    IpcSemaphore::clear_storage(&name);

    let sem = IpcSemaphore::open(&name, 1).expect("open");

    let waited = sem.wait(None).expect("wait");
    assert!(waited);

    sem.post(1).expect("post");
}

// Port of SemaphoreTest.PostWithCount
#[test]
fn post_with_count() {
    let name = unique_name("post_count");
    IpcSemaphore::clear_storage(&name);

    let sem = IpcSemaphore::open(&name, 0).expect("open");
    sem.post(5).expect("post 5");

    for _ in 0..5 {
        assert!(sem.wait(Some(10)).expect("wait"));
    }
}

// Port of SemaphoreTest.TimedWait
#[test]
fn timed_wait() {
    let name = unique_name("timed_wait");
    IpcSemaphore::clear_storage(&name);

    let sem = IpcSemaphore::open(&name, 1).expect("open");
    let waited = sem.wait(Some(100)).expect("wait");
    assert!(waited);
}

// Port of SemaphoreTest.WaitTimeout
#[test]
fn wait_timeout() {
    let name = unique_name("wait_timeout");
    IpcSemaphore::clear_storage(&name);

    let sem = IpcSemaphore::open(&name, 0).expect("open");

    let start = Instant::now();
    let waited = sem.wait(Some(50)).expect("wait");
    let elapsed = start.elapsed();

    assert!(!waited, "should timeout");
    assert!(elapsed.as_millis() >= 40, "should have waited ~50ms, got {}ms", elapsed.as_millis());
}

// Port of SemaphoreTest.InfiniteWait
#[test]
fn infinite_wait() {
    let name = unique_name("infinite_wait");
    IpcSemaphore::clear_storage(&name);

    let sem = Arc::new(IpcSemaphore::open(&name, 0).expect("open"));
    let wait_started = Arc::new(AtomicBool::new(false));
    let wait_succeeded = Arc::new(AtomicBool::new(false));

    let sem2 = Arc::clone(&sem);
    let ws = Arc::clone(&wait_started);
    let wsucc = Arc::clone(&wait_succeeded);
    let waiter = thread::spawn(move || {
        ws.store(true, Ordering::SeqCst);
        let result = sem2.wait(None).expect("wait");
        wsucc.store(result, Ordering::SeqCst);
    });

    while !wait_started.load(Ordering::SeqCst) {
        thread::sleep(Duration::from_millis(1));
    }
    thread::sleep(Duration::from_millis(50));

    sem.post(1).expect("post");

    waiter.join().unwrap();
    assert!(wait_succeeded.load(Ordering::SeqCst));
}

// Port of SemaphoreTest.ProducerConsumer
#[test]
fn producer_consumer() {
    let name = unique_name("prod_cons");
    IpcSemaphore::clear_storage(&name);

    let sem = Arc::new(IpcSemaphore::open(&name, 0).expect("open"));
    let produced = Arc::new(AtomicI32::new(0));
    let consumed = Arc::new(AtomicI32::new(0));
    let count = 10;

    let sem_p = Arc::clone(&sem);
    let prod = Arc::clone(&produced);
    let producer = thread::spawn(move || {
        for _ in 0..count {
            prod.fetch_add(1, Ordering::Relaxed);
            sem_p.post(1).expect("post");
            thread::sleep(Duration::from_millis(1));
        }
    });

    let sem_c = Arc::clone(&sem);
    let cons = Arc::clone(&consumed);
    let consumer = thread::spawn(move || {
        for _ in 0..count {
            sem_c.wait(None).expect("wait");
            cons.fetch_add(1, Ordering::Relaxed);
        }
    });

    producer.join().unwrap();
    consumer.join().unwrap();

    assert_eq!(produced.load(Ordering::Relaxed), count);
    assert_eq!(consumed.load(Ordering::Relaxed), count);
}

// Port of SemaphoreTest.MultipleProducersConsumers
#[test]
fn multiple_producers_consumers() {
    let name = unique_name("multi_prod_cons");
    IpcSemaphore::clear_storage(&name);

    let sem = Arc::new(IpcSemaphore::open(&name, 0).expect("open"));
    let total_produced = Arc::new(AtomicI32::new(0));
    let total_consumed = Arc::new(AtomicI32::new(0));
    let items_per = 5;
    let num_producers = 3;
    let num_consumers = 3;

    let mut handles = Vec::new();

    for _ in 0..num_producers {
        let sem = Arc::clone(&sem);
        let tp = Arc::clone(&total_produced);
        handles.push(thread::spawn(move || {
            for _ in 0..items_per {
                tp.fetch_add(1, Ordering::Relaxed);
                sem.post(1).expect("post");
                thread::yield_now();
            }
        }));
    }

    for _ in 0..num_consumers {
        let sem = Arc::clone(&sem);
        let tc = Arc::clone(&total_consumed);
        handles.push(thread::spawn(move || {
            for _ in 0..items_per {
                if sem.wait(Some(1000)).expect("wait") {
                    tc.fetch_add(1, Ordering::Relaxed);
                }
            }
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    assert_eq!(total_produced.load(Ordering::Relaxed), items_per * num_producers);
    assert_eq!(total_consumed.load(Ordering::Relaxed), items_per * num_producers);
}

// Port of SemaphoreTest.InitialCount
#[test]
fn initial_count() {
    let name = unique_name("initial_count");
    IpcSemaphore::clear_storage(&name);

    let initial = 3u32;
    let sem = IpcSemaphore::open(&name, initial).expect("open");

    for _ in 0..initial {
        assert!(sem.wait(Some(10)).expect("wait"));
    }

    // Next wait should timeout
    assert!(!sem.wait(Some(10)).expect("wait timeout"));
}

// Port of SemaphoreTest.RapidPost
#[test]
fn rapid_post() {
    let name = unique_name("rapid_post");
    IpcSemaphore::clear_storage(&name);

    let sem = IpcSemaphore::open(&name, 0).expect("open");
    let post_count = 100;

    for _ in 0..post_count {
        sem.post(1).expect("post");
    }

    let mut wait_count = 0;
    for _ in 0..post_count {
        if sem.wait(Some(10)).expect("wait") {
            wait_count += 1;
        }
    }

    assert_eq!(wait_count, post_count);
}

// Port of SemaphoreTest.ConcurrentPost
#[test]
fn concurrent_post() {
    let name = unique_name("concurrent_post");
    IpcSemaphore::clear_storage(&name);

    let sem = Arc::new(IpcSemaphore::open(&name, 0).expect("open"));
    let post_count = Arc::new(AtomicI32::new(0));
    let threads = 5;
    let posts_per_thread = 10;

    let handles: Vec<_> = (0..threads)
        .map(|_| {
            let sem = Arc::clone(&sem);
            let pc = Arc::clone(&post_count);
            thread::spawn(move || {
                for _ in 0..posts_per_thread {
                    sem.post(1).expect("post");
                    pc.fetch_add(1, Ordering::Relaxed);
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    assert_eq!(post_count.load(Ordering::Relaxed), threads * posts_per_thread);

    // Verify by consuming
    let mut consumed = 0;
    for _ in 0..(threads * posts_per_thread) {
        if sem.wait(Some(10)).expect("wait") {
            consumed += 1;
        }
    }
    assert_eq!(consumed, threads * posts_per_thread);
}

// Port of SemaphoreTest.NamedSemaphoreSharing
#[test]
fn named_semaphore_sharing() {
    let name = unique_name("sharing");
    IpcSemaphore::clear_storage(&name);

    let value = Arc::new(AtomicI32::new(0));

    let name1 = name.clone();
    let val1 = Arc::clone(&value);
    let t1 = thread::spawn(move || {
        let sem = IpcSemaphore::open(&name1, 0).expect("open t1");
        sem.wait(None).expect("wait");
        val1.store(100, Ordering::SeqCst);
    });

    let name2 = name.clone();
    let t2 = thread::spawn(move || {
        thread::sleep(Duration::from_millis(50));
        let sem = IpcSemaphore::open(&name2, 0).expect("open t2");
        sem.post(1).expect("post");
    });

    t1.join().unwrap();
    t2.join().unwrap();

    assert_eq!(value.load(Ordering::SeqCst), 100);
}

// Port of SemaphoreTest.PostMultiple
#[test]
fn post_multiple() {
    let name = unique_name("post_multiple");
    IpcSemaphore::clear_storage(&name);

    let sem = IpcSemaphore::open(&name, 0).expect("open");
    let count = 10u32;

    sem.post(count).expect("post multiple");

    for _ in 0..count {
        assert!(sem.wait(Some(10)).expect("wait"));
    }

    // Should be empty
    assert!(!sem.wait(Some(10)).expect("wait empty"));
}

// Port of SemaphoreTest.ZeroTimeout
#[test]
fn zero_timeout() {
    let name = unique_name("zero_timeout");
    IpcSemaphore::clear_storage(&name);

    let sem = IpcSemaphore::open(&name, 0).expect("open");
    let _ = sem.wait(Some(0)).expect("wait zero timeout");
    // Just ensure it doesn't hang
}

// Port of SemaphoreTest.HighFrequency
#[test]
fn high_frequency() {
    let name = unique_name("high_freq");
    IpcSemaphore::clear_storage(&name);

    let sem = Arc::new(IpcSemaphore::open(&name, 0).expect("open"));

    let sem_p = Arc::clone(&sem);
    let poster = thread::spawn(move || {
        for _ in 0..1000 {
            sem_p.post(1).expect("post");
        }
    });

    let sem_w = Arc::clone(&sem);
    let waiter = thread::spawn(move || {
        for _ in 0..1000 {
            sem_w.wait(Some(100)).expect("wait");
        }
    });

    poster.join().unwrap();
    waiter.join().unwrap();
}
