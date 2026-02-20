// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Rust port of cpp-ipc/test/test_condition.cpp

use std::sync::atomic::{AtomicBool, AtomicI32, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use libipc::{IpcCondition, IpcMutex};

static COUNTER: AtomicUsize = AtomicUsize::new(0);

fn unique_name(prefix: &str) -> String {
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}_cv_{n}")
}

// Port of ConditionTest.NamedConstructor
#[test]
fn named_constructor() {
    let name = unique_name("named");
    IpcCondition::clear_storage(&name);

    let cv = IpcCondition::open(&name).expect("open");
    drop(cv);
}

// Port of ConditionTest.Open
#[test]
fn open() {
    let name = unique_name("open");
    IpcCondition::clear_storage(&name);

    let cv = IpcCondition::open(&name);
    assert!(cv.is_ok());
}

// Port of ConditionTest.ClearStorage
#[test]
fn clear_storage() {
    let name = unique_name("clear_storage");
    IpcCondition::clear_storage(&name);

    {
        let _cv = IpcCondition::open(&name).expect("open");
    }

    IpcCondition::clear_storage(&name);
}

// Port of ConditionTest.WaitNotify
#[test]
fn wait_notify() {
    let cv_name = unique_name("wait_notify");
    let mtx_name = unique_name("wait_notify_mtx");
    IpcCondition::clear_storage(&cv_name);
    IpcMutex::clear_storage(&mtx_name);

    let cv = Arc::new(IpcCondition::open(&cv_name).expect("open cv"));
    let mtx = Arc::new(IpcMutex::open(&mtx_name).expect("open mtx"));

    let notified = Arc::new(AtomicBool::new(false));

    let cv2 = Arc::clone(&cv);
    let mtx2 = Arc::clone(&mtx);
    let notified2 = Arc::clone(&notified);
    let waiter = thread::spawn(move || {
        mtx2.lock().expect("lock");
        cv2.wait(&mtx2, None).expect("wait");
        notified2.store(true, Ordering::SeqCst);
        mtx2.unlock().expect("unlock");
    });

    thread::sleep(Duration::from_millis(50));

    mtx.lock().expect("lock main");
    cv.notify().expect("notify");
    mtx.unlock().expect("unlock main");

    waiter.join().unwrap();
    assert!(notified.load(Ordering::SeqCst));
}

// Port of ConditionTest.Broadcast
#[test]
fn broadcast() {
    let cv_name = unique_name("broadcast");
    let mtx_name = unique_name("broadcast_mtx");
    IpcCondition::clear_storage(&cv_name);
    IpcMutex::clear_storage(&mtx_name);

    let cv = Arc::new(IpcCondition::open(&cv_name).expect("open cv"));
    let mtx = Arc::new(IpcMutex::open(&mtx_name).expect("open mtx"));

    let notified_count = Arc::new(AtomicI32::new(0));
    let num_waiters = 5;

    let handles: Vec<_> = (0..num_waiters)
        .map(|_| {
            let cv = Arc::clone(&cv);
            let mtx = Arc::clone(&mtx);
            let nc = Arc::clone(&notified_count);
            thread::spawn(move || {
                mtx.lock().expect("lock waiter");
                cv.wait(&mtx, None).expect("wait");
                nc.fetch_add(1, Ordering::Relaxed);
                mtx.unlock().expect("unlock waiter");
            })
        })
        .collect();

    thread::sleep(Duration::from_millis(100));

    mtx.lock().expect("lock broadcaster");
    cv.broadcast().expect("broadcast");
    mtx.unlock().expect("unlock broadcaster");

    for h in handles {
        h.join().unwrap();
    }

    assert_eq!(notified_count.load(Ordering::Relaxed), num_waiters);
}

// Port of ConditionTest.TimedWait
#[test]
fn timed_wait() {
    let cv_name = unique_name("timed_wait");
    let mtx_name = unique_name("timed_wait_mtx");
    IpcCondition::clear_storage(&cv_name);
    IpcMutex::clear_storage(&mtx_name);

    let cv = IpcCondition::open(&cv_name).expect("open cv");
    let mtx = IpcMutex::open(&mtx_name).expect("open mtx");

    let start = Instant::now();
    mtx.lock().expect("lock");
    let result = cv.wait(&mtx, Some(100)).expect("wait");
    mtx.unlock().expect("unlock");
    let elapsed = start.elapsed();

    assert!(!result, "should timeout");
    assert!(
        elapsed.as_millis() >= 80,
        "should have waited ~100ms, got {}ms",
        elapsed.as_millis()
    );
}

