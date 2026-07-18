// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Cross-language bounded buffer — the classic producer/consumer problem solved
// with the byte-exact named IPC primitives.
//
// Usage (run the consumer first, then one or more producers):
//   demo_bounded_buffer consume <total>
//   demo_bounded_buffer produce <id> <count>
//
// A fixed-capacity ring lives in a shared-memory segment; access is coordinated
// by a named `IpcMutex` (so multiple producers can contend for `head`) and two
// counting `IpcSemaphore`s — `empty` (free slots, starts at CAP) and `full`
// (filled slots, starts at 0). Producers and the consumer can be *different
// languages*: the shm layout, the mutex and both semaphores are byte-exact
// across the C++, Rust, Swift and Zig ports. (This is the classic case where a
// mutex is genuinely required — several producers mutate the same `head`.)

use std::collections::BTreeMap;

use libipc::{IpcMutex, IpcSemaphore, ShmHandle, ShmOpenMode};

const SHM: &str = "__BBUF__";
const MUTEX: &str = "bbuf_m";
const EMPTY: &str = "bbuf_e";
const FULL: &str = "bbuf_f";
const CAP: u32 = 4; // ring capacity — small, so the semaphores actually block
const SLOT: usize = 48; // fixed bytes per slot
const SHM_SIZE: usize = 8 + CAP as usize * SLOT; // head(u32) + tail(u32) + slots

/// The shared ring: `head`(u32)@0, `tail`(u32)@4, then CAP × SLOT bytes @8.
struct Ring {
    shm: ShmHandle,
}
impl Ring {
    fn open() -> Self {
        let shm = ShmHandle::acquire(SHM, SHM_SIZE, ShmOpenMode::CreateOrOpen).expect("shm");
        if shm.ref_count() <= 1 {
            // First opener zeroes the cursors (byte-exact with a fresh segment).
            unsafe {
                (shm.get() as *mut u32).write_volatile(0);
                (shm.get().add(4) as *mut u32).write_volatile(0);
            }
        }
        Self { shm }
    }
    fn head(&self) -> u32 { unsafe { (self.shm.get() as *const u32).read_volatile() } }
    fn tail(&self) -> u32 { unsafe { (self.shm.get().add(4) as *const u32).read_volatile() } }
    fn set_head(&self, v: u32) { unsafe { (self.shm.get() as *mut u32).write_volatile(v) } }
    fn set_tail(&self, v: u32) { unsafe { (self.shm.get().add(4) as *mut u32).write_volatile(v) } }
    fn slot(&self, idx: u32) -> *mut u8 { unsafe { self.shm.get().add(8 + idx as usize * SLOT) } }
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    match a.get(1).map(String::as_str) {
        Some("consume") if a.len() >= 3 => consume(a[2].parse().unwrap_or(0)),
        Some("produce") if a.len() >= 4 => produce(&a[2], a[3].parse().unwrap_or(0)),
        _ => {
            eprintln!(
                "usage:\n  demo_bounded_buffer consume <total>\n  \
                 demo_bounded_buffer produce <id> <count>"
            );
            std::process::exit(1);
        }
    }
}

fn produce(id: &str, count: usize) {
    let ring = Ring::open();
    let mutex = IpcMutex::open(MUTEX).expect("mutex");
    let empty = IpcSemaphore::open(EMPTY, CAP).expect("empty sem");
    let full = IpcSemaphore::open(FULL, 0).expect("full sem");

    for k in 0..count {
        if !empty.wait(Some(10_000)).unwrap_or(false) {
            eprintln!("[producer {id}] no free slot within 10s (consumer gone?)");
            std::process::exit(2);
        }
        mutex.lock().expect("lock");
        let idx = ring.head();
        ring.set_head((idx + 1) % CAP);
        let msg = format!("{id} #{k}");
        let b = msg.as_bytes();
        let n = b.len().min(SLOT - 1);
        unsafe {
            std::ptr::copy_nonoverlapping(b.as_ptr(), ring.slot(idx), n);
            *ring.slot(idx).add(n) = 0;
        }
        mutex.unlock().expect("unlock");
        full.post(1).expect("full.post");
    }
    eprintln!("[producer {id}] produced {count} items");
}

fn consume(total: usize) {
    let ring = Ring::open();
    let mutex = IpcMutex::open(MUTEX).expect("mutex");
    let empty = IpcSemaphore::open(EMPTY, CAP).expect("empty sem");
    let full = IpcSemaphore::open(FULL, 0).expect("full sem");
    println!("[consumer] ready — draining {total} items through a {CAP}-slot ring");

    let mut tally: BTreeMap<String, usize> = BTreeMap::new();
    for i in 0..total {
        if !full.wait(Some(10_000)).unwrap_or(false) {
            eprintln!("[consumer] no item within 10s after {i}/{total}");
            break;
        }
        mutex.lock().expect("lock");
        let idx = ring.tail();
        ring.set_tail((idx + 1) % CAP);
        let msg = unsafe {
            let p = ring.slot(idx);
            let mut len = 0;
            while len < SLOT && *p.add(len) != 0 { len += 1; }
            String::from_utf8_lossy(std::slice::from_raw_parts(p, len)).to_string()
        };
        mutex.unlock().expect("unlock");
        empty.post(1).expect("empty.post"); // free the slot
        let producer = msg.split(" #").next().unwrap_or("?").to_string();
        *tally.entry(producer).or_default() += 1;
        println!("[consumer] {:>3}/{total}  {msg}", i + 1);
    }

    println!("\n[consumer] summary — {} items from {} producer(s):", tally.values().sum::<usize>(), tally.len());
    for (p, n) in &tally {
        println!("    {p:<12} {n}");
    }
}
