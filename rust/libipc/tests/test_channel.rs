// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Rust port of cpp-ipc/test/test_ipc_channel.cpp

use std::sync::atomic::{AtomicBool, AtomicI32, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use libipc::{Channel, IpcBuffer, Mode, Route};

static COUNTER: AtomicUsize = AtomicUsize::new(0);

fn unique_name(prefix: &str) -> String {
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{prefix}_ipc_{n}")
}

// ========== Route Tests ==========

// Port of RouteTest.ConstructionWithName
#[test]
fn route_construction() {
    let name = unique_name("route_ctor");
    Route::clear_storage(&name);

    let r = Route::connect(&name, Mode::Sender).expect("connect");
    assert_eq!(r.name(), name);
}

// Port of RouteTest.ConstructionWithPrefix
#[test]
fn route_with_prefix() {
    let name = unique_name("route_prefix");
    Route::clear_storage_with_prefix("my_prefix", &name);

    let r = Route::connect_with_prefix("my_prefix", &name, Mode::Sender).expect("connect");
    assert_eq!(r.name(), name);
}

// Port of RouteTest.ClearStorage
#[test]
fn route_clear_storage() {
    let name = unique_name("route_clear_storage");
    Route::clear_storage(&name);

    {
        let _r = Route::connect(&name, Mode::Sender).expect("connect");
    }

    Route::clear_storage(&name);
}

// Port of RouteTest.ClearStorageWithPrefix
#[test]
fn route_clear_storage_with_prefix() {
    let name = unique_name("route_clear_prefix");
    Route::clear_storage_with_prefix("test", &name);

    {
        let _r = Route::connect_with_prefix("test", &name, Mode::Sender).expect("connect");
    }

    Route::clear_storage_with_prefix("test", &name);
}

// Port of RouteTest.SendWithoutReceiver
#[test]
fn route_send_without_receiver() {
    let name = unique_name("route_send_no_recv");
    Route::clear_storage(&name);

    let mut r = Route::connect(&name, Mode::Sender).expect("connect");
    let sent = r.send(b"test", 10).expect("send");
    assert!(!sent); // no receiver
}

// Port of RouteTest.TrySendWithoutReceiver
#[test]
fn route_try_send_without_receiver() {
    let name = unique_name("route_try_send_no_recv");
    Route::clear_storage(&name);

    let mut r = Route::connect(&name, Mode::Sender).expect("connect");
    let sent = r.try_send(b"test").expect("try_send");
    assert!(!sent);
}

// Port of RouteTest.TryRecvEmpty
#[test]
fn route_try_recv_empty() {
    let name = unique_name("route_try_recv_empty");
    Route::clear_storage(&name);

    let mut r = Route::connect(&name, Mode::Receiver).expect("connect");
    let buf = r.try_recv().expect("try_recv");
    assert!(buf.is_empty());
}

// Port of RouteTest.RecvCount
#[test]
fn route_recv_count() {
    let name = unique_name("route_recv_count");
    Route::clear_storage(&name);

    let sender = Route::connect(&name, Mode::Sender).expect("sender");
    assert_eq!(sender.recv_count(), 0);

    let _recv = Route::connect(&name, Mode::Receiver).expect("receiver");
    assert_eq!(sender.recv_count(), 1);
}

// Port of RouteTest.SendReceiveBuffer
#[test]
fn route_send_recv_buffer() {
    let name = unique_name("route_send_recv_buf");
    Route::clear_storage(&name);

    let name2 = name.clone();
    let sent_flag = Arc::new(AtomicBool::new(false));
    let sent_flag2 = Arc::clone(&sent_flag);

    let sender = thread::spawn(move || {
        let mut s = Route::connect(&name2, Mode::Sender).expect("sender");
        // Wait for receiver to connect
        s.wait_for_recv(1, Some(1000)).expect("wait");
        let ok = s.send(b"Hello Route", 1000).expect("send");
        sent_flag2.store(ok, Ordering::SeqCst);
    });

    let mut r = Route::connect(&name, Mode::Receiver).expect("receiver");
    let buf = r.recv(Some(2000)).expect("recv");

    sender.join().unwrap();

    assert!(sent_flag.load(Ordering::SeqCst));
    assert_eq!(buf.data(), b"Hello Route");
}

// Port of RouteTest.SendReceiveString
#[test]
fn route_send_recv_string() {
    let name = unique_name("route_send_recv_str");
    Route::clear_storage(&name);

    let name2 = name.clone();
    let sender = thread::spawn(move || {
        let mut s = Route::connect(&name2, Mode::Sender).expect("sender");
        s.wait_for_recv(1, Some(1000)).expect("wait");
        s.send_str("Test String", 1000).expect("send");
    });

    let mut r = Route::connect(&name, Mode::Receiver).expect("receiver");
    let buf = r.recv(Some(2000)).expect("recv");

    sender.join().unwrap();

    // IpcBuffer::from_str adds a null terminator
    assert_eq!(&buf.data()[..11], b"Test String");
}

// Port of RouteTest.SendReceiveRawData
#[test]
fn route_send_recv_raw() {
    let name = unique_name("route_send_recv_raw");
    Route::clear_storage(&name);

    let data = b"Raw Data Test";
    let name2 = name.clone();
    let sender = thread::spawn(move || {
        let mut s = Route::connect(&name2, Mode::Sender).expect("sender");
        s.wait_for_recv(1, Some(1000)).expect("wait");
        s.send(data, 1000).expect("send");
    });

    let mut r = Route::connect(&name, Mode::Receiver).expect("receiver");
    let buf = r.recv(Some(2000)).expect("recv");

    sender.join().unwrap();

    assert_eq!(buf.data(), b"Raw Data Test");
}

// Port of RouteTest.WaitForRecv
#[test]
fn route_wait_for_recv() {
    let name = unique_name("route_wait_recv");
    Route::clear_storage(&name);

    let sender = Route::connect(&name, Mode::Sender).expect("sender");

    let name2 = name.clone();
    let receiver_thread = thread::spawn(move || {
        thread::sleep(Duration::from_millis(50));
        let _r = Route::connect(&name2, Mode::Receiver).expect("receiver");
        thread::sleep(Duration::from_millis(200)); // keep alive
    });

    let waited = sender.wait_for_recv(1, Some(500)).expect("wait");
    assert!(waited);

    receiver_thread.join().unwrap();
}

// Port of RouteTest.OneSenderMultipleReceivers
#[test]
fn route_one_sender_multiple_receivers() {
    let name = unique_name("route_1_to_n");
    Route::clear_storage(&name);

    let num_receivers = 3;
    let received: Vec<Arc<AtomicBool>> = (0..num_receivers)
        .map(|_| Arc::new(AtomicBool::new(false)))
        .collect();

    let mut handles = Vec::new();
    for i in 0..num_receivers {
        let n = name.clone();
        let flag = Arc::clone(&received[i]);
        handles.push(thread::spawn(move || {
            let mut r = Route::connect(&n, Mode::Receiver).expect("receiver");
            let buf = r.recv(Some(2000)).expect("recv");
            if buf.data() == b"Broadcast" {
                flag.store(true, Ordering::SeqCst);
            }
        }));
    }

    // Wait for receivers to connect
    let mut sender = Route::connect(&name, Mode::Sender).expect("sender");
    sender
        .wait_for_recv(num_receivers, Some(1000))
        .expect("wait");

    sender.send(b"Broadcast", 1000).expect("send");

    for h in handles {
        h.join().unwrap();
    }

    for flag in &received {
        assert!(flag.load(Ordering::SeqCst));
    }
}

// ========== Channel Tests ==========

// Port of ChannelTest.ConstructionWithName
#[test]
fn channel_construction() {
    let name = unique_name("channel_ctor");
    Channel::clear_storage(&name);

    let ch = Channel::connect(&name, Mode::Sender).expect("connect");
    assert_eq!(ch.name(), name);
}

// Port of ChannelTest.ClearStorage
#[test]
fn channel_clear_storage() {
    let name = unique_name("channel_clear");
    Channel::clear_storage(&name);

    {
        let _ch = Channel::connect(&name, Mode::Sender).expect("connect");
    }

    Channel::clear_storage(&name);
}

// Port of ChannelTest.SendReceive
#[test]
fn channel_send_recv() {
    let name = unique_name("channel_send_recv");
    Channel::clear_storage(&name);

    let name2 = name.clone();
    let sender = thread::spawn(move || {
        let mut ch = Channel::connect(&name2, Mode::Sender).expect("sender");
        ch.wait_for_recv(1, Some(1000)).expect("wait");
        ch.send_str("Channel Test", 1000).expect("send");
    });

    let mut ch = Channel::connect(&name, Mode::Receiver).expect("receiver");
    let buf = ch.recv(Some(2000)).expect("recv");

    sender.join().unwrap();

    assert_eq!(&buf.data()[..12], b"Channel Test");
}

// Port of ChannelTest.MultipleSenders
#[test]
fn channel_multiple_senders() {
    let name = unique_name("channel_multi_send");
    Channel::clear_storage(&name);

    let num_senders = 3;
    let received_count = Arc::new(AtomicI32::new(0));

    let name_r = name.clone();
    let rc = Arc::clone(&received_count);
    let receiver = thread::spawn(move || {
        let mut ch = Channel::connect(&name_r, Mode::Receiver).expect("receiver");
        for _ in 0..num_senders {
            let buf = ch.recv(Some(2000)).expect("recv");
            if !buf.is_empty() {
                rc.fetch_add(1, Ordering::Relaxed);
            }
        }
    });

    // Wait a bit for receiver to connect
    thread::sleep(Duration::from_millis(50));

    let mut senders = Vec::new();
    for i in 0..num_senders {
        let n = name.clone();
        senders.push(thread::spawn(move || {
            let mut ch = Channel::connect(&n, Mode::Sender).expect("sender");
            ch.wait_for_recv(1, Some(1000)).expect("wait");
            let msg = format!("Sender{i}");
            ch.send(msg.as_bytes(), 1000).expect("send");
        }));
    }

    for s in senders {
        s.join().unwrap();
    }
    receiver.join().unwrap();

    assert_eq!(received_count.load(Ordering::Relaxed), num_senders as i32);
}

// Port of ChannelTest.MultipleSendersReceivers (broadcast)
#[test]
fn channel_multiple_senders_receivers() {
    let name = unique_name("channel_m_to_n");
    Channel::clear_storage(&name);

    let num_senders = 2usize;
    let num_receivers = 2usize;
    let messages_per_sender = 3usize;
    let total_messages = num_senders * messages_per_sender;

    let sent_count = Arc::new(AtomicI32::new(0));
    let received_count = Arc::new(AtomicI32::new(0));

    let mut receiver_handles = Vec::new();
    for _i in 0..num_receivers {
        let n = name.clone();
        let rc = Arc::clone(&received_count);
        receiver_handles.push(thread::spawn(move || {
            let mut ch = Channel::connect(&n, Mode::Receiver).expect("receiver");
            for _ in 0..total_messages {
                let buf = ch.recv(Some(3000)).expect("recv");
                if !buf.is_empty() {
                    rc.fetch_add(1, Ordering::Relaxed);
                }
            }
        }));
    }

    thread::sleep(Duration::from_millis(200));

    let mut sender_handles = Vec::new();
    for i in 0..num_senders {
        let n = name.clone();
        let sc = Arc::clone(&sent_count);
        sender_handles.push(thread::spawn(move || {
            let mut ch = Channel::connect(&n, Mode::Sender).expect("sender");
            ch.wait_for_recv(num_receivers, Some(2000)).expect("wait");
            for j in 0..messages_per_sender {
                let msg = format!("S{i}M{j}");
                if ch.send(msg.as_bytes(), 2000).expect("send") {
                    sc.fetch_add(1, Ordering::Relaxed);
                }
                thread::sleep(Duration::from_millis(20));
            }
        }));
    }

    for s in sender_handles {
        s.join().unwrap();
    }
    for r in receiver_handles {
        r.join().unwrap();
    }

    assert_eq!(sent_count.load(Ordering::Relaxed), total_messages as i32);
    assert_eq!(
        received_count.load(Ordering::Relaxed),
        (total_messages * num_receivers) as i32
    );
}

// Port of ChannelTest.TrySendTryRecv
#[test]
fn channel_try_send_try_recv() {
    let name = unique_name("channel_try");
    Channel::clear_storage(&name);

    let mut sender = Channel::connect(&name, Mode::Sender).expect("sender");
    let mut receiver = Channel::connect(&name, Mode::Receiver).expect("receiver");

    let sent = sender.send(b"Try Test", 100).expect("send");

    if sent {
        // Give a moment for the slot to be visible
        thread::sleep(Duration::from_millis(10));
        let buf = receiver.try_recv().expect("try_recv");
        assert!(!buf.is_empty());
        assert_eq!(buf.data(), b"Try Test");
    }
}

// Port of ChannelTest.SendTimeout
#[test]
fn channel_send_timeout() {
    let name = unique_name("channel_timeout");
    Channel::clear_storage(&name);

    let mut ch = Channel::connect(&name, Mode::Sender).expect("sender");
    // Send with very short timeout (no receiver)
    let sent = ch.send(b"Timeout Test", 1).expect("send");
    assert!(!sent);
}

// Test large message fragmentation (>64 bytes spans multiple slots)
#[test]
fn route_large_message() {
    let name = unique_name("route_large_msg");
    Route::clear_storage(&name);

    let name2 = name.clone();
    // Create a message larger than DATA_LENGTH (64 bytes)
    let data: Vec<u8> = (0..200).map(|i| (i % 256) as u8).collect();
    let data2 = data.clone();

    let sender = thread::spawn(move || {
        let mut s = Route::connect(&name2, Mode::Sender).expect("sender");
        s.wait_for_recv(1, Some(1000)).expect("wait");
        s.send(&data2, 2000).expect("send");
    });

    let mut r = Route::connect(&name, Mode::Receiver).expect("receiver");
    let buf = r.recv(Some(3000)).expect("recv");

    sender.join().unwrap();

    assert_eq!(buf.data(), &data[..]);
}

// Test multiple sequential messages
#[test]
fn route_multiple_messages() {
    let name = unique_name("route_multi_msg");
    Route::clear_storage(&name);

    let count = 10;
    let name2 = name.clone();

    let sender = thread::spawn(move || {
        let mut s = Route::connect(&name2, Mode::Sender).expect("sender");
        s.wait_for_recv(1, Some(1000)).expect("wait");
        for i in 0..count {
            let msg = format!("msg_{i}");
            s.send(msg.as_bytes(), 1000).expect("send");
            thread::sleep(Duration::from_millis(5));
        }
    });

    let mut r = Route::connect(&name, Mode::Receiver).expect("receiver");
    let mut received = Vec::new();
    for _ in 0..count {
        let buf = r.recv(Some(2000)).expect("recv");
        received.push(buf);
    }

    sender.join().unwrap();

    for (i, buf) in received.iter().enumerate() {
        let expected = format!("msg_{i}");
        assert_eq!(buf.data(), expected.as_bytes(), "message {i} mismatch");
    }
}

// Test IpcBuffer conversions
#[test]
fn buffer_send_recv() {
    let name = unique_name("buf_send_recv");
    Route::clear_storage(&name);

    let original = IpcBuffer::from_str("Buffer message");

    let name2 = name.clone();
    let orig2 = original.clone();
    let sender = thread::spawn(move || {
        let mut s = Route::connect(&name2, Mode::Sender).expect("sender");
        s.wait_for_recv(1, Some(1000)).expect("wait");
        s.send_buf(&orig2, 1000).expect("send");
    });

    let mut r = Route::connect(&name, Mode::Receiver).expect("receiver");
    let buf = r.recv(Some(2000)).expect("recv");

    sender.join().unwrap();

    assert_eq!(buf, original);
}
