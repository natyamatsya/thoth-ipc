// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Tests for the proto layer: shm_ring, service_registry, process_manager, rt_prio.

use libipc::proto::{audio_period_ns, set_realtime_priority, ServiceRegistry, ShmRing};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;

static COUNTER: AtomicUsize = AtomicUsize::new(0);

fn unique_name(prefix: &str) -> String {
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}_proto_{n}_{}", std::process::id())
}

// ===========================================================================
// ShmRing tests
// ===========================================================================

#[test]
fn shm_ring_open_or_create() {
    let name = unique_name("ring_ctor");
    let mut ring: ShmRing<u32, 8> = ShmRing::new(&name);
    ring.open_or_create().expect("open_or_create");
    assert!(ring.valid());
    ring.destroy();
}

#[test]
fn shm_ring_write_read_single() {
    let name = unique_name("ring_wr1");
    let mut ring: ShmRing<u32, 8> = ShmRing::new(&name);
    ring.open_or_create().expect("open");

    assert!(ring.write(&42u32));
    let mut out = 0u32;
    assert!(ring.read(&mut out));
    assert_eq!(out, 42);
    ring.destroy();
}

#[test]
fn shm_ring_empty_read_returns_false() {
    let name = unique_name("ring_empty");
    let mut ring: ShmRing<u32, 4> = ShmRing::new(&name);
    ring.open_or_create().expect("open");

    let mut out = 0u32;
    assert!(!ring.read(&mut out));
    ring.destroy();
}

#[test]
fn shm_ring_full_write_returns_false() {
    let name = unique_name("ring_full");
    let mut ring: ShmRing<u32, 4> = ShmRing::new(&name);
    ring.open_or_create().expect("open");

    for i in 0..4u32 {
        assert!(ring.write(&i));
    }
    assert!(ring.is_full());
    assert!(!ring.write(&99u32)); // full
    ring.destroy();
}

#[test]
fn shm_ring_write_overwrite_drops_oldest() {
    let name = unique_name("ring_overwrite");
    let mut ring: ShmRing<u32, 4> = ShmRing::new(&name);
    ring.open_or_create().expect("open");

    for i in 0..4u32 {
        ring.write(&i);
    }
    // Overwrite: oldest (0) should be dropped
    ring.write_overwrite(&99u32);

    let mut out = 0u32;
    ring.read(&mut out);
    assert_eq!(out, 1); // 0 was dropped
    ring.read(&mut out);
    assert_eq!(out, 2);
    ring.read(&mut out);
    assert_eq!(out, 3);
    ring.read(&mut out);
    assert_eq!(out, 99);
    ring.destroy();
}

#[test]
fn shm_ring_available() {
    let name = unique_name("ring_avail");
    let mut ring: ShmRing<u64, 8> = ShmRing::new(&name);
    ring.open_or_create().expect("open");

    assert_eq!(ring.available(), 0);
    ring.write(&1u64);
    ring.write(&2u64);
    assert_eq!(ring.available(), 2);
    let mut v = 0u64;
    ring.read(&mut v);
    assert_eq!(ring.available(), 1);
    ring.destroy();
}

#[test]
fn shm_ring_fifo_order() {
    let name = unique_name("ring_fifo");
    let mut ring: ShmRing<u32, 16> = ShmRing::new(&name);
    ring.open_or_create().expect("open");

    for i in 0..10u32 {
        ring.write(&i);
    }
    for i in 0..10u32 {
        let mut v = 0u32;
        assert!(ring.read(&mut v));
        assert_eq!(v, i);
    }
    ring.destroy();
}

#[test]
fn shm_ring_spsc_cross_thread() {
    let name = unique_name("ring_spsc");
    let name2 = name.clone();

    // Producer thread
    let producer = thread::spawn(move || {
        let mut ring: ShmRing<u64, 32> = ShmRing::new(&name2);
        ring.open_or_create().expect("open producer");
        for i in 0..20u64 {
            while !ring.write(&i) {
                thread::yield_now();
            }
        }
    });

    let mut ring: ShmRing<u64, 32> = ShmRing::new(&name);
    ring.open_or_create().expect("open consumer");

    let mut received = Vec::new();
    while received.len() < 20 {
        let mut v = 0u64;
        if ring.read(&mut v) {
            received.push(v);
        } else {
            thread::yield_now();
        }
    }

    producer.join().unwrap();
    assert_eq!(received, (0..20u64).collect::<Vec<_>>());
    ring.destroy();
}

#[test]
fn shm_ring_write_slot_commit() {
    let name = unique_name("ring_slot");
    let mut ring: ShmRing<u32, 8> = ShmRing::new(&name);
    ring.open_or_create().expect("open");

    let slot = ring.write_slot().expect("slot");
    unsafe {
        *slot = 77u32;
    }
    ring.write_commit();

    let mut out = 0u32;
    assert!(ring.read(&mut out));
    assert_eq!(out, 77);
    ring.destroy();
}

