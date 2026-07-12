// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// In-process test for the Layer-2 async receive API (`async-tokio` feature): a
// blocking sender (with the notify source) wakes an `AsyncRoute::recv().await`
// via the readiness fd. Cross-language wakeup is covered by the xlang matrix.
#![cfg(all(unix, feature = "async-tokio"))]

use std::time::Duration;

use libipc::async_recv::AsyncRoute;
use libipc::channel::{Mode, Route};

#[test]
fn async_route_wakes_on_notified_send() {
    let name = format!("rust_async_notify_{}", std::process::id());
    Route::clear_storage(&name);

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");

    rt.block_on(async {
        // Receiver first so the sender's wait_for_recv succeeds.
        let mut ar = AsyncRoute::connect(&name).expect("async connect");
        assert!(ar.route().native_wait_handle() >= 0, "expected a readiness fd");

        let sender_name = name.clone();
        let sender = std::thread::spawn(move || {
            let mut w = Route::connect(&sender_name, Mode::Sender).expect("sender connect");
            assert!(w.wait_for_recv(1, Some(2000)).expect("wait_for_recv"));
            for i in 0..5u8 {
                let msg = vec![b'A' + i; 100]; // >64B → exercises chunk storage too
                assert!(w.send(&msg, 2000).expect("send"));
            }
        });

        for i in 0..5u8 {
            let buf = tokio::time::timeout(Duration::from_secs(5), ar.recv())
                .await
                .expect("recv timed out — notify wakeup regressed")
                .expect("recv error");
            assert_eq!(buf.len(), 100);
            assert!(buf.data().iter().all(|&b| b == b'A' + i));
        }

        sender.join().unwrap();
    });

    Route::clear_storage(&name);
}
