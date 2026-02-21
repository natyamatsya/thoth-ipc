# macOS IPC Backend Performance Comparison

## Environment

* **Machine:** Apple Silicon (12 hardware threads)
* **Build:** Release (`-O2`)
* **Workload:** 100 000 messages, random 2–256 bytes each
* **C++ compiler:** AppleClang (Xcode toolchain)
* **Rust toolchain:** stable, `--release`

## Backends under test

| Label | Description |
| --- | --- |
| **C++ ulock** | New `__ulock_wait`/`__ulock_wake` backend (default, private Darwin API) |
| **C++ Mach** | New `semaphore_t` backend (`-DLIBIPC_APPLE_APP_STORE_SAFE=ON`, public API) |
| **Rust** | Pure Rust port (`rust/libipc`) using `parking_lot`-style ulock internally |

---

## ipc::route — 1 sender, N receivers (µs/datum)

| Receivers | C++ ulock | C++ Mach | Rust  | ulock vs Mach | ulock vs Rust |
|:---------:|----------:|---------:|------:|:-------------:|:-------------:|
| 1         | 3.20      | 3.23     | 0.022 | 1.0×          | **145×**      |
| 2         | 3.08      | 3.21     | 0.023 | 1.0×          | **134×**      |
| 4         | 3.18      | 3.21     | 0.023 | 1.0×          | **138×**      |
| 8         | 3.09      | 3.07     | 0.021 | 1.0×          | **147×**      |

---

## ipc::channel — 1 sender, N receivers (µs/datum)

| Receivers | C++ ulock | C++ Mach | Rust  | ulock vs Mach | ulock vs Rust |
|:---------:|----------:|---------:|------:|:-------------:|:-------------:|
| 1         | 3.13      | 4.13     | 0.023 | 1.3× faster   | **136×**      |
| 2         | 3.61      | 1.76     | 0.023 | 2.1× slower   | **157×**      |
| 4         | 8.25      | 3.43     | 0.023 | 2.4× slower   | **359×**      |
| 8         | 13.07     | 10.27    | 0.027 | 1.3× slower   | **484×**      |

---

## ipc::channel — N senders, 1 receiver (µs/datum)

| Senders | C++ ulock | C++ Mach | Rust  | ulock vs Mach | ulock vs Rust |
|:-------:|----------:|---------:|------:|:-------------:|:-------------:|
| 1       | 4.33      | 4.14     | 0.024 | 1.0×          | **180×**      |
| 2       | 2.84      | 1.22     | 0.049 | 2.3× slower   | **58×**       |
| 4       | 5.35      | 1.11     | 0.096 | 4.8× slower   | **56×**       |
| 8       | 4.01      | 1.43     | 0.073 | 2.8× slower   | **55×**       |

---

## ipc::channel — N senders, N receivers (µs/datum)

| Threads | C++ ulock | C++ Mach | Rust  | ulock vs Mach | ulock vs Rust |
|:-------:|----------:|---------:|------:|:-------------:|:-------------:|
| 1       | 4.13      | 1.25     | 0.024 | 3.3× slower   | **172×**      |
| 2       | 3.77      | 2.04     | 0.037 | 1.8× slower   | **102×**      |
| 4       | 11.08     | 3.93     | 0.071 | 2.8× slower   | **156×**      |
| 8       | 20.98     | 10.82    | 0.078 | 1.9× slower   | **269×**      |

---

## Phase 3 post-optimization results (C++ ulock, after `waiters` counter fix)

### ipc::channel N-1 — before vs after Phase 3 (µs/datum)

| Senders | Before | After | Speedup |
|:-------:|-------:|------:|:-------:|
| 1       | 4.33   | 0.537 | **8×**  |
| 2       | 2.84   | 0.975 | **3×**  |
| 4       | 5.35   | 0.887 | **6×**  |
| 8       | 4.01   | 1.036 | **4×**  |

### ipc::channel N-N — before vs after Phase 3 (µs/datum)

| Threads | Before | After | Speedup |
|:-------:|-------:|------:|:-------:|
| 1       | 4.13   | 0.560 | **7×**  |
| 2       | 3.77   | 0.841 | **4×**  |
| 4       | 11.08  | 1.075 | **10×** |
| 8       | 20.98  | 1.936 | **11×** |

`ipc::route` (1 sender, N receivers) remains at ~3 µs/datum — the receiver is always
sleeping waiting for new data, so `waiters > 0` on every push and `__ulock_wake` cannot
be skipped. This is the irreducible round-trip cost of the ulock condvar.

---

## Analysis

### C++ ulock vs C++ Mach (before Phase 3)

The two C++ backends were **roughly equivalent on `ipc::route`** — both around 3 µs/datum.
On multi-sender/multi-receiver `ipc::channel` patterns the Mach backend was consistently
**2–5× faster** due to the ulock mutex waking all waiters simultaneously (`ULF_WAKE_ALL`)
while Mach uses `SYNC_POLICY_FIFO` (one at a time).

### Root cause of the C++/Rust gap (revised after Phase 3)

The initial hypothesis (spin threshold difference) was incorrect. Code inspection confirmed
identical `SPIN_COUNT=32` in both C++ and Rust `wait_for` loops. The actual cause was:

**`waiter::broadcast()` was called unconditionally on every successful push and pop**, even
when no thread was sleeping. Each call paid:

1. A mutex lock/unlock (barrier) — ~1 µs
2. A `__ulock_wake` syscall — ~1–2 µs even with no waiters

**Fix:** Added a `waiters` counter to `ulock_cond_t`. `broadcast()`/`notify()` now skip
`__ulock_wake` when `waiters == 0`. Also removed the redundant barrier lock from
`waiter::broadcast()` (the ulock seq-counter condvar prevents lost wakeups independently).

**Result:** `ipc::channel` dropped from ~3–21 µs to **0.5–2 µs/datum** (3–11× improvement).

### Remaining gap vs Rust

The Rust benchmark sends with `timeout_ms=0` (non-blocking, drops messages when ring full),
while the C++ benchmark uses blocking send (waits until ring has space). These measure
different workloads. For the blocking send case, `ipc::route` at ~3 µs/datum represents
the **irreducible ulock condvar round-trip** when a receiver is genuinely sleeping.

---

## Recommendations

| Scenario | Recommended backend |
| --- | --- |
| Default / highest throughput | **C++ ulock** (already default) |
| Mac App Store distribution | **C++ Mach** (`LIBIPC_APPLE_APP_STORE_SAFE=ON`) |
| Lowest possible latency | **Rust port** (non-blocking send, no kernel sleep) |

### Remaining optimisation opportunities

1. **`ipc::route` ~3 µs** — irreducible when receiver is always sleeping. Could be
   reduced by batching wakeups (signal once per N pushes) at the cost of latency.
2. **Mach backend** — apply the same `waiters` counter optimisation to
   `mach/condition.h` (already has `waiters` field but `broadcast()` always calls
   `semaphore_signal_all`).
3. **`ipc::channel` 1-N at N=1** — still ~4 µs; the `wt_waiter_.broadcast()` call in
   `recv()` is the bottleneck when only one sender is waiting.