#[test]
fn shm_ring_read_slot_commit() {
    let name = unique_name("ring_rslot");
    let mut ring: ShmRing<u32, 8> = ShmRing::new(&name);
    ring.open_or_create().expect("open");

    ring.write(&55u32);
    let slot = ring.read_slot().expect("read slot");
    let v = unsafe { *slot };
    ring.read_commit();
    assert_eq!(v, 55);
    assert!(ring.is_empty());
    ring.destroy();
}

// ===========================================================================
// ServiceRegistry tests
// ===========================================================================

#[test]
fn service_registry_open() {
    let domain = unique_name("reg_open");
    let reg = ServiceRegistry::open(&domain).expect("open");
    let _ = reg; // just ensure it opens without panic
}

#[test]
fn service_registry_register_find() {
    let domain = unique_name("reg_reg_find");
    let reg = ServiceRegistry::open(&domain).expect("open");

    let ok = reg.register_service("svc_a", "ctrl_a", "reply_a");
    assert!(ok, "register should succeed");

    let entry = reg.find("svc_a").expect("find");
    assert_eq!(entry.name_str(), "svc_a");
    assert_eq!(entry.control_channel_str(), "ctrl_a");
    assert_eq!(entry.reply_channel_str(), "reply_a");
}

#[test]
fn service_registry_find_missing_returns_none() {
    let domain = unique_name("reg_missing");
    let reg = ServiceRegistry::open(&domain).expect("open");
    assert!(reg.find("nonexistent").is_none());
}

#[test]
fn service_registry_unregister() {
    let domain = unique_name("reg_unreg");
    let reg = ServiceRegistry::open(&domain).expect("open");

    reg.register_service("svc_b", "ctrl_b", "reply_b");
    assert!(reg.find("svc_b").is_some());

    let ok = reg.unregister_service("svc_b");
    assert!(ok);
    assert!(reg.find("svc_b").is_none());
}

#[test]
fn service_registry_duplicate_register_fails() {
    let domain = unique_name("reg_dup");
    let reg = ServiceRegistry::open(&domain).expect("open");

    assert!(reg.register_service("svc_c", "ctrl_c", "reply_c"));
    // Second registration of same name with same (live) PID should fail
    assert!(!reg.register_service("svc_c", "ctrl_c2", "reply_c2"));
}

#[test]
fn service_registry_list() {
    let domain = unique_name("reg_list");
    let reg = ServiceRegistry::open(&domain).expect("open");

    reg.register_service("svc_x", "cx", "rx");
    reg.register_service("svc_y", "cy", "ry");

    let list = reg.list();
    let names: Vec<&str> = list.iter().map(|e| e.name_str()).collect();
    assert!(names.contains(&"svc_x"));
    assert!(names.contains(&"svc_y"));
}

#[test]
fn service_registry_find_all_prefix() {
    let domain = unique_name("reg_prefix");
    let reg = ServiceRegistry::open(&domain).expect("open");

    reg.register_service("audio.0", "c0", "r0");
    reg.register_service("audio.1", "c1", "r1");
    reg.register_service("video.0", "cv", "rv");

    let audio = reg.find_all("audio");
    assert_eq!(audio.len(), 2);
    let video = reg.find_all("video");
    assert_eq!(video.len(), 1);
}

#[test]
fn service_registry_clear() {
    let domain = unique_name("reg_clear");
    let reg = ServiceRegistry::open(&domain).expect("open");

    reg.register_service("svc_d", "cd", "rd");
    assert!(reg.find("svc_d").is_some());
    reg.clear();
    assert!(reg.find("svc_d").is_none());
    assert!(reg.list().is_empty());
}

#[test]
fn service_registry_gc_removes_stale() {
    let domain = unique_name("reg_gc");
    let reg = ServiceRegistry::open(&domain).expect("open");

    // Register with a dead PID (PID 1 on macOS is launchd — alive; use a
    // clearly-dead PID like i32::MAX which no process will have).
    // We use register_service_as to inject a fake dead PID.
    reg.register_service_as("dead_svc", "c", "r", i32::MAX);

    let removed = reg.gc();
    assert!(removed >= 1);
    assert!(reg.find("dead_svc").is_none());
}

#[test]
fn service_registry_shared_across_threads() {
    let domain = unique_name("reg_threads");
    let reg = Arc::new(ServiceRegistry::open(&domain).expect("open"));

    let reg2 = Arc::clone(&reg);
    let t = thread::spawn(move || {
        reg2.register_service("thread_svc", "ct", "rt");
    });
    t.join().unwrap();

    assert!(reg.find("thread_svc").is_some());
}

// ===========================================================================
// rt_prio tests
// ===========================================================================

#[test]
fn audio_period_ns_48k_256() {
    // 256 frames at 48 kHz = 5_333_333 ns
    let ns = audio_period_ns(48_000, 256);
    assert_eq!(ns, 5_333_333);
}

#[test]
fn audio_period_ns_44k_512() {
    let ns = audio_period_ns(44_100, 512);
    assert!(ns > 11_000_000 && ns < 12_000_000);
}

#[test]
fn set_realtime_priority_runs_without_panic() {
    // We don't assert success (may require elevated privileges) but it must not panic.
    let _ = set_realtime_priority(5_333_333, None, None);
}