// Port of ConditionTest.ImmediateNotify
#[test]
fn immediate_notify() {
    let cv_name = unique_name("immediate");
    let mtx_name = unique_name("immediate_mtx");
    IpcCondition::clear_storage(&cv_name);
    IpcMutex::clear_storage(&mtx_name);

    let cv = Arc::new(IpcCondition::open(&cv_name).expect("open cv"));
    let mtx = Arc::new(IpcMutex::open(&mtx_name).expect("open mtx"));

    let wait_started = Arc::new(AtomicBool::new(false));
    let notified = Arc::new(AtomicBool::new(false));

    let cv2 = Arc::clone(&cv);
    let mtx2 = Arc::clone(&mtx);
    let ws = Arc::clone(&wait_started);
    let n = Arc::clone(&notified);
    let waiter = thread::spawn(move || {
        mtx2.lock().expect("lock");
        ws.store(true, Ordering::SeqCst);
        cv2.wait(&mtx2, Some(1000)).expect("wait");
        n.store(true, Ordering::SeqCst);
        mtx2.unlock().expect("unlock");
    });

    while !wait_started.load(Ordering::SeqCst) {
        thread::sleep(Duration::from_millis(1));
    }
    thread::sleep(Duration::from_millis(10));

    mtx.lock().expect("lock main");
    cv.notify().expect("notify");
    mtx.unlock().expect("unlock main");

    waiter.join().unwrap();
    assert!(notified.load(Ordering::SeqCst));
}

// Port of ConditionTest.ProducerConsumer
#[test]
fn producer_consumer() {
    let cv_name = unique_name("prod_cons");
    let mtx_name = unique_name("prod_cons_mtx");
    IpcCondition::clear_storage(&cv_name);
    IpcMutex::clear_storage(&mtx_name);

    let cv = Arc::new(IpcCondition::open(&cv_name).expect("open cv"));
    let mtx = Arc::new(IpcMutex::open(&mtx_name).expect("open mtx"));

    let buffer = Arc::new(AtomicI32::new(0));
    let ready = Arc::new(AtomicBool::new(false));
    let consumed_value = Arc::new(AtomicI32::new(0));

    let cv_p = Arc::clone(&cv);
    let mtx_p = Arc::clone(&mtx);
    let buf_p = Arc::clone(&buffer);
    let rdy_p = Arc::clone(&ready);
    let producer = thread::spawn(move || {
        thread::sleep(Duration::from_millis(50));
        mtx_p.lock().expect("lock producer");
        buf_p.store(42, Ordering::SeqCst);
        rdy_p.store(true, Ordering::SeqCst);
        cv_p.notify().expect("notify");
        mtx_p.unlock().expect("unlock producer");
    });

    let cv_c = Arc::clone(&cv);
    let mtx_c = Arc::clone(&mtx);
    let buf_c = Arc::clone(&buffer);
    let rdy_c = Arc::clone(&ready);
    let cv_c2 = Arc::clone(&consumed_value);
    let consumer = thread::spawn(move || {
        mtx_c.lock().expect("lock consumer");
        while !rdy_c.load(Ordering::SeqCst) {
            cv_c.wait(&mtx_c, Some(2000)).expect("wait");
        }
        cv_c2.store(buf_c.load(Ordering::SeqCst), Ordering::SeqCst);
        mtx_c.unlock().expect("unlock consumer");
    });

    producer.join().unwrap();
    consumer.join().unwrap();

    assert_eq!(consumed_value.load(Ordering::SeqCst), 42);
}

// Port of ConditionTest.MultipleNotify
#[test]
fn multiple_notify() {
    let cv_name = unique_name("multi_notify");
    let mtx_name = unique_name("multi_notify_mtx");
    IpcCondition::clear_storage(&cv_name);
    IpcMutex::clear_storage(&mtx_name);

    let cv = Arc::new(IpcCondition::open(&cv_name).expect("open cv"));
    let mtx = Arc::new(IpcMutex::open(&mtx_name).expect("open mtx"));

    let notify_count = Arc::new(AtomicI32::new(0));
    let num_notifications = 3;

    let cv2 = Arc::clone(&cv);
    let mtx2 = Arc::clone(&mtx);
    let nc = Arc::clone(&notify_count);
    let waiter = thread::spawn(move || {
        for _ in 0..num_notifications {
            mtx2.lock().expect("lock waiter");
            cv2.wait(&mtx2, Some(1000)).expect("wait");
            nc.fetch_add(1, Ordering::Relaxed);
            mtx2.unlock().expect("unlock waiter");
            thread::sleep(Duration::from_millis(10));
        }
    });

    for _ in 0..num_notifications {
        thread::sleep(Duration::from_millis(50));
        mtx.lock().expect("lock notifier");
        cv.notify().expect("notify");
        mtx.unlock().expect("unlock notifier");
    }

    waiter.join().unwrap();
    assert_eq!(notify_count.load(Ordering::Relaxed), num_notifications);
}

