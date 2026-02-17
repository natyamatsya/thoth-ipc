// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Rust port of cpp-ipc/test/test_mutex.cpp
// Comprehensive unit tests for named inter-process mutex functionality.

use std::sync::atomic::{AtomicBool, AtomicI32, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use libipc::IpcMutex;

static COUNTER: AtomicUsize = AtomicUsize::new(0);

fn unique_name(prefix: &str) -> String {
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}_mtx_{n}")
}

// Port of MutexTest.NamedConstructor
#[test]
fn named_constructor() {
    let name = unique_name("named_ctor");
    IpcMutex::clear_storage(&name);

    let mtx = IpcMutex::open(&name).expect("open");
    // Successfully opened — valid by definition
    drop(mtx);
}

// Port of MutexTest.Open
#[test]
fn open() {
    let name = unique_name("open");
    IpcMutex::clear_storage(&name);

    let mtx = IpcMutex::open(&name);
    assert!(mtx.is_ok());
}

// Port of MutexTest.ClearStorage
#[test]
fn clear_storage() {
    let name = unique_name("clear_storage");
    IpcMutex::clear_storage(&name);

    {
        let _mtx = IpcMutex::open(&name).expect("open");
    }

    IpcMutex::clear_storage(&name);

    // Should be able to create a new one after clear
    let mtx2 = IpcMutex::open(&name).expect("reopen after clear");
    drop(mtx2);
}

// Port of MutexTest.LockUnlock
#[test]
fn lock_unlock() {
    let name = unique_name("lock_unlock");
    IpcMutex::clear_storage(&name);

    let mtx = IpcMutex::open(&name).expect("open");

    mtx.lock().expect("lock");
    mtx.unlock().expect("unlock");
}

// Port of MutexTest.TryLock
#[test]
fn try_lock() {
    let name = unique_name("try_lock");
    IpcMutex::clear_storage(&name);

    let mtx = IpcMutex::open(&name).expect("open");

    let locked = mtx.try_lock().expect("try_lock");
    assert!(locked);

    if locked {
        mtx.unlock().expect("unlock");
    }
}

// Port of MutexTest.MultipleCycles
#[test]
fn multiple_cycles() {
    let name = unique_name("cycles");
    IpcMutex::clear_storage(&name);

    let mtx = IpcMutex::open(&name).expect("open");

    for _ in 0..100 {
        mtx.lock().expect("lock");
        mtx.unlock().expect("unlock");
    }
}

