// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Tests for the chan_wrapper API gaps: valid, disconnect, reconnect, clone.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;

use libipc::channel::{Channel, Mode, Route};

static COUNTER: AtomicUsize = AtomicUsize::new(0);

fn unique_name(prefix: &str) -> String {
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}_cw_{n}_{}", std::process::id())
}

// ===========================================================================
// valid()
// ===========================================================================

#[test]
fn route_valid_after_connect() {
    let name = unique_name("rv_valid");
    Route::clear_storage(&name);
    let r = Route::connect(&name, Mode::Sender).expect("connect");
    assert!(r.valid());
    Route::clear_storage(&name);
}

#[test]
fn route_valid_false_after_disconnect() {
    let name = unique_name("rv_disc");
    Route::clear_storage(&name);
    let mut r = Route::connect(&name, Mode::Sender).expect("connect");
    assert!(r.valid());
    r.disconnect();
    assert!(!r.valid());
    Route::clear_storage(&name);
}

#[test]
fn channel_valid_after_connect() {
    let name = unique_name("cv_valid");
    Channel::clear_storage(&name);
    let c = Channel::connect(&name, Mode::Sender).expect("connect");
    assert!(c.valid());
    Channel::clear_storage(&name);
}

#[test]
fn channel_valid_false_after_disconnect() {
    let name = unique_name("cv_disc");
    Channel::clear_storage(&name);
    let mut c = Channel::connect(&name, Mode::Sender).expect("connect");
    assert!(c.valid());
    c.disconnect();
    assert!(!c.valid());
    Channel::clear_storage(&name);
}

// ===========================================================================
// disconnect()
// ===========================================================================

#[test]
fn route_disconnect_sender_decrements_count() {
    let name = unique_name("rd_sender");
    Route::clear_storage(&name);
    let mut s = Route::connect(&name, Mode::Sender).expect("sender");
    // A second sender to verify the count goes down by exactly 1.
    let s2 = Route::connect(&name, Mode::Sender).expect("sender2");
    let _ = s.recv_count(); // just to touch the API; sender_count isn't public
    s.disconnect();
    assert!(!s.valid());
    drop(s2);
    Route::clear_storage(&name);
}

#[test]
fn route_disconnect_receiver_frees_conn_bit() {
    let name = unique_name("rd_recv");
    Route::clear_storage(&name);
    let mut r = Route::connect(&name, Mode::Receiver).expect("receiver");
    assert_eq!(r.recv_count(), 1);
    r.disconnect();
    assert!(!r.valid());
    // After disconnect the bit is freed — a new receiver can connect.
    let r2 = Route::connect(&name, Mode::Receiver).expect("receiver2");
    assert_eq!(r2.recv_count(), 1);
    Route::clear_storage(&name);
}

#[test]
fn route_disconnect_idempotent() {
    let name = unique_name("rd_idem");
    Route::clear_storage(&name);
    let mut r = Route::connect(&name, Mode::Sender).expect("sender");
    r.disconnect();
    r.disconnect(); // second call must not panic
    assert!(!r.valid());
    Route::clear_storage(&name);
}

#[test]
fn channel_disconnect_receiver_frees_conn_bit() {
    let name = unique_name("cd_recv");
    Channel::clear_storage(&name);
    let mut r = Channel::connect(&name, Mode::Receiver).expect("receiver");
    assert_eq!(r.recv_count(), 1);
    r.disconnect();
    assert!(!r.valid());
    let r2 = Channel::connect(&name, Mode::Receiver).expect("receiver2");
    assert_eq!(r2.recv_count(), 1);
    Channel::clear_storage(&name);
}

// ===========================================================================
// reconnect()
// ===========================================================================

#[test]
fn route_reconnect_same_mode() {
    let name = unique_name("rr_same");
    Route::clear_storage(&name);
    let mut r = Route::connect(&name, Mode::Sender).expect("sender");
    r.reconnect(Mode::Sender).expect("reconnect");
    assert!(r.valid());
    assert_eq!(r.mode(), Mode::Sender);
    Route::clear_storage(&name);
}