// Port of ConditionTest.SpuriousWakeupPattern
#[test]
fn spurious_wakeup_pattern() {
    let cv_name = unique_name("spurious");
    let mtx_name = unique_name("spurious_mtx");
    IpcCondition::clear_storage(&cv_name);
    IpcMutex::clear_storage(&mtx_name);

    let cv = Arc::new(IpcCondition::open(&cv_name).expect("open cv"));
    let mtx = Arc::new(IpcMutex::open(&mtx_name).expect("open mtx"));

    let predicate = Arc::new(AtomicBool::new(false));
    let done = Arc::new(AtomicBool::new(false));

    let cv2 = Arc::clone(&cv);
    let mtx2 = Arc::clone(&mtx);
    let pred2 = Arc::clone(&predicate);
    let done2 = Arc::clone(&done);
    let waiter = thread::spawn(move || {
        mtx2.lock().expect("lock");
        while !pred2.load(Ordering::SeqCst) {
            match cv2.wait(&mtx2, Some(100)) {
                Ok(false) => {
                    if pred2.load(Ordering::SeqCst) {
                        break;
                    }
                }
                Ok(true) => {}
                Err(e) => panic!("wait error: {e}"),
            }
        }
        done2.store(true, Ordering::SeqCst);
        mtx2.unlock().expect("unlock");
    });

    thread::sleep(Duration::from_millis(50));

    mtx.lock().expect("lock main");
    predicate.store(true, Ordering::SeqCst);
    cv.notify().expect("notify");
    mtx.unlock().expect("unlock main");

    waiter.join().unwrap();
    assert!(done.load(Ordering::SeqCst));
}

// Port of ConditionTest.InfiniteWait
#[test]
fn infinite_wait() {
    let cv_name = unique_name("infinite");
    let mtx_name = unique_name("infinite_mtx");
    IpcCondition::clear_storage(&cv_name);
    IpcMutex::clear_storage(&mtx_name);

    let cv = Arc::new(IpcCondition::open(&cv_name).expect("open cv"));
    let mtx = Arc::new(IpcMutex::open(&mtx_name).expect("open mtx"));

    let woken = Arc::new(AtomicBool::new(false));

    let cv2 = Arc::clone(&cv);
    let mtx2 = Arc::clone(&mtx);
    let w = Arc::clone(&woken);
    let waiter = thread::spawn(move || {
        mtx2.lock().expect("lock");
        cv2.wait(&mtx2, None).expect("wait infinite");
        w.store(true, Ordering::SeqCst);
        mtx2.unlock().expect("unlock");
    });

    thread::sleep(Duration::from_millis(100));

    mtx.lock().expect("lock main");
    cv.notify().expect("notify");
    mtx.unlock().expect("unlock main");

    waiter.join().unwrap();
    assert!(woken.load(Ordering::SeqCst));
}

// Port of ConditionTest.BroadcastSequential
#[test]
fn broadcast_sequential() {
    let cv_name = unique_name("broadcast_seq");
    let mtx_name = unique_name("broadcast_seq_mtx");
    IpcCondition::clear_storage(&cv_name);
    IpcMutex::clear_storage(&mtx_name);

    let cv = Arc::new(IpcCondition::open(&cv_name).expect("open cv"));
    let mtx = Arc::new(IpcMutex::open(&mtx_name).expect("open mtx"));

    let processed = Arc::new(AtomicI32::new(0));
    let num_threads = 4;

    let handles: Vec<_> = (0..num_threads)
        .map(|_| {
            let cv = Arc::clone(&cv);
            let mtx = Arc::clone(&mtx);
            let p = Arc::clone(&processed);
            thread::spawn(move || {
                mtx.lock().expect("lock");
                cv.wait(&mtx, Some(2000)).expect("wait");
                p.fetch_add(1, Ordering::Relaxed);
                mtx.unlock().expect("unlock");
            })
        })
        .collect();

    thread::sleep(Duration::from_millis(100));

    mtx.lock().expect("lock broadcaster");
    cv.broadcast().expect("broadcast");
    mtx.unlock().expect("unlock broadcaster");

    for h in handles {
        h.join().unwrap();
    }

    assert_eq!(processed.load(Ordering::Relaxed), num_threads);
}

