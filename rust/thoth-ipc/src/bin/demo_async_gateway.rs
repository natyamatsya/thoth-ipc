// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Async receive demo: a device gateway multiplexing many channels in ONE
// event loop.
//
// Domain: supervisors, gateways and GUI apps cannot afford a blocking recv
// thread per channel. A gateway bridging N device agents to the network
// already lives on an async runtime (tokio, kqueue/epoll, a runloop) — at
// tens or hundreds of channels, thread-per-channel is a non-starter, and a
// runtime CANNOT host a blocking recv without burning a worker thread per
// channel. The Layer-1 notify readiness fd + `AsyncRoute::recv().await`
// integrate each channel into the existing loop: a single thread awaits all
// devices at once, alongside timers and sockets. Any language's sender wakes
// it — the notify protocol is byte-exact across C++/Rust/Swift (see the
// xlang matrix's async scenario).
//
// Usage:
//   demo_async_gateway demo [devices] [readings]   one-command demo (spawns agents)
//   demo_async_gateway gateway <devices> <readings>  the multiplexing event loop
//   demo_async_gateway agent <id> <readings>       one device agent (own process)
//
// Build with:
//   cargo build --features async-tokio --bin demo_async_gateway

use std::process::exit;
use std::time::Duration;

use thoth_ipc::async_recv::AsyncRoute;
use thoth_ipc::channel::{Mode, Route};

fn chan(id: usize) -> String {
    format!("gw-dev-{id}")
}

/// One device agent: an ordinary blocking sender in its own process. The
/// `notify` feature (implied by async-tokio) makes every send also post the
/// readiness signal that wakes the gateway's event loop.
fn agent(id: usize, readings: usize) -> i32 {
    let mut tx = Route::connect(&chan(id), Mode::Sender).expect("connect");
    if !matches!(tx.wait_for_recv(1, Some(10_000)), Ok(true)) {
        eprintln!("[agent {id}] gateway never subscribed");
        return 1;
    }
    for n in 0..readings {
        // A fake sensor reading; the payload format is the demo's, not the library's.
        let value = 20.0 + (id as f64) + (n as f64) * 0.1;
        let msg = format!("dev-{id} reading {n} temp {value:.1}C");
        tx.send(msg.as_bytes(), 5000).expect("send");
        std::thread::sleep(Duration::from_millis(150 + (id as u64 % 3) * 70));
    }
    0
}

/// The gateway: one current-thread tokio runtime, one task per device
/// channel, all awaiting concurrently — plus a stats timer sharing the same
/// loop, exactly like the network I/O would in a real bridge.
fn gateway(devices: usize, per_device: usize) -> i32 {
    let total = devices * per_device;
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_io()
        .enable_time()
        .build()
        .expect("tokio runtime");
    let local = tokio::task::LocalSet::new();
    let received = std::rc::Rc::new(std::cell::Cell::new(0usize));

    rt.block_on(local.run_until(async move {
        let mut tasks = Vec::new();
        for id in 0..devices {
            let received = received.clone();
            tasks.push(tokio::task::spawn_local(async move {
                let mut rx = match AsyncRoute::connect(&chan(id)) {
                    Ok(rx) => rx,
                    Err(e) => {
                        eprintln!("[gateway] connect dev-{id} failed: {e}");
                        return;
                    }
                };
                // Each device sends a known number of readings; a real
                // gateway would run this loop forever.
                for _ in 0..per_device {
                    match rx.recv().await {
                        Ok(buf) if !buf.is_empty() => {
                            println!("[gateway] {}", String::from_utf8_lossy(buf.data()));
                            received.set(received.get() + 1);
                        }
                        _ => break,
                    }
                }
            }));
        }

        // The same loop keeps servicing other work while every channel is
        // parked — this is the point of the readiness integration.
        let stats = {
            let received = received.clone();
            tokio::task::spawn_local(async move {
                let mut tick = tokio::time::interval(Duration::from_millis(500));
                loop {
                    tick.tick().await;
                    println!("[gateway] -- stats: {}/{total} readings --", received.get());
                    if received.get() >= total {
                        break;
                    }
                }
            })
        };

        for t in tasks {
            let _ = t.await;
        }
        let _ = stats.await;
        println!(
            "[gateway] done: {} readings from {devices} devices on ONE thread.",
            received.get()
        );
    }));
    0
}

/// Convenience: spawn the agents as child processes, then run the gateway.
fn demo(devices: usize, readings: usize) -> i32 {
    for id in 0..devices {
        Route::clear_storage(&chan(id));
    }
    let exe = std::env::current_exe().expect("current_exe");
    let children: Vec<_> = (0..devices)
        .map(|id| {
            std::process::Command::new(&exe)
                .args(["agent", &id.to_string(), &readings.to_string()])
                .spawn()
                .expect("spawn agent")
        })
        .collect();
    let code = gateway(devices, readings);
    for mut c in children {
        let _ = c.wait();
    }
    for id in 0..devices {
        Route::clear_storage(&chan(id));
    }
    code
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let arg = |i: usize, default: usize| args.get(i).and_then(|s| s.parse().ok()).unwrap_or(default);
    let code = match args.get(1).map(String::as_str) {
        Some("demo") => demo(arg(2, 4), arg(3, 10)),
        Some("gateway") => gateway(arg(2, 4), arg(3, 10)),
        Some("agent") => agent(arg(2, 0), arg(3, 10)),
        _ => {
            eprintln!("usage: demo_async_gateway <demo|gateway|agent> [args]");
            2
        }
    };
    exit(code);
}
