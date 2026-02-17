// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Rust port of cpp-ipc/test/test_locks.cpp (RWLock section).

use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use libipc::RwLock;

// Port of RWLockTest.BasicWriteLock
#[test]
fn basic_write_lock() {
    let lock = RwLock::new();
    lock.lock();
    lock.unlock();
}

// Port of RWLockTest.BasicReadLock
#[test]
fn basic_read_lock() {
    let lock = RwLock::new();
    lock.lock_shared();
    lock.unlock_shared();
}

// Port of RWLockTest.MultipleWriteCycles
#[test]
fn multiple_write_cycles() {
    let lock = RwLock::new();
    for _ in 0..100 {
        lock.lock();
        lock.unlock();
    }
}

// Port of RWLockTest.MultipleReadCycles
#[test]
fn multiple_read_cycles() {
    let lock = RwLock::new();
    for _ in 0..100 {
        lock.lock_shared();
        lock.unlock_shared();
    }
}

// Port of RWLockTest.WriteLockProtection
#[test]
fn write_lock_protection() {
    let lock = Arc::new(RwLock::new());
    let data = Arc::new(AtomicI32::new(0));
    let iterations = 500;

    let handles: Vec<_> = (0..2)
        .map(|_| {
            let lock = Arc::clone(&lock);
            let data = Arc::clone(&data);
            thread::spawn(move || {
                for _ in 0..iterations {
                    lock.lock();
                    data.fetch_add(1, Ordering::Relaxed);
                    lock.unlock();
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    assert_eq!(data.load(Ordering::Relaxed), iterations * 2);
}

// Port of RWLockTest.ConcurrentReaders
#[test]
fn concurrent_readers() {
    let lock = Arc::new(RwLock::new());
    let concurrent_readers = Arc::new(AtomicI32::new(0));
    let max_concurrent = Arc::new(AtomicI32::new(0));
    let num_readers = 5;

    let handles: Vec<_> = (0..num_readers)
        .map(|_| {
            let lock = Arc::clone(&lock);
            let cr = Arc::clone(&concurrent_readers);
            let mc = Arc::clone(&max_concurrent);
            thread::spawn(move || {
                for _ in 0..20 {
                    lock.lock_shared();

                    let current = cr.fetch_add(1, Ordering::SeqCst) + 1;
                    // Track maximum concurrent readers
                    let mut current_max = mc.load(Ordering::Relaxed);
                    while current as i32 > current_max {
                        match mc.compare_exchange_weak(
                            current_max,
                            current as i32,
                            Ordering::Relaxed,
                            Ordering::Relaxed,
                        ) {
                            Ok(_) => break,
                            Err(v) => current_max = v,
                        }
                    }

                    thread::sleep(Duration::from_micros(100));

                    cr.fetch_sub(1, Ordering::SeqCst);
                    lock.unlock_shared();

                    thread::yield_now();
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    assert!(
        max_concurrent.load(Ordering::Relaxed) > 1,
        "should have had multiple concurrent readers"
    );
}

// Port of RWLockTest.WriterExclusiveAccess
#[test]
fn writer_exclusive_access() {
    let lock = Arc::new(RwLock::new());
    let writer_in_cs = Arc::new(AtomicBool::new(false));
    let violation = Arc::new(AtomicBool::new(false));

    let handles: Vec<_> = (0..2)
        .map(|_| {
            let lock = Arc::clone(&lock);
            let wics = Arc::clone(&writer_in_cs);
            let viol = Arc::clone(&violation);
            thread::spawn(move || {
                for _ in 0..50 {
                    lock.lock();
                    if wics.swap(true, Ordering::SeqCst) {
                        viol.store(true, Ordering::SeqCst);
                    }
                    thread::sleep(Duration::from_micros(50));
                    wics.store(false, Ordering::SeqCst);
                    lock.unlock();
                    thread::yield_now();
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    assert!(!violation.load(Ordering::SeqCst));
}

// Port of RWLockTest.ReadersWritersNoOverlap
#[test]
fn readers_writers_no_overlap() {
    let lock = Arc::new(RwLock::new());
    let readers = Arc::new(AtomicI32::new(0));
    let writer_active = Arc::new(AtomicBool::new(false));
    let violation = Arc::new(AtomicBool::new(false));

    let lock_r1 = Arc::clone(&lock);
    let readers_r1 = Arc::clone(&readers);
    let wa_r1 = Arc::clone(&writer_active);
    let viol_r1 = Arc::clone(&violation);
    let r1 = thread::spawn(move || {
        for _ in 0..30 {
            lock_r1.lock_shared();
            readers_r1.fetch_add(1, Ordering::SeqCst);
            if wa_r1.load(Ordering::SeqCst) {
                viol_r1.store(true, Ordering::SeqCst);
            }
            thread::sleep(Duration::from_micros(50));
            readers_r1.fetch_sub(1, Ordering::SeqCst);
            lock_r1.unlock_shared();
            thread::yield_now();
        }
    });

    let lock_r2 = Arc::clone(&lock);
    let readers_r2 = Arc::clone(&readers);
    let wa_r2 = Arc::clone(&writer_active);
    let viol_r2 = Arc::clone(&violation);
    let r2 = thread::spawn(move || {
        for _ in 0..30 {
            lock_r2.lock_shared();
            readers_r2.fetch_add(1, Ordering::SeqCst);
            if wa_r2.load(Ordering::SeqCst) {
                viol_r2.store(true, Ordering::SeqCst);
            }
            thread::sleep(Duration::from_micros(50));
            readers_r2.fetch_sub(1, Ordering::SeqCst);
            lock_r2.unlock_shared();
            thread::yield_now();
        }
    });

    let lock_w = Arc::clone(&lock);
    let readers_w = Arc::clone(&readers);
    let wa_w = Arc::clone(&writer_active);
    let viol_w = Arc::clone(&violation);
    let w1 = thread::spawn(move || {
        for _ in 0..15 {
            lock_w.lock();
            wa_w.store(true, Ordering::SeqCst);
            if readers_w.load(Ordering::SeqCst) > 0 {
                viol_w.store(true, Ordering::SeqCst);
            }
            thread::sleep(Duration::from_micros(50));
            wa_w.store(false, Ordering::SeqCst);
            lock_w.unlock();
            thread::yield_now();
        }
    });

    r1.join().unwrap();
    r2.join().unwrap();
    w1.join().unwrap();

    assert!(!violation.load(Ordering::SeqCst));
}

// Port of RWLockTest.ReadWriteReadPattern
#[test]
fn read_write_read_pattern() {
    let lock = Arc::new(RwLock::new());
    let data = Arc::new(AtomicI32::new(0));
    let iterations = Arc::new(AtomicI32::new(0));

    let handles: Vec<_> = (1..=2)
        .map(|id| {
            let lock = Arc::clone(&lock);
            let data = Arc::clone(&data);
            let iters = Arc::clone(&iterations);
            thread::spawn(move || {
                for _ in 0..20 {
                    // Write
                    lock.lock();
                    data.fetch_add(id, Ordering::Relaxed);
                    lock.unlock();

                    iters.fetch_add(1, Ordering::Relaxed);
                    thread::yield_now();

                    // Read
                    lock.lock_shared();
                    let read_val = data.load(Ordering::Relaxed);
                    assert!(read_val >= 0);
                    lock.unlock_shared();

                    thread::yield_now();
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    // Each thread increments by its id (1 or 2), 20 times each
    // Total = 1*20 + 2*20 = 60
    assert_eq!(data.load(Ordering::Relaxed), 60);
    assert_eq!(iterations.load(Ordering::Relaxed), 40);
}

// Port of RWLockTest.ManyReadersOneWriter
#[test]
fn many_readers_one_writer() {
    let lock = Arc::new(RwLock::new());
    let data = Arc::new(AtomicI32::new(0));
    let read_count = Arc::new(AtomicI32::new(0));
    let num_readers = 10;

    let mut handles: Vec<_> = (0..num_readers)
        .map(|_| {
            let lock = Arc::clone(&lock);
            let data = Arc::clone(&data);
            let rc = Arc::clone(&read_count);
            thread::spawn(move || {
                for _ in 0..50 {
                    lock.lock_shared();
                    let _ = data.load(Ordering::Relaxed);
                    rc.fetch_add(1, Ordering::Relaxed);
                    lock.unlock_shared();
                    thread::yield_now();
                }
            })
        })
        .collect();

    let lock_w = Arc::clone(&lock);
    let data_w = Arc::clone(&data);
    handles.push(thread::spawn(move || {
        for _ in 0..100 {
            lock_w.lock();
            data_w.fetch_add(1, Ordering::Relaxed);
            lock_w.unlock();
            thread::yield_now();
        }
    }));

    for h in handles {
        h.join().unwrap();
    }

    assert_eq!(data.load(Ordering::Relaxed), 100);
    assert_eq!(read_count.load(Ordering::Relaxed), num_readers * 50);
}

// Port of RWLockTest.RapidReadLocks
#[test]
fn rapid_read_locks() {
    let lock = Arc::new(RwLock::new());

    let handles: Vec<_> = (0..3)
        .map(|_| {
            let lock = Arc::clone(&lock);
            thread::spawn(move || {
                for _ in 0..5000 {
                    lock.lock_shared();
                    lock.unlock_shared();
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }
}

// Port of RWLockTest.RapidWriteLocks
#[test]
fn rapid_write_locks() {
    let lock = Arc::new(RwLock::new());

    let handles: Vec<_> = (0..2)
        .map(|_| {
            let lock = Arc::clone(&lock);
            thread::spawn(move || {
                for _ in 0..2000 {
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

// Port of RWLockTest.MixedRapidOperations
#[test]
fn mixed_rapid_operations() {
    let lock = Arc::new(RwLock::new());

    let lock_r1 = Arc::clone(&lock);
    let r1 = thread::spawn(move || {
        for _ in 0..1000 {
            lock_r1.lock_shared();
            lock_r1.unlock_shared();
        }
    });
    let lock_r2 = Arc::clone(&lock);
    let r2 = thread::spawn(move || {
        for _ in 0..1000 {
            lock_r2.lock_shared();
            lock_r2.unlock_shared();
        }
    });
    let lock_w1 = Arc::clone(&lock);
    let w1 = thread::spawn(move || {
        for _ in 0..500 {
            lock_w1.lock();
            lock_w1.unlock();
        }
    });

    r1.join().unwrap();
    r2.join().unwrap();
    w1.join().unwrap();
}

// Port of RWLockTest.WriteLockBlocksReaders
#[test]
fn write_lock_blocks_readers() {
    let lock = Arc::new(RwLock::new());
    let write_locked = Arc::new(AtomicBool::new(false));
    let reader_entered = Arc::new(AtomicBool::new(false));

    let lock_w = Arc::clone(&lock);
    let wl = Arc::clone(&write_locked);
    let writer = thread::spawn(move || {
        lock_w.lock();
        wl.store(true, Ordering::SeqCst);
        thread::sleep(Duration::from_millis(100));
        wl.store(false, Ordering::SeqCst);
        lock_w.unlock();
    });

    let lock_r = Arc::clone(&lock);
    let wl2 = Arc::clone(&write_locked);
    let re = Arc::clone(&reader_entered);
    let reader = thread::spawn(move || {
        thread::sleep(Duration::from_millis(20));
        lock_r.lock_shared();
        if wl2.load(Ordering::SeqCst) {
            re.store(true, Ordering::SeqCst);
        }
        lock_r.unlock_shared();
    });

    writer.join().unwrap();
    reader.join().unwrap();

    assert!(!reader_entered.load(Ordering::SeqCst));
}

// Port of RWLockTest.MultipleWriteLockPattern
#[test]
fn multiple_write_lock_pattern() {
    let lock = RwLock::new();
    let mut data = 0i32;

    for _ in 0..100 {
        lock.lock_shared();
        let temp = data;
        lock.unlock_shared();

        lock.lock();
        data = temp + 1;
        lock.unlock();
    }

    assert_eq!(data, 100);
}

// Port of RWLockTest.ConcurrentMixedOperations
#[test]
fn concurrent_mixed_operations() {
    let lock = Arc::new(RwLock::new());
    let data = Arc::new(AtomicI32::new(0));
    let reads = Arc::new(AtomicI32::new(0));
    let writes = Arc::new(AtomicI32::new(0));

    let handles: Vec<_> = (0..4)
        .map(|_| {
            let lock = Arc::clone(&lock);
            let data = Arc::clone(&data);
            let reads = Arc::clone(&reads);
            let writes = Arc::clone(&writes);
            thread::spawn(move || {
                for i in 0..50 {
                    if i % 3 == 0 {
                        lock.lock();
                        data.fetch_add(1, Ordering::Relaxed);
                        writes.fetch_add(1, Ordering::Relaxed);
                        lock.unlock();
                    } else {
                        lock.lock_shared();
                        let _ = data.load(Ordering::Relaxed);
                        reads.fetch_add(1, Ordering::Relaxed);
                        lock.unlock_shared();
                    }
                    thread::yield_now();
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    assert!(reads.load(Ordering::Relaxed) > 0);
    assert!(writes.load(Ordering::Relaxed) > 0);
}