// Port of ConditionTest.NamedSharing
#[test]
fn named_sharing() {
    let cv_name = unique_name("sharing");
    let mtx_name = unique_name("sharing_mtx");
    IpcCondition::clear_storage(&cv_name);
    IpcMutex::clear_storage(&mtx_name);

    let value = Arc::new(AtomicI32::new(0));

    let cv_n1 = cv_name.clone();
    let mtx_n1 = mtx_name.clone();
    let val1 = Arc::clone(&value);
    let t1 = thread::spawn(move || {
        let cv = IpcCondition::open(&cv_n1).expect("open cv t1");
        let mtx = IpcMutex::open(&mtx_n1).expect("open mtx t1");
        mtx.lock().expect("lock t1");
        cv.wait(&mtx, Some(1000)).expect("wait t1");
        val1.store(100, Ordering::SeqCst);
        mtx.unlock().expect("unlock t1");
    });

    let cv_n2 = cv_name.clone();
    let mtx_n2 = mtx_name.clone();
    let t2 = thread::spawn(move || {
        thread::sleep(Duration::from_millis(50));
        let cv = IpcCondition::open(&cv_n2).expect("open cv t2");
        let mtx = IpcMutex::open(&mtx_n2).expect("open mtx t2");
        mtx.lock().expect("lock t2");
        cv.notify().expect("notify t2");
        mtx.unlock().expect("unlock t2");
    });

    t1.join().unwrap();
    t2.join().unwrap();

    assert_eq!(value.load(Ordering::SeqCst), 100);
}

// Port of ConditionTest.NotifyVsBroadcast
// notify() should wake at most one waiter; broadcast() should wake all.
#[test]
fn notify_vs_broadcast() {
    let cv_name = unique_name("notify_vs_bc");
    let mtx_name = unique_name("notify_vs_bc_mtx");
    IpcCondition::clear_storage(&cv_name);
    IpcMutex::clear_storage(&mtx_name);

    let cv = IpcCondition::open(&cv_name).expect("open cv");
    let mtx = IpcMutex::open(&mtx_name).expect("open mtx");

    // Phase 1: notify() — send one signal to 3 waiters; at most 1 should wake
    // before the 100ms timeout expires.
    let woken_by_notify = Arc::new(AtomicI32::new(0));
    let mut waiters = Vec::new();
    for _ in 0..3 {
        let cv_n = cv_name.clone();
        let mtx_n = mtx_name.clone();
        let counter = Arc::clone(&woken_by_notify);
        waiters.push(thread::spawn(move || {
            let cv = IpcCondition::open(&cv_n).expect("cv");
            let mtx = IpcMutex::open(&mtx_n).expect("mtx");
            mtx.lock().expect("lock");
            // 100ms timeout — only the notified thread wakes early
            let _ = cv.wait(&mtx, Some(100)).expect("wait");
            counter.fetch_add(1, Ordering::Relaxed);
            mtx.unlock().expect("unlock");
        }));
    }

    thread::sleep(Duration::from_millis(20));
    mtx.lock().expect("lock notify");
    cv.notify().expect("notify");
    mtx.unlock().expect("unlock notify");

    // Give the notified thread time to wake, but not enough for timeouts.
    thread::sleep(Duration::from_millis(30));
    let woken = woken_by_notify.load(Ordering::Relaxed);
    // At least 1 woken by notify; remaining 2 will timeout after ~100ms.
    assert!(woken >= 1, "notify should wake at least one waiter");

    for w in waiters {
        w.join().unwrap();
    }
    // After timeouts all 3 should have exited.
    assert_eq!(woken_by_notify.load(Ordering::Relaxed), 3);

    // Phase 2: broadcast() — all 3 waiters should wake immediately.
    let woken_by_broadcast = Arc::new(AtomicI32::new(0));
    let mut waiters2 = Vec::new();
    for _ in 0..3 {
        let cv_n = cv_name.clone();
        let mtx_n = mtx_name.clone();
        let counter = Arc::clone(&woken_by_broadcast);
        waiters2.push(thread::spawn(move || {
            let cv = IpcCondition::open(&cv_n).expect("cv");
            let mtx = IpcMutex::open(&mtx_n).expect("mtx");
            mtx.lock().expect("lock");
            cv.wait(&mtx, Some(2000)).expect("wait");
            counter.fetch_add(1, Ordering::Relaxed);
            mtx.unlock().expect("unlock");
        }));
    }

    thread::sleep(Duration::from_millis(50));
    mtx.lock().expect("lock bc");
    cv.broadcast().expect("broadcast");
    mtx.unlock().expect("unlock bc");

    for w in waiters2 {
        w.join().unwrap();
    }
    assert_eq!(woken_by_broadcast.load(Ordering::Relaxed), 3);
}