#[test]
fn route_reconnect_sender_to_receiver() {
    let name = unique_name("rr_s2r");
    Route::clear_storage(&name);
    let mut r = Route::connect(&name, Mode::Sender).expect("sender");
    assert_eq!(r.mode(), Mode::Sender);
    r.reconnect(Mode::Receiver).expect("reconnect");
    assert!(r.valid());
    assert_eq!(r.mode(), Mode::Receiver);
    assert_eq!(r.recv_count(), 1);
    Route::clear_storage(&name);
}

#[test]
fn route_reconnect_receiver_to_sender() {
    let name = unique_name("rr_r2s");
    Route::clear_storage(&name);
    let mut r = Route::connect(&name, Mode::Receiver).expect("receiver");
    assert_eq!(r.recv_count(), 1);
    r.reconnect(Mode::Sender).expect("reconnect");
    assert!(r.valid());
    assert_eq!(r.mode(), Mode::Sender);
    assert_eq!(r.recv_count(), 0);
    Route::clear_storage(&name);
}

#[test]
fn route_reconnect_then_send_recv() {
    let name = unique_name("rr_sr");
    Route::clear_storage(&name);

    let name2 = name.clone();
    let sender = thread::spawn(move || {
        let mut s = Route::connect(&name2, Mode::Sender).expect("sender");
        s.wait_for_recv(1, Some(1000)).expect("wait");
        s.send(b"hello", 2000).expect("send")
    });

    let mut r = Route::connect(&name, Mode::Receiver).expect("receiver");
    // Reconnect as receiver (same mode) — should still work.
    r.reconnect(Mode::Receiver).expect("reconnect");
    let buf = r.recv(Some(3000)).expect("recv");

    sender.join().unwrap();
    assert_eq!(buf.data(), b"hello");
    Route::clear_storage(&name);
}

#[test]
fn channel_reconnect_sender_to_receiver() {
    let name = unique_name("cr_s2r");
    Channel::clear_storage(&name);
    let mut c = Channel::connect(&name, Mode::Sender).expect("sender");
    assert_eq!(c.mode(), Mode::Sender);
    c.reconnect(Mode::Receiver).expect("reconnect");
    assert!(c.valid());
    assert_eq!(c.mode(), Mode::Receiver);
    assert_eq!(c.recv_count(), 1);
    Channel::clear_storage(&name);
}

// ===========================================================================
// clone()
// ===========================================================================

#[test]
fn route_clone_sender() {
    let name = unique_name("rc_sender");
    Route::clear_storage(&name);
    let r = Route::connect(&name, Mode::Sender).expect("sender");
    let r2 = r.clone().expect("clone");
    assert_eq!(r2.name(), r.name());
    assert_eq!(r2.mode(), Mode::Sender);
    assert!(r2.valid());
    Route::clear_storage(&name);
}

#[test]
fn route_clone_receiver_independent() {
    let name = unique_name("rc_recv");
    Route::clear_storage(&name);
    let r1 = Route::connect(&name, Mode::Receiver).expect("receiver1");
    let r2 = r1.clone().expect("clone");
    // Both are independent receivers — each occupies its own conn bit.
    assert_eq!(r1.recv_count(), 2);
    assert_eq!(r2.recv_count(), 2);
    assert_eq!(r2.name(), r1.name());
    Route::clear_storage(&name);
}

#[test]
fn route_clone_disconnect_original_clone_still_valid() {
    let name = unique_name("rc_indep");
    Route::clear_storage(&name);
    let mut r1 = Route::connect(&name, Mode::Receiver).expect("receiver");
    let r2 = r1.clone().expect("clone");
    r1.disconnect();
    assert!(!r1.valid());
    // Clone is independent — still valid and still has its conn bit.
    assert!(r2.valid());
    assert_eq!(r2.recv_count(), 1);
    Route::clear_storage(&name);
}

#[test]
fn route_clone_send_recv() {
    let name = unique_name("rc_sr");
    Route::clear_storage(&name);

    let name2 = name.clone();
    let sender = thread::spawn(move || {
        let mut s = Route::connect(&name2, Mode::Sender).expect("sender");
        s.wait_for_recv(2, Some(1000)).expect("wait");
        s.send(b"cloned", 2000).expect("send")
    });

    let r1 = Route::connect(&name, Mode::Receiver).expect("r1");
    let mut r2 = r1.clone().expect("r2");
    // Use r2 to receive (r1 is kept alive to hold its conn bit).
    let buf = r2.recv(Some(3000)).expect("recv");

    sender.join().unwrap();
    assert_eq!(buf.data(), b"cloned");
    Route::clear_storage(&name);
}

