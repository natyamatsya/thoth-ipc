# thoth-ipc — Cross-Language IPC Library

[![License: Apache-2.0-LLVM OR MIT](https://img.shields.io/badge/license-Apache--2.0--LLVM%20OR%20MIT-blue.svg)](#license)
[![Build Status](https://github.com/natyamatsya/thoth-ipc/actions/workflows/c-cpp.yml/badge.svg)](https://github.com/natyamatsya/thoth-ipc/actions)
[![Cross-language ABI](https://github.com/natyamatsya/thoth-ipc/actions/workflows/xlang.yml/badge.svg)](https://github.com/natyamatsya/thoth-ipc/actions/workflows/xlang.yml)

A high-performance inter-process communication library using shared memory on Linux/Windows/macOS/FreeBSD.
Binary-compatible primitives implemented in multiple languages — all sharing the same wire format and shm layout.

Four independent implementations — **C++, Rust, Swift and Zig** — are
**byte-exact** on the `ipc::route` wire ABI
([`context/xlang-channel-abi.md`](context/xlang-channel-abi.md)). A CI matrix
framework ([`tools/xlang-runner`](tools/xlang-runner)) runs every writer→reader
language pairing to prove a message sent by any language is received
byte-for-byte by any other — across blocking round-trips (fragment and
chunk-storage boundaries, 40 B – 64 KB), broadcast fan-out to mixed-language
readers, async notify wakeup, dead-connection reaping, sync primitives
(mutex/condition/semaphore), the typed codec layer, and **encrypted channels**:
AEAD envelopes (AES-256-GCM, ChaCha20-Poly1305) sealed by one language open in
every other, with tampered, wrong-key, wrong-key-id or algorithm-mismatched
envelopes rejected fail-closed. (Zig is macOS-first; on Linux and Windows the
matrix pairs C++ and Rust.) Known parity gaps the matrix has uncovered
(multi-writer `ipc::channel`, C++↔port semaphores) run as tracked
expected-failures — see
[`tools/xlang-runner/README.md`](tools/xlang-runner/README.md#known-gaps-expected-fail).

**Dead-connection reaping.** A `SIGKILL`ed broadcast receiver used to leave a
phantom `cc_` bit that stalled the ring, exhausted the 32 connection slots, and
inflated `recv_count`. Each receiver now records `{pid, start_token}` in a
per-channel `LV_CONN__` owner table, and any participant reaps slots whose owner
process has died (PID-liveness + a start token that defeats PID reuse). The table
and token formula are byte-exact across C++/Rust/Swift/Zig, so a reaper of any
language reclaims a dead receiver of any other and never false-reaps a live one.
See [`context/dead-connection-reaper-rfc.md`](context/dead-connection-reaper-rfc.md)
and ABI [§9](context/xlang-channel-abi.md).

> **Fork notice:** thoth-ipc is a fork of [cpp-ipc](https://github.com/mutouyun/cpp-ipc) by mutouyun,
> branched at upstream v1.4.1. thoth-ipc versioning starts independently at 0.1.0.
> Upstream cpp-ipc targeted Linux and Windows; macOS was not supported. This fork adds full
> macOS support to the C++ library, a pure Rust port, a Swift package, a native Zig port, a
> pluggable typed protocol layer (FlatBuffers/Cap'n Proto/Protobuf), an opt-in secure codec,
> and cross-language sync ABI alignment.

## Repository layout

```
cpp/libipc/    — C++ library (upstream core, extended; Linux/Windows/macOS/FreeBSD)
rust/libipc/   — Pure Rust port (Linux/Windows/macOS)
swift/libipc/  — Swift package (macOS 14+; byte-exact with C++/Rust/Zig)
zig/libipc/    — Native Zig port (macOS; byte-exact, every scenario but channel)
```

## Language implementations

### C++ — [`cpp/libipc/`](cpp/libipc/)

[![Build Status](https://github.com/natyamatsya/thoth-ipc/actions/workflows/c-cpp.yml/badge.svg)](https://github.com/natyamatsya/thoth-ipc/actions)

Based on the original [cpp-ipc](https://github.com/mutouyun/cpp-ipc) library. See [`cpp/libipc/README.md`](cpp/libipc/README.md) for full documentation.

- C++17 (msvc-2017/gcc-7/clang-4); built with C++23 in this repo
- No dependencies except STL for the core transport
- Lock-free or lightweight spin-lock only
- `ipc::route` (1 writer, N readers) and `ipc::channel` (N writers, N readers)
- Typed protocol layer: FlatBuffers, Cap'n Proto, Protocol Buffers (opt-in)
- Opt-in secure codec with AEAD envelope (OpenSSL EVP backend, zero overhead when disabled)
- Opt-in reactor-integrable async receive: a readiness handle (`native_wait_handle()`) and a stdexec `ipc::async_recv()` sender, so channels multiplex on one event loop instead of one blocking thread each — zero cost when off. See [`cpp/libipc/doc/async-recv.md`](cpp/libipc/doc/async-recv.md)

**macOS support** (not present in upstream cpp-ipc, added in this fork):

- `LIBIPC_OS_APPLE` platform branch added throughout sync, shm, and platform layers
- `shm_open` name hashing: macOS enforces `PSHMNAMLEN=31`; names are FNV-1a hashed when they exceed the limit (auto-enabled on Apple, zero-cost elsewhere)
- `ftruncate`/`fstat` quirks on already-sized shm objects handled correctly
- `pthread_mutex_timedlock` emulated (not available on macOS) with adaptive spin + sleep back-off
- `pthread_mutexattr_setrobust` emulated via PID-based dead-holder detection (`kill(pid, 0)`)
- `-lrt` excluded on Darwin (not present on macOS)
- `__ulock_wait`/`__ulock_wake` backend (default): word-lock mutex, seq-counter condvar, counting semaphore — equivalent to Linux futex, lowest latency
- Mach semaphore backend (`-DLIBIPC_APPLE_APP_STORE_SAFE=ON`): public-API-only alternative, App Store safe
- File-backed mmap fallback (`-DLIBIPC_USE_FILE_SHM=ON`): avoids `shm_open` entirely, sidesteps all `PSHMNAMLEN`/`ftruncate` quirks
- Universal binary CI: `arm64;x86_64` fat binary verified with `lipo`

### Rust — [`rust/libipc/`](rust/libipc/)

Pure Rust crate, binary-compatible with the C++ and Swift libraries.

- All primitives ported: shm, mutex, semaphore, condition, buffer, channel, waiter, circ
- Typed protocol layer: FlatBuffers (default), Cap'n Proto, Protocol Buffers (feature flags)
- Secure codec with AEAD envelope, OpenSSL EVP backend (feature-gated)
- Apple ulock sync ABI alignment with C++ and Swift
- Service registry, process manager, real-time audio demos
- **Async receive** (opt-in): a Layer-1 notify readiness fd (byte-exact with C++
  `LIBIPC_NOTIFY_FD`) + `AsyncRoute::recv().await` on tokio — a Rust `send()`
  wakes a C++ `async_recv` and vice versa

```sh
cd rust/libipc && cargo test
```

**Async receive** — enable the `async-tokio` feature (implies `notify`):

```rust
use libipc::async_recv::AsyncRoute;

let mut r = AsyncRoute::connect("st.agent.cmd")?; // receiver
loop {
    let msg = r.recv().await?;                     // woken by any-language sender
    // dispatch msg.data() ...
}
```

The sender side just needs the `notify` feature — every `Route::send` then posts
the readiness signal that wakes a C++/Rust async receiver. Runtime-agnostic users
can drive `native_wait_handle()` (a `RawFd`) on their own reactor instead of
tokio. See [`context/xlang-channel-abi.md`](context/xlang-channel-abi.md) §8 for
the byte-exact notify protocol, and the runnable
[`demo_async_gateway`](rust/libipc/src/bin/demo_async_gateway.rs) (one event
loop multiplexing many device channels).

### Swift — [`swift/libipc/`](swift/libipc/)

Swift Package Manager package targeting macOS 14+.

- Core transport (`Route`, `Channel`) binary-compatible with C++ and Rust
- Apple ulock sync primitives (`IpcMutex`, `IpcCondition`, `IpcSemaphore`) aligned with C++ and Rust ABI
- Typed protocol layer: FlatBuffers, Protocol Buffers
- Secure codec with AEAD envelope, optional OpenSSL EVP backend
- **Async receive**: `AsyncRoute.recv() async` over the Layer-1 readiness fd
  (`DispatchSource`), woken by a C++/Rust/Swift/Zig sender's notify
- Bench and demo executables included

```sh
cd swift/libipc && swift build
```

**Async receive** — a Swift `send()` posts the readiness notify, and
`AsyncRoute` awaits it on any Swift concurrency executor:

```swift
import LibIPC

let r = try await AsyncRoute.connect(name: "st.agent.cmd")   // receiver
while true {
    let msg = try await r.recv()                             // woken by any-language sender
    // dispatch msg.bytes ...
}
```

### Zig — [`zig/libipc/`](zig/libipc/)

Native Zig port (macOS-first), independently reimplementing the `ipc::route`
wire ABI — not an FFI wrapper of the C/C++ core. It covers the **core broadcast
transport**: byte-exact shm ring (`elem_array<80,8>`, 22784B), DCLP header init
over `os_unfair_lock`, the broadcast push/pop CAS protocol, prefix-global
`cc_id` identity, fragment reassembly, and receive-side chunk-storage decode for
large (>64B) messages; the **dead-connection reaper** (the `LV_CONN__` owner
table with a `proc_pidinfo` start token that defeats PID reuse); and the
**sync primitives** — an Apple-ulock word-lock mutex (with robust dead-holder
recovery), a seq-counter condition variable, and a `sem_open` semaphore, each
carrying the `SyncAbi` guard stamp. It also carries the **typed codec** (a thin protobuf-framed wrapper over the
route — field 1 varint `seq`, field 2 bytes `payload`, no protobuf library
needed) and the **secure AEAD envelope** (SIPC v1 framing with AES-256-GCM and
ChaCha20-Poly1305 done in pure Zig `std.crypto` — a standardized algorithm is
byte-identical to the OpenSSL-backed ports, so no C crypto is linked). It also has the **Layer-1 notify readiness** for async receive: a sender posts
on the libnotify service keyed by `fnv1a_64("<prefix>__IPC_SHM__NOTIFY__<name>")`,
and an `aread` receiver wakes on that fd. It joins every matrix scenario except
multi-writer `channel` — `sync`, `fanout`, `reap`, `primitives`, `typed`,
`secure`/`secure-badkey`/`secure-negative`, and `async` — proven byte-exact with
the C++, Rust and Swift ports in every writer→reader direction at all payload
sizes (40 B–64 KB). That includes: a reaper or a mutex-recoverer of any language
reclaims a dead Zig peer and never false-reaps a live one; a Zig `broadcast`
wakes a C++/Rust/Swift condition waiter; an envelope sealed by any language opens
in Zig (with tampered / wrong-key / wrong-key-id / algorithm-mismatched envelopes
rejected fail-closed); and a Zig `send` wakes a C++ stdexec / coroutine, Rust
`AsyncRoute` or Swift async receiver, and vice versa. Multi-writer `channel` is
the one gap — a cross-port ABI incompatibility that predates this port and runs
as an expected-fail for every language.

Idiomatic Zig: `std.posix`/`std.c` for the syscalls, native `@atomic*`
builtins over the shm fields, and `extern struct` with comptime `@sizeOf`/
`@offsetOf` guards for the byte-exact layouts. The only unavoidable C
dependencies are Apple-specific primitives with no Zig equivalent: `os_unfair_lock`
(the header lock a C++ peer contends on during DCLP init), the `__ulock_wait`/
`__ulock_wake` futex the sync primitives are built on, and `proc_pidinfo` (the
reaper's start token). One sharp edge worth noting: `sem_open` is variadic, and
on Apple arm64 variadic args pass on the stack — so it must be declared variadic
(std.c's fixed-arg wrapper corrupts the mode/value → `EINVAL`).

```sh
cd zig/libipc && zig build          # -> zig-out/bin/xlang harness
zig build test                      # byte-exact ABI unit tests
```

## Capabilities

**Cross-language, byte-exact and stable.** Every capability below is proven in
the CI matrix with a message or primitive produced by one language and consumed
by another, in every writer→reader direction (all four languages on macOS;
C++↔Rust on Linux/Windows). The wire format and shared-memory layout are fixed.

- **Broadcast transport** — `ipc::route`, one writer → N readers over a
  lock-free shared-memory ring; blocking and non-blocking send/recv, message
  fragmentation and large-message (>64 B) chunk storage, verified byte-for-byte
  from 40 B to 64 KB.
- **Fan-out** — one writer to N concurrently-connected readers of mixed
  languages; every reader receives every message (per-reader `rc_` bitmask).
- **Dead-connection reaping** — a `SIGKILL`ed receiver's slot is reclaimed by any
  participant of any language via the `LV_CONN__` owner table and a
  PID-reuse-proof start token; a live receiver is never false-reaped.
- **Sync primitives** — inter-process mutex (with robust dead-holder recovery),
  condition variable and counting semaphore on the Apple ulock backend
  (backend_id=2); a lock held or a condition signalled by one language is
  observed by another.
- **Typed codec layer** — a pluggable codec wraps the route with a typed message
  (Protobuf is exercised in the matrix; FlatBuffers / Cap'n Proto are available
  per language).
- **Encrypted channels** — an opt-in AEAD secure envelope (SIPC v1) with
  AES-256-GCM and ChaCha20-Poly1305: sealed by any language, opened by every
  other; tampered, wrong-key, wrong-key-id and algorithm-mismatched envelopes are
  rejected fail-closed.
- **Async receive** — a Layer-1 notify readiness fd multiplexes many channels on
  one event loop instead of a blocking thread each; a `send()` in any language
  wakes a C++ stdexec/coroutine, Rust `AsyncRoute`, Swift async or Zig `aread`
  receiver.

**Platforms** — C++: Linux, Windows, macOS, FreeBSD. Rust: Linux, Windows,
macOS. Swift: macOS 14+. Zig: macOS (arm64). Multi-writer `ipc::channel` is the
one capability not yet cross-language (see gaps below).

**Known cross-language parity gaps** — discovered by the matrix and tracked as
expected-failures in [`tools/xlang-ci.toml`](tools/xlang-ci.toml) until closed:

- `ipc::channel` (multi-writer): the C++ multi-producer broadcast queue uses a
  different slot layout (96 B + commit flag) than the ports, and port senders
  draw message ids from a process-local counter instead of the shared `AC_CONN`
  counter — not interoperable, and port↔port multi-writer collides.
- Semaphore: C++ ↔ port semaphores don't interop in either direction (different
  backing objects); the pure ports (Rust/Swift/Zig) interoperate.
- Mutex: mutual exclusion is broken while a **Rust** process holds the lock — its
  mutex open re-initializes live state, so C++/Rust/Swift probers can acquire a
  held lock. The Zig prober never re-inits and reports contention correctly.
- Async receive: messages above ring capacity (16 KB) deadlock a parked async
  receiver, so the async matrix caps payloads at 3 KB.

**Prototype** — unreleased, under active development, APIs and data layouts may change:

- `cpp/libipc/include/libipc/proto/` — typed protocol layer, service registry, process manager, shm_ring, RT priority
- `cpp/libipc/demo/audio_service/` — FlatBuffers audio service demo with orchestration
- `cpp/libipc/demo/audio_realtime/` — real-time audio demo with lock-free ring buffer and warm standby failover
- `rust/libipc/src/bin/demo_rt_audio_*` — Rust 2024 edition RT audio service via C FFI / bindgen

## Cross-language testing

Same-language test suites cannot catch ABI drift between the ports — every bug
in the list above shipped with green per-language suites. The repo therefore
treats **cross-language pairings as the primary test axis**, driven by a
dedicated framework: [`tools/xlang-runner`](tools/xlang-runner) (Rust).

The architecture has two halves:

1. **One harness binary per language** (`cpp/libipc/test/xlang/xlang.cpp`,
   `rust/libipc/src/bin/xlang.rs`, `swift/libipc/Sources/XlangHarness`,
   `zig/libipc/src/xlang.zig`) with a uniform verb CLI (`write`/`read`,
   `cwrite`/`cread`, `twrite`/`tread`, `swrite`/`sread`, `aread`,
   `hold`/`count`/`probe`, `mhold`/`mtry`/`mlock`, …). Each harness reports its
   build/runtime features via a `caps` verb.
2. **A declarative matrix runner** that expands scenarios into every
   writer→reader language pairing, negotiates capabilities (a harness lacking
   a feature is skipped with a note, or fails fast under `--strict-caps`),
   executes cases in parallel with hard deadlines, and reports console +
   JUnit + JSON. One TOML config ([`tools/xlang-ci.toml`](tools/xlang-ci.toml))
   serves every OS/CI job via `${ENV_VAR}` binary paths.

Scenarios: `sync` (byte-exact round-trips incl. fragment/chunk boundaries),
`fanout` (1 writer → N mixed-language readers), `channel` (multi-writer),
`reap` (dead-connection reaping + traffic-after-reap), `primitives`
(mutex/semaphore/condition), `typed` (codec layer), `async` (notify wakeup),
and `secure`/`secure-badkey`/`secure-negative` (AEAD envelope interop:
sealed by any language, opened by every other; tampered, wrong-key,
wrong-key-id and algorithm-mismatched envelopes rejected fail-closed).

Known gaps run as **expected-failures**: documented in every run, non-fatal,
and flagged `UNEXPECTED-pass` the moment a fix lands so the expectation gets
flipped — the matrix is simultaneously the regression suite and the live
ledger of remaining parity work. See
[`tools/xlang-runner/README.md`](tools/xlang-runner/README.md) for scenario
details, local usage, and how to add a language or scenario.

## Usage

See: [`cpp/libipc/`](cpp/libipc/) for C++ usage. Rust and Swift usage is documented inline in each subdirectory's source and test files.

## Performance

### Windows

 Environment | Value
 ------ | ------
 CPU | AMD Ryzen 9 7950X3D 16-Core (32 threads)
 RAM | 64 GB
 OS | Windows 11 Pro x64
 Compiler | MSVC 19.50 (Visual Studio 18 2026), Release build

All values in **µs/datum** (lower is better).

#### `ipc::route` — 1 sender, N receivers (random 2–256 bytes × 100 000)

 Receivers | µs/datum
 ------ | ------
 1 | **1.80**
 2 | 25.79
 4 | 48.23
 8 | 94.88

#### `ipc::channel` — multiple patterns (random 2–256 bytes × 100 000)

 Threads | 1→N | N→1 | N→N
 ------ | ------ | ------ | ------
 1 | **2.59** | **2.60** | **2.58**
 2 | 26.47 | 10.00 | 31.67
 4 | 51.16 | 10.59 | 65.29
 8 | 93.04 | 10.75 | 127.06

### macOS

 Environment | Value
 ------ | ------
 CPU | Apple Silicon (arm64), 12 threads
 OS | macOS (Darwin)
 Compiler | Apple Clang (C++17), Release build
 Peak throughput | **~7.2 GB/s** (128 B – 16 KB messages, `msg_que` demo)

All values in **µs/datum** (lower is better).

#### `ipc::route` — 1 sender, N receivers (random 2–256 bytes × 100 000)

 Receivers | µs/datum
 ------ | ------
 1 | **0.70**
 2 | 0.72
 4 | 2.05
 8 | 4.76

#### `ipc::channel` — multiple patterns (random 2–256 bytes × 100 000)

 Threads | 1→N | N→1 | N→N
 ------ | ------ | ------ | ------
 1 | **0.51** | **0.50** | **0.50**
 2 | 0.66 | 0.58 | 0.91
 4 | 2.12 | 0.84 | 2.63
 8 | 4.80 | 1.02 | 5.62

> 💡 Reproduce with: `cmake -B build -DLIBIPC_BUILD_BENCHMARKS=ON -DCMAKE_BUILD_TYPE=Release && cmake --build build --target bench_ipc && ./build/bin/bench_ipc`

Raw data: [performance.xlsx](performance.xlsx) &nbsp;|&nbsp; Benchmark source: [bench/](bench/)

## Documentation

- **[Cross-Language Test Framework](tools/xlang-runner/README.md)** — the xlang matrix runner: scenarios, capability negotiation, expected-failure tracking, adding languages/scenarios
- **[Cross-Language Channel ABI](context/xlang-channel-abi.md)** — the byte-exact wire spec the matrix verifies (ring layout, framing, notify, reaper)
- **[macOS Technical Notes](doc/macos-technical-notes.md)** — platform-specific implementation details for macOS (semaphores, mutexes, shared memory)
- **[Windows Technical Notes](doc/windows-technical-notes.md)** — platform-specific implementation details for Windows (MSVC conformance, process management, thread priority)
- **[macOS Deployment & Distribution](doc/macos-deployment.md)** — code signing, notarization, sandbox restrictions, and XPC alternatives for production shipping
- **[Typed Protocol Layer](doc/proto-layer.md)** *(prototype)* — FlatBuffers-based typed channels and routes for type-safe, zero-copy IPC messaging
- **[Process Orchestration & Discovery](doc/orchestration.md)** *(prototype)* — service registry, process management, redundant service groups with automatic failover
- **[Secure POS Demo](cpp/libipc/demo/secure_pos/)** — encrypted IPC where it is mandatory (PCI-style card pipeline): pinpad seals, gateway opens, keyless POS fails closed; roles mixable across C++/Rust
- **[Async Gateway Demo](rust/libipc/src/bin/demo_async_gateway.rs)** — one event loop multiplexing many device channels via `AsyncRoute` (thread-per-channel does not scale; runtimes cannot host blocking recv)
- **[Audio Service Demo](cpp/libipc/demo/audio_service/)** *(prototype)* — complete example with FlatBuffers protocol, redundancy, crash recovery, and auto-reconnect
- **[Real-Time Audio Demo](cpp/libipc/demo/audio_realtime/)** *(prototype)* — dropout-free design with lock-free ring buffer, RT thread priority, heartbeat watchdog, and warm standby failover
- **[Cross-Language Services via C FFI](doc/rust-services.md)** *(prototype)* — Rust 2024 edition service using bindgen-generated FFI bindings to the proto layer, with CMake auto-detection

## License

thoth-ipc is dual-licensed, at your option, under either of:

- **Apache License, Version 2.0, with the LLVM exception** ([LICENSE-APACHE](LICENSE-APACHE)), or
- **MIT license** ([LICENSE-MIT](LICENSE-MIT))

SPDX: `Apache-2.0 WITH LLVM-exception OR MIT`. Unless you explicitly state
otherwise, any contribution you intentionally submit for inclusion shall be
dual-licensed as above, without additional terms.

Copyright © 2025–2026 natyamatsya and thoth-ipc contributors.

**Fork provenance.** thoth-ipc is a fork of
[cpp-ipc](https://github.com/mutouyun/cpp-ipc) (© 2018 mutouyun), which was
released under MIT. MIT permits sublicensing, so the combined work — including
modified upstream portions — is redistributed under the dual license above,
with mutouyun's original MIT copyright and permission notice retained as MIT
requires. See [NOTICE](NOTICE) for full provenance and third-party components.

Source files carry [SPDX](https://spdx.dev/) headers identifying the license and
copyright holders:

```text
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2018 mutouyun (http://orzz.org)                          ← upstream cpp-ipc code
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors         ← thoth-ipc additions
```

Files created entirely by thoth-ipc contributors carry only the second copyright
line; files derived from cpp-ipc carry both. Vendored dependencies under
`cpp/libipc/3rdparty/` and `swift/libipc/vendor/` keep their own licenses and are
not relicensed.

## Reference

- [Lock-Free Data Structures | Dr Dobb's](http://www.drdobbs.com/lock-free-data-structures/184401865)
- [Yet another implementation of a lock-free circular array queue | CodeProject](https://www.codeproject.com/Articles/153898/Yet-another-implementation-of-a-lock-free-circular)
- [Lock-Free 编程 | 匠心十年 - 博客园](http://www.cnblogs.com/gaochundong/p/lock_free_programming.html)
- [无锁队列的实现 | 酷 壳 - CoolShell](https://coolshell.cn/articles/8239.html)
- [Implementing Condition Variables with Semaphores](https://www.microsoft.com/en-us/research/wp-content/uploads/2004/12/ImplementingCVs.pdf)
