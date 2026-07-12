# Cross-platform parity: what's missing off macOS, and how to close it

**macOS (Apple arm64) is the reference platform.** Everything built in the async
/ reaper work — the byte-exact wire ABI, Layer-1 notify, Layer-2 async (C++
stdexec **and** coroutines, Rust, Swift), and the dead-connection reaper — is
implemented and **matrix-verified** on macOS across C++/Rust/Swift. Linux is
close; Windows has none of the new async/notify/reaper layers; FreeBSD is
untested. Swift is a macOS-only SPM package and is out of scope elsewhere.

## Status matrix

Legend: ✅ done + CI-verified · 🟡 works but not byte-exact / not verified ·
◐ stub (safe no-op) · ❌ not implemented · — n/a.

| Capability | macOS | Linux | Windows |
|---|---|---|---|
| Wire ABI ring/msg_t (C++↔C++) | ✅ | ✅ | ✅ |
| Wire ABI **byte-exact** C++↔Rust (ring offsets + message interop) | ✅ | 🟡¹ | ❌² |
| Byte-exact **spin_lock** (`lc_`@4) / chunk `lock_`@36 in the ports | ✅ | 🟡¹ | ❌² |
| Chunk storage (>64B) C++↔Rust | ✅ | 🟡¹ | ❌² |
| Layer-1 notify (source+sink) — C++ | ✅ libnotify | ✅ FIFO | ❌³ |
| Layer-1 notify — Rust | ✅ | ✅ FIFO | ❌⁴ |
| Layer-1 notify — Swift | ✅ | — | — |
| Reactor (kqueue/epoll) — C++ | ✅ | ✅ | ❌⁵ |
| Async recv — C++ stdexec `async_recv` + coroutines | ✅ | ✅ | ❌⁵ |
| Async recv — Rust `AsyncRoute` (tokio `AsyncFd`) | ✅ | ✅ | ❌⁴ |
| Async recv — Swift `AsyncRoute` (`DispatchSource`) | ✅ | — | — |
| Dead-connection reaper (PID-liveness + start-token) | ✅ | ✅ | ◐ stub⁶ |
| xlang CI matrix (sync / async / reap) | ✅ full 3-lang + coro | ✅ C++↔Rust | ❌ none |

Footnotes / code pointers:
1. **Linux ports:** ring offsets already match (the `lc_`@4 and chunk `lock_`@36
   are both 4-byte on every target), so **message interop works** and is run in
   CI (`matrix-linux`). But Rust replaces the platform lock with a `[u8; 4]`
   placeholder that does **not** run C++'s init/spin protocol
   (`rust/libipc/src/channel.rs:139`, `chunk_storage.rs:55`;
   `init_header`/`chunk_lock` are Apple-gated). C++'s Linux `spin_lock` is a
   trivial `std::atomic<uint32_t>` exchange-spin (`rw_lock.h:117`), so this is a
   **small** fix, not a redesign. Until then the DCLP first-init critical section
   isn't mutually exclusive cross-language (a narrow, benign-in-practice race
   guarded by `constructed_`), and chunk storage is Apple-only in Rust.
2. **Windows ports:** the C++ Windows `spin_lock` differs again and the ports are
   not aligned; Windows is not in the xlang matrix at all.
3. C++ notify is a hard `#error` on Windows (`notify.h:36`).
4. Rust `notify` / `async-tokio` features are unix-only (`notify.rs` backends are
   apple/unix; `async_recv.rs` uses `tokio::io::unix::AsyncFd`) — they do not
   compile on Windows.
5. `reactor.cpp` has kqueue (Apple) / epoll (else) only; gated on
   `LIBIPC_NOTIFY_FD`, which errors on Windows. No Windows reactor.
6. `is_process_alive` returns `true` and `start_token` returns `0` on Windows
   (`liveness.h:96,146`; Rust `liveness.rs` `#[cfg(not(unix))]`). **Safe** — a
   phantom is never falsely reaped — but nothing is ever reclaimed.

## How to reestablish parity

### Linux — small, do first
1. **Byte-exact spin locks.** Replace the Rust `[u8; 4]` placeholders at
   `RingHeader.lc`@4 and `ChunkInfo.lock_`@36 with an `AtomicU32` and run the same
   exchange-spin as C++'s generic `spin_lock` (`lock: while swap(1)!=0 spin;
   unlock: store(0)`) in `init_header` and the chunk lock on non-Apple. Purely
   mechanical (C++'s Linux lock is already a plain atomic-u32 spin).
2. **Prove it.** The message matrix already runs on Linux; add a Linux job (or
   assertion) that exercises **chunk storage** (>64B) C++↔Rust and a concurrent
   first-init stress, so the `lc_`/`lock_` bytes are verified, not just assumed.
   After this, Linux C++↔Rust is fully byte-exact; notify (FIFO), async (epoll +
   tokio `AsyncFd`), and the reaper (`kill(pid,0)` + `/proc/<pid>/stat`) already
   work and are CI-covered.

### Windows — the real gap, in three layers
1. **Liveness (reaper) — smallest, highest safety value.** Implement
   `is_process_alive` via `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` +
   `GetExitCodeProcess` (`STILL_ACTIVE`), and `start_token` via `GetProcessTimes`
   creation time packed into the same u64 as the POSIX formula. In C++
   (`liveness.h`) and Rust (`liveness.rs`). The owner-table ABI is already
   platform-neutral; only these two functions are stubbed.
2. **Notify (Layer 1).** A Windows backend using a named `CreateEventW`
   (manual-reset) per channel: `native_wait_handle()` returns the `HANDLE`;
   `signal` = `SetEvent`; the sink waits on it. Multicast is one named event per
   channel (all readers wait the same handle). Add to C++ `notify.h` (remove the
   `#error`) and a Rust Windows backend in `notify.rs`.
3. **Reactor + async (Layer 2).** A Windows reactor over
   `RegisterWaitForSingleObject` / `WaitForMultipleObjects` (or IOCP) in
   `reactor.cpp`; then C++ stdexec `async_recv` and both coroutine paths work
   unchanged (they only need the reactor + a wait handle). For Rust, drive the
   event `HANDLE` with tokio's Windows facilities (or a small wait-thread that
   wakes a `Waker`) instead of `AsyncFd`. Gate the Rust `notify`/`async-tokio`
   features to compile on Windows.
4. **CI.** Add a Windows xlang job (sync + async + reap) once 1–3 land; and align
   the ring/chunk `spin_lock` bytes on Windows as in the Linux step.

### FreeBSD / other POSIX
Likely close (FIFO notify, kqueue reactor, and `kill(pid,0)` are BSD-native), but
`start_token` needs a BSD source (`kinfo_proc` / `sysctl KERN_PROC_PID`) and shm
names/`AlignSize` need per-target checks. Validate by adding the target to the
byte-exact asserts + a CI run before claiming parity.

## Suggested order
1. **Linux spin_lock byte-exactness** (small; makes Linux C++↔Rust fully
   byte-exact incl. chunk storage).
2. **Windows liveness** (small–medium; the reaper becomes functional on Windows —
   currently safe but inert).
3. **Windows notify + reactor + async** (large; the substantive Windows work).
4. **FreeBSD validation** (medium; mostly `start_token` + CI).