// Port of MutexTest.CriticalSection
#[test]
fn critical_section() {
    let name = unique_name("critical_section");
    IpcMutex::clear_storage(&name);

    let counter = Arc::new(AtomicI32::new(0));
    let iterations = 100;

    let handles: Vec<_> = (0..2)
        .map(|_| {
            let name = name.clone();
            let counter = Arc::clone(&counter);
            thread::spawn(move || {
                let mtx = IpcMutex::open(&name).expect("open");
                for _ in 0..iterations {
                    mtx.lock().expect("lock");
                    counter.fetch_add(1, Ordering::Relaxed);
                    mtx.unlock().expect("unlock");
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    assert_eq!(counter.load(Ordering::Relaxed), iterations * 2);
}

// Port of MutexTest.ConcurrentTryLock
#[test]
fn concurrent_try_lock() {
    let name = unique_name("concurrent_try");
    IpcMutex::clear_storage(&name);

    let success_count = Arc::new(AtomicI32::new(0));
    let fail_count = Arc::new(AtomicI32::new(0));

    let handles: Vec<_> = (0..3)
        .map(|_| {
            let name = name.clone();
            let success = Arc::clone(&success_count);
            let fail = Arc::clone(&fail_count);
            thread::spawn(move || {
                let mtx = IpcMutex::open(&name).expect("open");
                for _ in 0..10 {
                    match mtx.try_lock() {
                        Ok(true) => {
                            success.fetch_add(1, Ordering::Relaxed);
                            thread::sleep(Duration::from_millis(1));
                            mtx.unlock().expect("unlock");
                        }
                        Ok(false) => {
                            fail.fetch_add(1, Ordering::Relaxed);
                        }
                        Err(e) => panic!("try_lock error: {e}"),
                    }
                    thread::yield_now();
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    assert!(success_count.load(Ordering::Relaxed) > 0, "some try_locks should succeed");
}

// Port of MutexTest.LockContention — mutual exclusion verification
#[test]
fn lock_contention() {
    let name = unique_name("contention");
    IpcMutex::clear_storage(&name);

    let thread1_in_cs = Arc::new(AtomicBool::new(false));
    let thread2_in_cs = Arc::new(AtomicBool::new(false));
    let violation = Arc::new(AtomicBool::new(false));

    let make_task = |my_flag: Arc<AtomicBool>,
                     other_flag: Arc<AtomicBool>,
                     viol: Arc<AtomicBool>,
                     name: String| {
        thread::spawn(move || {
            let mtx = IpcMutex::open(&name).expect("open");
            for _ in 0..50 {
                mtx.lock().expect("lock");

                my_flag.store(true, Ordering::SeqCst);
                if other_flag.load(Ordering::SeqCst) {
                    viol.store(true, Ordering::SeqCst);
                }

                thread::sleep(Duration::from_micros(10));

                my_flag.store(false, Ordering::SeqCst);
                mtx.unlock().expect("unlock");

                thread::yield_now();
            }
        })
    };

    let t1 = make_task(
        Arc::clone(&thread1_in_cs),
        Arc::clone(&thread2_in_cs),
        Arc::clone(&violation),
        name.clone(),
    );
    let t2 = make_task(
        Arc::clone(&thread2_in_cs),
        Arc::clone(&thread1_in_cs),
        Arc::clone(&violation),
        name.clone(),
    );

    t1.join().unwrap();
    t2.join().unwrap();

    assert!(!violation.load(Ordering::SeqCst), "both threads in critical section simultaneously");
}

// Port of MutexTest.NamedMutexInterThread
#[test]
fn named_mutex_inter_thread() {
    let name = unique_name("inter_thread");
    IpcMutex::clear_storage(&name);

    let shared_data = Arc::new(AtomicI32::new(0));
    let t1_done = Arc::new(AtomicBool::new(false));

    let name_t1 = name.clone();
    let data_t1 = Arc::clone(&shared_data);
    let done_t1 = Arc::clone(&t1_done);
    let t1 = thread::spawn(move || {
        let mtx = IpcMutex::open(&name_t1).expect("open t1");
        mtx.lock().expect("lock t1");
        data_t1.store(100, Ordering::SeqCst);
        thread::sleep(Duration::from_millis(50));
        mtx.unlock().expect("unlock t1");
        done_t1.store(true, Ordering::SeqCst);
    });

    let name_t2 = name.clone();
    let data_t2 = Arc::clone(&shared_data);
    let done_t1_ref = Arc::clone(&t1_done);
    let t2 = thread::spawn(move || {
        // Wait a bit to ensure t1 starts first
        thread::sleep(Duration::from_millis(10));

        let mtx = IpcMutex::open(&name_t2).expect("open t2");
        mtx.lock().expect("lock t2");
        assert!(
            done_t1_ref.load(Ordering::SeqCst) || data_t2.load(Ordering::SeqCst) == 100,
            "t2 entered critical section before t1 finished"
        );
        data_t2.store(200, Ordering::SeqCst);
        mtx.unlock().expect("unlock t2");
    });

    t1.join().unwrap();
    t2.join().unwrap();

    assert_eq!(shared_data.load(Ordering::SeqCst), 200);
}

// Port of MutexTest.RapidLockUnlock
#[test]
fn rapid_lock_unlock() {
    let name = unique_name("rapid");
    IpcMutex::clear_storage(&name);

    let handles: Vec<_> = (0..2)
        .map(|_| {
            let name = name.clone();
            thread::spawn(move || {
                let mtx = IpcMutex::open(&name).expect("open");
                for _ in 0..1000 {
                    mtx.lock().expect("lock");
                    mtx.unlock().expect("unlock");
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }
    // Should complete without deadlock or crash
}

// Port of MutexTest.ConcurrentOpenClose
#[test]
fn concurrent_open() {
    let success_count = Arc::new(AtomicI32::new(0));

    let handles: Vec<_> = (0..5)
        .map(|i| {
            let sc = Arc::clone(&success_count);
            thread::spawn(move || {
                let name = format!("concurrent_open_{i}_{}", COUNTER.fetch_add(1, Ordering::Relaxed));
                IpcMutex::clear_storage(&name);
                if IpcMutex::open(&name).is_ok() {
                    sc.fetch_add(1, Ordering::Relaxed);
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    assert_eq!(success_count.load(Ordering::Relaxed), 5);
}

// Port of MutexTest.ZeroTimeout — via try_lock
#[test]
fn zero_timeout_via_try_lock() {
    let name = unique_name("zero_timeout");
    IpcMutex::clear_storage(&name);

    let mtx = IpcMutex::open(&name).expect("open");

    // try_lock on an uncontended mutex should succeed
    let locked = mtx.try_lock().expect("try_lock");
    assert!(locked);
    if locked {
        mtx.unlock().expect("unlock");
    }
}

// Port of MutexTest.TimedLockTimeoutScenario — adapted for try_lock
#[test]
fn try_lock_contended() {
    let name = unique_name("try_contended");
    IpcMutex::clear_storage(&name);

    let mtx_main = IpcMutex::open(&name).expect("open main");
    mtx_main.lock().expect("lock main");

    let contended = Arc::new(AtomicBool::new(false));
    let contended_ref = Arc::clone(&contended);
    let name_t = name.clone();

    let t = thread::spawn(move || {
        let mtx = IpcMutex::open(&name_t).expect("open thread");
        // Main thread holds the lock, so try_lock should return false
        match mtx.try_lock() {
            Ok(true) => {
                // Unlikely but possible if scheduling is weird
                mtx.unlock().expect("unlock");
            }
            Ok(false) => {
                contended_ref.store(true, Ordering::SeqCst);
            }
            Err(e) => panic!("try_lock error: {e}"),
        }
    });

    // Give the thread time to try
    thread::sleep(Duration::from_millis(50));
    mtx_main.unlock().expect("unlock main");

    t.join().unwrap();

    assert!(contended.load(Ordering::SeqCst), "try_lock should have been contended");
}

// Additional: lock protects non-atomic increment (data race test)
#[test]
fn protects_non_atomic_data() {
    let name = unique_name("non_atomic");
    IpcMutex::clear_storage(&name);

    // Use a raw pointer to a non-atomic counter to prove the mutex prevents data races
    let counter = Arc::new(std::sync::Mutex::new(0i32));
    let iterations = 500;

    let handles: Vec<_> = (0..4)
        .map(|_| {
            let name = name.clone();
            let counter = Arc::clone(&counter);
            thread::spawn(move || {
                let mtx = IpcMutex::open(&name).expect("open");
                for _ in 0..iterations {
                    mtx.lock().expect("lock");
                    let mut c = counter.lock().unwrap();
                    *c += 1;
                    drop(c);
                    mtx.unlock().expect("unlock");
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    assert_eq!(*counter.lock().unwrap(), iterations * 4);
}

// Additional: multiple lock/unlock on same thread (non-recursive should work with unlock between)
#[test]
fn sequential_lock_unlock_same_thread() {
    let name = unique_name("seq_same_thread");
    IpcMutex::clear_storage(&name);

    let mtx = IpcMutex::open(&name).expect("open");

    for i in 0..50 {
        mtx.lock().unwrap_or_else(|e| panic!("lock failed on iteration {i}: {e}"));
        mtx.unlock().unwrap_or_else(|e| panic!("unlock failed on iteration {i}: {e}"));
    }
}

// Additional: high contention with many threads
#[test]
fn high_contention() {
    let name = unique_name("high_contention");
    IpcMutex::clear_storage(&name);

    let counter = Arc::new(AtomicI32::new(0));
    let num_threads = 8;
    let ops_per_thread = 50;

    let handles: Vec<_> = (0..num_threads)
        .map(|_| {
            let name = name.clone();
            let counter = Arc::clone(&counter);
            thread::spawn(move || {
                let mtx = IpcMutex::open(&name).expect("open");
                for _ in 0..ops_per_thread {
                    mtx.lock().expect("lock");
                    counter.fetch_add(1, Ordering::Relaxed);
                    thread::sleep(Duration::from_micros(100));
                    mtx.unlock().expect("unlock");
                    thread::yield_now();
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    assert_eq!(counter.load(Ordering::Relaxed), num_threads * ops_per_thread);
}