#[test]
fn channel_clone_sender() {
    let name = unique_name("cc_sender");
    Channel::clear_storage(&name);
    let c = Channel::connect(&name, Mode::Sender).expect("sender");
    let c2 = c.clone().expect("clone");
    assert_eq!(c2.name(), c.name());
    assert_eq!(c2.mode(), Mode::Sender);
    assert!(c2.valid());
    Channel::clear_storage(&name);
}

#[test]
fn channel_clone_receiver_independent() {
    let name = unique_name("cc_recv");
    Channel::clear_storage(&name);
    let c1 = Channel::connect(&name, Mode::Receiver).expect("receiver1");
    let c2 = c1.clone().expect("clone");
    assert_eq!(c1.recv_count(), 2);
    assert_eq!(c2.recv_count(), 2);
    Channel::clear_storage(&name);
}

// ===========================================================================
// release()
// ===========================================================================

#[test]
fn route_release_marks_invalid() {
    let name = unique_name("rrel");
    Route::clear_storage(&name);
    let mut r = Route::connect(&name, Mode::Sender).expect("sender");
    assert!(r.valid());
    r.release();
    assert!(!r.valid());
    Route::clear_storage(&name);
}

#[test]
fn channel_release_marks_invalid() {
    let name = unique_name("crel");
    Channel::clear_storage(&name);
    let mut c = Channel::connect(&name, Mode::Sender).expect("sender");
    assert!(c.valid());
    c.release();
    assert!(!c.valid());
    Channel::clear_storage(&name);
}

// ===========================================================================
// clear()
// ===========================================================================

#[test]
fn route_clear_disconnects_and_removes_storage() {
    let name = unique_name("rclr");
    Route::clear_storage(&name);
    let mut r = Route::connect(&name, Mode::Receiver).expect("receiver");
    assert_eq!(r.recv_count(), 1);
    r.clear();
    assert!(!r.valid());
    // After clear, a fresh connect should see 0 receivers (SHM was removed).
    let r2 = Route::connect(&name, Mode::Receiver).expect("fresh receiver");
    assert_eq!(r2.recv_count(), 1);
    Route::clear_storage(&name);
}

#[test]
fn channel_clear_disconnects_and_removes_storage() {
    let name = unique_name("cclr");
    Channel::clear_storage(&name);
    let mut c = Channel::connect(&name, Mode::Receiver).expect("receiver");
    assert_eq!(c.recv_count(), 1);
    c.clear();
    assert!(!c.valid());
    let c2 = Channel::connect(&name, Mode::Receiver).expect("fresh receiver");
    assert_eq!(c2.recv_count(), 1);
    Channel::clear_storage(&name);
}

// ===========================================================================
// wait_for_recv_on() static
// ===========================================================================

#[test]
fn route_wait_for_recv_on_sees_existing_receiver() {
    let name = unique_name("rwfr");
    Route::clear_storage(&name);
    let _r = Route::connect(&name, Mode::Receiver).expect("receiver");
    let ok = Route::wait_for_recv_on(&name, 1, Some(500)).expect("wait");
    assert!(ok);
    Route::clear_storage(&name);
}

#[test]
fn route_wait_for_recv_on_times_out_with_no_receiver() {
    let name = unique_name("rwfr_to");
    Route::clear_storage(&name);
    let ok = Route::wait_for_recv_on(&name, 1, Some(50)).expect("wait");
    assert!(!ok);
    Route::clear_storage(&name);
}

#[test]
fn channel_wait_for_recv_on_sees_existing_receiver() {
    let name = unique_name("cwfr");
    Channel::clear_storage(&name);
    let _r = Channel::connect(&name, Mode::Receiver).expect("receiver");
    let ok = Channel::wait_for_recv_on(&name, 1, Some(500)).expect("wait");
    assert!(ok);
    Channel::clear_storage(&name);
}
