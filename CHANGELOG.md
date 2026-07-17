# Changelog

Notable changes to thoth-ipc. The format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow SemVer
(pre-1.0: minor bumps may include behavioural changes).

## [0.3.0] — 2026-07-17

### Added
- **Native Zig port** [`zig/libipc/`](zig/libipc/) — an independent
  reimplementation of the `ipc::route` wire ABI (not an FFI wrapper), proven
  byte-exact against the C++, Rust and Swift ports in every writer→reader
  direction. Joins every matrix scenario except multi-writer `channel`: the
  broadcast transport (fragmentation + chunk storage, 40 B–64 KB), fan-out, the
  dead-connection reaper (`LV_CONN__` + `proc_pidinfo` start token), the ulock
  sync primitives (mutex with robust dead-holder recovery / condition /
  semaphore), the typed protobuf codec, the AEAD secure envelope (AES-256-GCM
  and ChaCha20-Poly1305 via pure Zig `std.crypto`), and Layer-1 notify readiness
  (`aread`). macOS-first; wired into the `matrix-macos` and `async-matrix-macos`
  CI jobs.

### Changed
- **Relicensed** from MIT to a dual **Apache-2.0 WITH LLVM-exception OR MIT**
  (SPDX: `Apache-2.0 WITH LLVM-exception OR MIT`). Copyright is now held by
  "natyamatsya and thoth-ipc contributors". The upstream cpp-ipc MIT copyright
  (© 2018 mutouyun) is retained on the derived source files and in `LICENSE-MIT`
  as MIT's sublicense terms require. See `LICENSE-APACHE`, `LICENSE-MIT` and
  `NOTICE`. Vendored dependencies keep their own licenses.

## [0.2.0] — 2026-07-14

### Added
- **Cross-language test framework** [`tools/xlang-runner`](tools/xlang-runner)
  (Rust), replacing `tools/xlang_matrix.py`: declarative TOML config with
  env-var binary paths, capability negotiation via the harnesses' `caps`
  verb, parallel execution, JUnit/JSON reporting, and an expected-failure
  ledger (`xfail`) that documents known gaps in every run and flags
  unexpected passes.
- **New matrix scenarios** (with the harness verbs backing them in all three
  languages): `secure`/`secure-badkey`/`secure-negative` (AEAD envelope v1
  interop incl. tamper/wrong-key/wrong-key-id/algorithm-mismatch fail-closed),
  `fanout` (1 writer → N mixed-language readers), `channel` (multi-writer),
  `primitives` (mutex/semaphore/condition), `typed` (codec layer), reap
  edges (`probe` no-reap, traffic-after-reap), and 63/64/65 + 64KB payload
  boundaries.
- **Demos for the two headline features**:
  [`secure_pos`](cpp/libipc/demo/secure_pos/) (C++ + Rust, wire-identical
  roles) — a PCI-style card pipeline where AEAD on a broadcast bus is
  mandatory; and `demo_async_gateway` (Rust) — one event loop multiplexing
  many device channels via `AsyncRoute`.
- Windows secure-scenario CI (choco OpenSSL + MSVC `libcrypto` link support
  in `build.rs`).

### Changed
- The FlatBuffers audio demo bins (`demo_audio_host`, `demo_audio_service`)
  are gated behind the new `audio-demos` cargo feature: a feature-less
  `cargo build --bins` no longer hard-fails when `flatc` is absent, and
  enabling the feature without `flatc` fails fast with an actionable error.
- Chat demos adopt the string-send helpers (Rust `send_str`, Swift
  `send(string:)`).

### Fixed
- Rust/Swift chat demos kept the shared ID-counter shm handle alive only
  momentarily, so the segment was unlinked and every instance restarted
  numbering at `c0` (mistaking each other's messages for their own).

### Known gaps (discovered by the matrix, tracked as expected-failures)
- Cross-language `ipc::channel` (multi-writer) was never ABI-compatible, and
  port multi-writer collides on process-local message ids.
- C++ ↔ port semaphores do not interop; mutual exclusion is broken while a
  Rust process holds the mutex.
- Async receive deadlocks above ring capacity (16KB) and can mis-assemble at
  exactly 16KB into the C++ async receiver.

See [`tools/xlang-runner/README.md`](tools/xlang-runner/README.md#known-gaps-expected-fail).

## [0.1.0]

Initial thoth-ipc baseline, branched from upstream
[cpp-ipc](https://github.com/mutouyun/cpp-ipc) v1.4.1: macOS support, pure
Rust port, Swift package, typed protocol layer, opt-in secure codec, async
receive, dead-connection reaping, cross-language sync ABI alignment.
