# thoth-ipc — Cross-Language IPC Library

[![License: Apache-2.0-LLVM OR MIT](https://img.shields.io/badge/license-Apache--2.0--LLVM%20OR%20MIT-blue.svg)](#license)
[![Build Status](https://github.com/natyamatsya/thoth-ipc/actions/workflows/c-cpp.yml/badge.svg)](https://github.com/natyamatsya/thoth-ipc/actions)
[![Cross-language ABI](https://github.com/natyamatsya/thoth-ipc/actions/workflows/xlang.yml/badge.svg)](https://github.com/natyamatsya/thoth-ipc/actions/workflows/xlang.yml)

A high-performance inter-process communication library using shared memory on Linux/Windows/macOS/FreeBSD.
Binary-compatible primitives implemented in multiple languages — all sharing the same wire format and shm layout.

Four independent implementations — **C++, Rust, Swift and Zig** — are
**byte-exact** on the `thoth::route` wire ABI
([`context/xlang-channel-abi.md`](context/xlang-channel-abi.md)). A CI matrix
framework ([`tools/xlang-runner`](tools/xlang-runner)) runs every writer→reader
language pairing to prove a message sent by any language is received
byte-for-byte by any other — across blocking round-trips (fragment and
chunk-storage boundaries, 40 B – 64 KB), broadcast fan-out to mixed-language
readers, multi-writer `thoth::channel` (two concurrent senders of different
languages into one reader), async notify wakeup, dead-connection reaping, sync
primitives (mutex/condition/semaphore), the typed codec layer, and **encrypted
channels**: AEAD envelopes (AES-256-GCM, ChaCha20-Poly1305) sealed by one
language open in every other, with tampered, wrong-key, wrong-key-id or
algorithm-mismatched envelopes rejected fail-closed. (On Linux the matrix pairs C++, Rust and Zig; on
Windows, C++ and Rust.) Every pairing the matrix
exercises now passes byte-exact — the expected-failure list is empty.

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
cpp/thoth-ipc/    — C++ library (upstream core, extended; Linux/Windows/macOS/FreeBSD)
rust/thoth-ipc/   — Pure Rust port (Linux/Windows/macOS)
swift/thoth-ipc/  — Swift package (macOS 14+; byte-exact with C++/Rust/Zig)
zig/thoth-ipc/    — Native Zig port (macOS, Linux; byte-exact, full cross-language parity)
```

## Language implementations

### C++ — [`cpp/thoth-ipc/`](cpp/thoth-ipc/)

[![Build Status](https://github.com/natyamatsya/thoth-ipc/actions/workflows/c-cpp.yml/badge.svg)](https://github.com/natyamatsya/thoth-ipc/actions)

Based on the original [cpp-ipc](https://github.com/mutouyun/cpp-ipc) library. See [`cpp/thoth-ipc/README.md`](cpp/thoth-ipc/README.md) for full documentation.

- C++17 (msvc-2017/gcc-7/clang-4); built with C++23 in this repo
- No dependencies except STL for the core transport
- Lock-free or lightweight spin-lock only
- `thoth::route` (1 writer, N readers) and `thoth::channel` (N writers, N readers)
- Typed protocol layer: FlatBuffers, Cap'n Proto, Protocol Buffers (opt-in)
- Opt-in secure codec with AEAD envelope (OpenSSL EVP backend, zero overhead when disabled)
- Opt-in reactor-integrable async receive: a readiness handle (`native_wait_handle()`) and a stdexec `thoth::async_recv()` sender, so channels multiplex on one event loop instead of one blocking thread each — zero cost when off. See [`cpp/thoth-ipc/doc/async-recv.md`](cpp/thoth-ipc/doc/async-recv.md)

**macOS support** (not present in upstream cpp-ipc, added in this fork):

- `THOTH_IPC_OS_APPLE` platform branch added throughout sync, shm, and platform layers
- `shm_open` name hashing: macOS enforces `PSHMNAMLEN=31`; names are FNV-1a hashed when they exceed the limit (auto-enabled on Apple, zero-cost elsewhere)
- `ftruncate`/`fstat` quirks on already-sized shm objects handled correctly
- `pthread_mutex_timedlock` emulated (not available on macOS) with adaptive spin + sleep back-off
- `pthread_mutexattr_setrobust` emulated via PID-based dead-holder detection (`kill(pid, 0)`)
- `-lrt` excluded on Darwin (not present on macOS)
- `__ulock_wait`/`__ulock_wake` backend (default): word-lock mutex, seq-counter condvar, counting semaphore — equivalent to Linux futex, lowest latency
- Mach semaphore backend (`-DTHOTH_IPC_APPLE_APP_STORE_SAFE=ON`): public-API-only alternative, App Store safe
- File-backed mmap fallback (`-DTHOTH_IPC_USE_FILE_SHM=ON`): avoids `shm_open` entirely, sidesteps all `PSHMNAMLEN`/`ftruncate` quirks
- Universal binary CI: `arm64;x86_64` fat binary verified with `lipo`

### Rust — [`rust/thoth-ipc/`](rust/thoth-ipc/)

Pure Rust crate, binary-compatible with the C++ and Swift libraries.

- All primitives ported: shm, mutex, semaphore, condition, buffer, channel, waiter, circ
- Typed protocol layer: FlatBuffers (default), Cap'n Proto, Protocol Buffers (feature flags)
- Secure codec with AEAD envelope, OpenSSL EVP backend (feature-gated)
- Apple ulock sync ABI alignment with C++ and Swift
- Service registry, process manager, real-time audio demos
- **Async receive** (opt-in): a Layer-1 notify readiness fd (byte-exact with C++
  `THOTH_IPC_NOTIFY_FD`) + `AsyncRoute::recv().await` on tokio — a Rust `send()`
  wakes a C++ `async_recv` and vice versa

```sh
cd rust/thoth-ipc && cargo test
```

**Async receive** — enable the `async-tokio` feature (implies `notify`):

```rust
use thoth_ipc::async_recv::AsyncRoute;

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
[`demo_async_gateway`](rust/thoth-ipc/src/bin/demo_async_gateway.rs) (one event
loop multiplexing many device channels).

### Swift — [`swift/thoth-ipc/`](swift/thoth-ipc/)

Swift Package Manager package targeting macOS 14+.

- Core transport (`Route`, `Channel`) binary-compatible with C++ and Rust
- Apple ulock sync primitives (`IpcMutex`, `IpcCondition`, `IpcSemaphore`) aligned with C++ and Rust ABI
- Typed protocol layer: FlatBuffers, Protocol Buffers
- Secure codec with AEAD envelope, optional OpenSSL EVP backend
- **Async receive**: `AsyncRoute.recv() async` over the Layer-1 readiness fd
  (`DispatchSource`), woken by a C++/Rust/Swift/Zig sender's notify
- Bench and demo executables included

```sh
cd swift/thoth-ipc && swift build
```

**Async receive** — a Swift `send()` posts the readiness notify, and
`AsyncRoute` awaits it on any Swift concurrency executor:

```swift
import ThothIPC

let r = try await AsyncRoute.connect(name: "st.agent.cmd")   // receiver
while true {
    let msg = try await r.recv()                             // woken by any-language sender
    // dispatch msg.bytes ...
}
```

### Zig — [`zig/thoth-ipc/`](zig/thoth-ipc/)

Native Zig port (macOS and Linux), independently reimplementing the `thoth::route`
wire ABI — not an FFI wrapper of the C/C++ core. It covers the **core broadcast
transport**: byte-exact shm ring (`elem_array<80,AlignSize>`: 22784 B on Apple arm64,
24832 B on x86-64 / Linux aarch64), DCLP header init over the `thoth::spin_lock`, the broadcast push/pop CAS protocol, prefix-global
`cc_id` identity, fragment reassembly, and receive-side chunk-storage decode for
large (>64B) messages; the **dead-connection reaper** (the `LV_CONN__` owner
table with a process start token that defeats PID reuse); and the
**sync primitives**, each carrying the `SyncAbi` guard stamp — on macOS an
Apple-ulock word-lock mutex (with robust dead-holder recovery), a seq-counter
condition variable and a shm-ulock counting semaphore; on Linux the alephzero
robust priority-inheriting futex mutex and requeue-PI condition (`linux_a0`)
and a `sem_open` semaphore, as C++ and Rust run there. It also carries the **typed codec** (a thin protobuf-framed wrapper over the
route — field 1 varint `seq`, field 2 bytes `payload`, no protobuf library
needed) and the **secure AEAD envelope** (SIPC v1 framing with AES-256-GCM and
ChaCha20-Poly1305 done in pure Zig `std.crypto` — a standardized algorithm is
byte-identical to the OpenSSL-backed ports, so no C crypto is linked). It also has the **Layer-1 notify readiness** for async receive, keyed by
`fnv1a_64("<prefix>__THOTH_SHM__NOTIFY__<name>")`: a sender posts on that
libnotify service (macOS) or pokes each connected reader's FIFO (Linux), and an
`aread` receiver wakes on its fd. Like the other ports, Zig targets the
single-writer `thoth::route`, and it joins **every cross-language matrix
scenario** — `sync`, `fanout`, `reap`, `primitives`, `typed`,
`secure`/`secure-badkey`/`secure-negative`, and `async` — proven byte-exact with
the C++, Rust and Swift ports in every writer→reader direction at all payload
sizes (40 B–64 KB). That includes: a reaper or a mutex-recoverer of any language
reclaims a dead Zig peer and never false-reaps a live one; a Zig `broadcast`
wakes a C++/Rust/Swift condition waiter; an envelope sealed by any language opens
in Zig (with tampered / wrong-key / wrong-key-id / algorithm-mismatched envelopes
rejected fail-closed); and a Zig `send` wakes a C++ stdexec / coroutine, Rust
`AsyncRoute` or Swift async receiver, and vice versa. The multi-writer
`thoth::channel` is now interoperable across all four ports too — two concurrent
senders of different languages into one reader, byte-exact on the 96-byte
commit-flag slot layout and the shared `AC_CONN__` message-id counter.

Idiomatic Zig: `std.posix`/`std.c`/`std.os.linux` for the syscalls, native
`@atomic*` builtins and `std.atomic.Value` over the shm fields, `extern struct`
with comptime `@sizeOf`/`@offsetOf` guards for the byte-exact layouts, and one
type per primitive whose platform backend is chosen at comptime. The ABI
constants come from `abi_generated.zig`, generated for both alignment classes.
The only C dependencies on macOS are Apple primitives with no Zig equivalent:
the `__ulock_wait`/`__ulock_wake` futex the sync primitives are built on,
libnotify, and `proc_pidinfo` (the reaper's start token). On Linux the futexes
and the robust list are raw syscalls; libc provides `sem_open` and `mkfifo`.

```sh
cd zig/thoth-ipc && zig build          # -> zig-out/bin/xlang harness
zig build test                      # byte-exact ABI unit tests
```

## Capabilities

**Cross-language, byte-exact and stable.** Every capability below is proven in
the CI matrix with a message or primitive produced by one language and consumed
by another, in every writer→reader direction (all four languages on macOS;
C++↔Rust on Linux/Windows). The wire format and shared-memory layout are fixed.

- **Broadcast transport** — `thoth::route`, one writer → N readers over a
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
  (backend_id=2) and, C++↔Rust, the Linux alephzero futex backend
  (backend_id=5); a lock held or a condition signalled by one language is
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
macOS. Swift: macOS 14+. Zig: macOS (arm64), Linux (x86-64).

Every port targets both the single-writer `thoth::route` and the multi-writer
`thoth::channel`; both are cross-language byte-exact across all four ports.

**Cross-language parity** — every pairing the matrix exercises now passes
byte-exact; the expected-failure list in
[`tools/xlang-ci.toml`](tools/xlang-ci.toml) is empty. Gaps the matrix uncovered
and that have since been closed include the multi-writer `thoth::channel` layout
(all four ports), the C++↔port semaphore backing object (the ports' POSIX
`sem_open` replaced by a shared shm-ulock counter byte-exact with C++), and a
Rust Apple-mutex cross-process ref-count bug that let a prober re-initialise a
held lock.

**Known limitation** — async receive: messages above ring capacity (16 KB)
deadlock a parked async receiver, so the async matrix caps payloads at 3 KB.

**Prototype** — unreleased, under active development, APIs and data layouts may change:

- `cpp/thoth-ipc/include/thoth-ipc/proto/` — typed protocol layer, service registry, process manager, shm_ring, RT priority
- `cpp/thoth-ipc/demo/audio_service/` — FlatBuffers audio service demo with orchestration
- `cpp/thoth-ipc/demo/audio_realtime/` — real-time audio demo with lock-free ring buffer and warm standby failover
- `rust/thoth-ipc/src/bin/demo_rt_audio_*` — Rust 2024 edition RT audio service via C FFI / bindgen

## Cross-language testing

Same-language test suites cannot catch ABI drift between the ports — every one
of the gaps described above shipped with green per-language suites and was found
only by cross-language pairing. The repo therefore treats **cross-language
pairings as the primary test axis**, driven by a dedicated framework:
[`tools/xlang-runner`](tools/xlang-runner) (Rust).

The architecture has two halves:

1. **One harness binary per language** (`cpp/thoth-ipc/test/xlang/xlang.cpp`,
   `rust/thoth-ipc/src/bin/xlang.rs`, `swift/thoth-ipc/Sources/XlangHarness`,
   `zig/thoth-ipc/src/xlang.zig`) with a uniform verb CLI (`write`/`read`,
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

Any residual gap runs as an **expected-failure**: documented in every run,
non-fatal, and flagged `UNEXPECTED-pass` the moment a fix lands so the
expectation gets flipped — the matrix is simultaneously the regression suite and
the live ledger of parity work. The expected-failure list is currently empty:
every pairing passes. See
[`tools/xlang-runner/README.md`](tools/xlang-runner/README.md) for scenario
details, local usage, and how to add a language or scenario.

The **demos** form a second matrix over the same idea. Their roles share one CLI
and wire format across the ports, so `demo-runner` (in the same crate, config
[`tools/demos.toml`](tools/demos.toml)) runs every demo with every built
language in every role — all 81 four-hop source → stage → stage → sink
pipelines over C++, Rust and Zig, every pinpad × gateway × POS of the secure
bus, every host × service of the audio demos, … — and checks each process's
exit code and stdout, so a lost message or a hung role fails the case. On
Linux that is 160 cases over eleven demos in about 30 s; the
[demos workflow](.github/workflows/demos.yml) runs it on Linux and macOS.

## Usage

See: [`cpp/thoth-ipc/`](cpp/thoth-ipc/) for C++ usage. Rust and Swift usage is documented inline in each subdirectory's source and test files.

## Performance

### Windows

 Environment | Value
 ------ | ------
 CPU | AMD Ryzen 9 7950X3D 16-Core (32 threads)
 RAM | 64 GB
 OS | Windows 11 Pro x64
 Compiler | MSVC 19.50 (Visual Studio 18 2026), Release build

All values in **µs/datum** (lower is better).

#### `thoth::route` — 1 sender, N receivers (random 2–256 bytes × 100 000)

 Receivers | µs/datum
 ------ | ------
 1 | **1.80**
 2 | 25.79
 4 | 48.23
 8 | 94.88

#### `thoth::channel` — multiple patterns (random 2–256 bytes × 100 000)

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

#### `thoth::route` — 1 sender, N receivers (random 2–256 bytes × 100 000)

 Receivers | µs/datum
 ------ | ------
 1 | **0.70**
 2 | 0.72
 4 | 2.05
 8 | 4.76

#### `thoth::channel` — multiple patterns (random 2–256 bytes × 100 000)

 Threads | 1→N | N→1 | N→N
 ------ | ------ | ------ | ------
 1 | **0.51** | **0.50** | **0.50**
 2 | 0.66 | 0.58 | 0.91
 4 | 2.12 | 0.84 | 2.63
 8 | 4.80 | 1.02 | 5.62

> 💡 Reproduce with: `cmake -B build -DTHOTH_IPC_BUILD_BENCHMARKS=ON -DCMAKE_BUILD_TYPE=Release && cmake --build build --target bench_ipc && ./build/bin/bench_ipc`

Raw data: [performance.xlsx](performance.xlsx) &nbsp;|&nbsp; Benchmark source: [bench/](bench/)

## Documentation

- **[Cross-Language Test Framework](tools/xlang-runner/README.md)** — the xlang matrix runner: scenarios, capability negotiation, expected-failure tracking, adding languages/scenarios, and the demo matrix (`demo-runner`)
- **[Language-neutral ABI](abi/README.md)** — `abi/abi.json` is the single source of truth the four ports are generated from and checked against (schema + C++ dump + staleness + matrix gates); see the [hands-on walkthrough](abi/EXAMPLE.md)
- **[Cross-Language Channel ABI](context/xlang-channel-abi.md)** — the byte-exact wire spec the matrix verifies (ring layout, framing, notify, reaper)
- **[Multi-writer `thoth::channel` RFC](context/xlang-channel-multiwriter-rfc.md)** — the multi-writer ABI + per-language roadmap (Zig → Rust → Swift), now complete: `thoth::channel` is cross-language byte-exact across all four ports
- **[macOS Technical Notes](doc/macos-technical-notes.md)** — platform-specific implementation details for macOS (semaphores, mutexes, shared memory)
- **[Windows Technical Notes](doc/windows-technical-notes.md)** — platform-specific implementation details for Windows (MSVC conformance, process management, thread priority)
- **[macOS Deployment & Distribution](doc/macos-deployment.md)** — code signing, notarization, sandbox restrictions, and XPC alternatives for production shipping
- **[Typed Protocol Layer](doc/proto-layer.md)** *(prototype)* — FlatBuffers-based typed channels and routes for type-safe, zero-copy IPC messaging
- **[Process Orchestration & Discovery](doc/orchestration.md)** *(prototype)* — service registry, process management, redundant service groups with automatic failover
- **[Channel Aggregator Demo](cpp/thoth-ipc/demo/channel_aggregator/)** — multi-writer `thoth::channel` fan-in: N producers `send` into one channel, a single collector reads the merged stream and tallies it by producer (what a single-writer `route` cannot do). Implemented in all four ports (`cpp/thoth-ipc/demo/channel_aggregator/`, `rust/…/demo_channel_aggregator.rs`, `swift/…/DemoChannelAggregator`, `zig/…/demo_channel_aggregator.zig`), and because the wire format is byte-exact the roles are **mixable across languages** — e.g. a C++ collector receiving from C++/Rust/Swift/Zig producers at once
- **[Polyglot Pipeline Demo](cpp/thoth-ipc/demo/pipeline/)** — a chain of single-writer→single-reader `thoth::route` hops, **one process (and one language) per stage**. The launcher [`demo/pipeline/run.sh`](cpp/thoth-ipc/demo/pipeline/run.sh) chains the built ports — `Zig source → Rust stage → Swift stage → C++ sink` with all four, `Zig → Rust → C++` on Linux — and the sink prints one line showing every language a message crossed — e.g. `item-0 [zig] -> rust -> swift -> [cpp sink]`. The `source`/`stage`/`sink` roles exist in all four ports, so any stage can be any language
- **[Cross-Language Bounded Buffer Demo](cpp/thoth-ipc/demo/bounded_buffer/)** — the classic producer/consumer over a shared-memory ring, coordinated by a byte-exact named **`IpcMutex`** (guards `head`, so multiple producers contend) and two counting **`IpcSemaphore`s** (`empty`/`full`). The launcher [`demo/bounded_buffer/run.sh`](cpp/thoth-ipc/demo/bounded_buffer/run.sh) runs one consumer against a producer per built port (C++/Rust/Zig, and Swift on macOS) at once through a 4-slot ring — the languages synchronising on shared memory with the sync primitives this release made cross-language
- **[Secure POS Demo](cpp/thoth-ipc/demo/secure_pos/)** — encrypted IPC where it is mandatory (PCI-style card pipeline): pinpad seals, gateway opens, keyless POS fails closed; roles mixable across C++/Rust/Zig
- **[Async Gateway Demo](rust/thoth-ipc/src/bin/demo_async_gateway.rs)** — one event loop multiplexing many device channels via `AsyncRoute` (thread-per-channel does not scale; runtimes cannot host blocking recv); also in Zig, on one thread with `poll` over the notify readiness fds, and the agents mix across both
- **Chat, message queue, send/recv and service/client demos** ([`chat`](cpp/thoth-ipc/demo/chat/), [`msg_que`](cpp/thoth-ipc/demo/msg_que/), [`send_recv`](cpp/thoth-ipc/demo/send_recv/), [`linux_service`](cpp/thoth-ipc/demo/linux_service/)) — interactive or run-until-signal by default, each with a bounded count mode (`chat bot`, `msg_que s|r <count>`, …) that the demo matrix runs across C++, Rust, Swift and Zig

- **[Audio Service Demo](cpp/thoth-ipc/demo/audio_service/)** *(prototype)* — complete example with FlatBuffers protocol, redundancy, crash recovery, and auto-reconnect
- **[Real-Time Audio Demo](cpp/thoth-ipc/demo/audio_realtime/)** *(prototype)* — dropout-free design with lock-free ring buffer, RT thread priority, heartbeat watchdog, and warm standby failover
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
`cpp/thoth-ipc/3rdparty/` and `swift/thoth-ipc/vendor/` keep their own licenses and are
not relicensed.

## Reference

- [Lock-Free Data Structures | Dr Dobb's](http://www.drdobbs.com/lock-free-data-structures/184401865)
- [Yet another implementation of a lock-free circular array queue | CodeProject](https://www.codeproject.com/Articles/153898/Yet-another-implementation-of-a-lock-free-circular)
- [Lock-Free 编程 | 匠心十年 - 博客园](http://www.cnblogs.com/gaochundong/p/lock_free_programming.html)
- [无锁队列的实现 | 酷 壳 - CoolShell](https://coolshell.cn/articles/8239.html)
- [Implementing Condition Variables with Semaphores](https://www.microsoft.com/en-us/research/wp-content/uploads/2004/12/ImplementingCVs.pdf)
