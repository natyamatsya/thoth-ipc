# TODO

Open items left after the Linux Zig port and the cross-language demo matrix
(through `2cb28b8`). Everything below was checked on Linux x86-64 only.

## Unverified: needs macOS, Windows or a CI run

- [ ] **Swift demo changes.** Every Swift demo edit is unbuilt (Swift is
  macOS-only): stall timeouts and `clear` verbs (bounded_buffer,
  channel_aggregator, pipeline), stdout line buffering in all six demos, the
  count modes of msg_que, send_recv and chat, and the send_recv default-mode
  fixes. The macOS job of `.github/workflows/demos.yml` covers them.
- [ ] **Swift connect-window fix.** The ABI 1.3.0 receiver connect (`since`,
  adopt, stale-mark release with its wait for a claim in progress) and the
  route writer's `since` filter in `Liveness.swift` and `Channel.swift` have
  never been compiled or run. The macOS xlang job covers them.
- [ ] **The new CI.** `.github/workflows/demos.yml` and the Zig steps added to
  the Linux jobs of `.github/workflows/xlang.yml` have not run yet. On macOS the
  C++ audio services may be skipped if Apple clang lacks C++23 `<print>`
  (`THOTH_IPC_HAS_STD_PRINT`); `--require cpp` would then fail the job. The
  FFI audio service build (cargo from CMake, bindgen with apt's `libclang-dev`
  on Linux and Xcode's libclang on macOS) has only run locally.
- [ ] **Zig on macOS.** Since the Linux port it has only been type-checked for
  `aarch64-macos` (`zig build-exe -target aarch64-macos -fno-emit-bin`), never
  built or run there.
- [ ] **Zig on Linux aarch64.** Never built; the README claims only x86-64.
- [ ] **Rust `thoth_ipc::proto::steady_clock_ns()`.** Only the Linux path
  (`CLOCK_MONOTONIC`) has run. The Apple path (`CLOCK_UPTIME_RAW`, matching
  libc++'s `steady_clock`) and the Windows path (QueryPerformanceCounter,
  scaled as MSVC's `steady_clock` does) are untested; the realtime audio
  demo's heartbeat depends on them matching C++.
- [ ] **rustfmt.** The Rust added in this work has not been through
  `cargo fmt` (no rustfmt in the toolchain used).

## Port coverage (by design, for now)

- [ ] **async_gateway** exists in Rust and Zig only; no C++ port (it would use
  stdexec `async_recv`) and no Swift port.
- [ ] **audio_service / audio_realtime** exist in C++ and Rust only; Zig and
  Swift would need FlatBuffers code generation.
- [ ] **send_recv default-mode senders differ.** The C++ sender sends without
  waiting for a receiver; Rust, Swift and Zig wait for one first. The Zig
  default modes have no signal handler (they stop only when killed).

## Minor

- [ ] **Compiler warning.** Unused import `std::os::unix::io::AsRawFd` at
  `rust/thoth-ipc/src/notify.rs:214` (pre-existing).
- [ ] **chat bot exit codes.** The C++ and Rust bots exit 5 for both a receive
  timeout and a receive error, so the two cannot be told apart.
