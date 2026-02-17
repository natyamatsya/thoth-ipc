// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of circ/connection tests from cpp-ipc/test/archive/test_queue.cpp.
// Tests for BroadcastConnHead and UnicastConnHead bitmask allocation.

use std::sync::atomic::Ordering;

use libipc::circ::{BroadcastConnHead, UnicastConnHead};

/// Helper: create a zero-initialized BroadcastConnHead on the heap.
fn new_broadcast() -> Box<BroadcastConnHead> {
    // SAFETY: BroadcastConnHead is repr(C) with all-zeroes being a valid
    // (uninitialised) state; init() will set up the constructed flag.
    let head: Box<BroadcastConnHead> = unsafe {
        let layout = std::alloc::Layout::new::<BroadcastConnHead>();
        let ptr = std::alloc::alloc_zeroed(layout) as *mut BroadcastConnHead;
        Box::from_raw(ptr)
    };
    head.init();
    head
}

fn new_unicast() -> Box<UnicastConnHead> {
    let head: Box<UnicastConnHead> = unsafe {
        let layout = std::alloc::Layout::new::<UnicastConnHead>();
        let ptr = std::alloc::alloc_zeroed(layout) as *mut UnicastConnHead;
        Box::from_raw(ptr)
    };
    head.init();
    head
}

// --- BroadcastConnHead tests ---

#[test]
fn broadcast_initial_state() {
    let h = new_broadcast();
    assert_eq!(h.connections(Ordering::Relaxed), 0);
    assert_eq!(h.conn_count(Ordering::Relaxed), 0);
}

#[test]
fn broadcast_connect_single() {
    let h = new_broadcast();
    let id = h.connect();
    assert_ne!(id, 0);
    assert_eq!(id, 1); // first bit
    assert!(h.connected(id));
    assert_eq!(h.conn_count(Ordering::Relaxed), 1);
}

#[test]
fn broadcast_connect_multiple() {
    let h = new_broadcast();
    let id1 = h.connect();
    let id2 = h.connect();
    let id3 = h.connect();

    assert_eq!(id1, 0b001);
    assert_eq!(id2, 0b010);
    assert_eq!(id3, 0b100);

    assert!(h.connected(id1));
    assert!(h.connected(id2));
    assert!(h.connected(id3));
    assert_eq!(h.conn_count(Ordering::Relaxed), 3);
    assert_eq!(h.connections(Ordering::Relaxed), 0b111);
}

// Port of Queue.el_connection — fill all 32 bits
#[test]
fn broadcast_connect_full() {
    let h = new_broadcast();
    for i in 0..32 {
        let id = h.connect();
        assert_ne!(id, 0, "bit {i} should succeed");
    }
    assert_eq!(h.conn_count(Ordering::Relaxed), 32);

    // 33rd connection should fail
    for _ in 0..100 {
        assert_eq!(h.connect(), 0, "full — should return 0");
    }
}

#[test]
fn broadcast_disconnect() {
    let h = new_broadcast();
    let id1 = h.connect();
    let id2 = h.connect();
    assert_eq!(h.conn_count(Ordering::Relaxed), 2);

    h.disconnect(id1);
    assert!(!h.connected(id1));
    assert!(h.connected(id2));
    assert_eq!(h.conn_count(Ordering::Relaxed), 1);
}

#[test]
fn broadcast_disconnect_reconnect() {
    let h = new_broadcast();
    let id1 = h.connect(); // bit 0
    let _id2 = h.connect(); // bit 1

    h.disconnect(id1); // free bit 0
    let id3 = h.connect(); // should reuse bit 0
    assert_eq!(id3, id1, "should reuse freed bit");
    assert_eq!(h.conn_count(Ordering::Relaxed), 2);
}

// Port of Queue.el_connection — fill, free one, re-fill
#[test]
fn broadcast_full_free_refill() {
    let h = new_broadcast();
    let mut ids = Vec::new();
    for _ in 0..32 {
        ids.push(h.connect());
    }
    assert_eq!(h.connect(), 0); // full

    // Free slot 10
    let freed = ids[10];
    h.disconnect(freed);
    assert_eq!(h.conn_count(Ordering::Relaxed), 31);

    // Reconnect — should get the same bit back
    let new_id = h.connect();
    assert_eq!(new_id, freed);
    assert_eq!(h.conn_count(Ordering::Relaxed), 32);

    // Full again
    assert_eq!(h.connect(), 0);
}

// --- UnicastConnHead tests ---

#[test]
fn unicast_initial_state() {
    let h = new_unicast();
    assert_eq!(h.connections(Ordering::Relaxed), 0);
    assert_eq!(h.conn_count(Ordering::Relaxed), 0);
}

#[test]
fn unicast_connect_single() {
    let h = new_unicast();
    let id = h.connect();
    assert_eq!(id, 1);
    assert!(h.connected(id));
    assert_eq!(h.conn_count(Ordering::Relaxed), 1);
}

#[test]
fn unicast_connect_multiple() {
    let h = new_unicast();
    for i in 1..=100 {
        let id = h.connect();
        assert_eq!(id, i);
    }
    assert_eq!(h.conn_count(Ordering::Relaxed), 100);
}

#[test]
fn unicast_disconnect() {
    let h = new_unicast();
    let id = h.connect();
    assert_eq!(h.conn_count(Ordering::Relaxed), 1);

    h.disconnect(id);
    assert_eq!(h.conn_count(Ordering::Relaxed), 0);
    assert!(!h.connected(0));
}

#[test]
fn unicast_disconnect_all() {
    let h = new_unicast();
    for _ in 0..5 {
        h.connect();
    }
    assert_eq!(h.conn_count(Ordering::Relaxed), 5);

    h.disconnect(!0u32); // disconnect all
    assert_eq!(h.conn_count(Ordering::Relaxed), 0);
}

// --- Concurrent broadcast connect ---

#[test]
fn broadcast_concurrent_connect() {
    let h = Box::leak(new_broadcast()) as &'static BroadcastConnHead;
    let mut threads = Vec::new();

    // 8 threads each connect once
    for _ in 0..8 {
        threads.push(std::thread::spawn(move || {
            let id = h.connect();
            assert_ne!(id, 0);
            id
        }));
    }

    let mut ids: Vec<u32> = threads.into_iter().map(|t| t.join().unwrap()).collect();
    ids.sort();

    // All IDs should be unique power-of-two bits
    for (i, &id) in ids.iter().enumerate() {
        assert!(id.is_power_of_two(), "id {id:#x} should be power of two");
        // No duplicates
        if i > 0 {
            assert_ne!(id, ids[i - 1]);
        }
    }

    assert_eq!(h.conn_count(Ordering::Relaxed), 8);

    // Clean up leaked box (safe because no more references)
    unsafe { drop(Box::from_raw(h as *const _ as *mut BroadcastConnHead)) };
}
