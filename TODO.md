# TODO

Open items left after the Linux Zig port and the cross-language demo matrix
(through `2cb28b8`). Everything below was checked on Linux x86-64 only.

## Unverified: needs macOS, Windows or a CI run

- [ ] **Swift demo changes.** Every Swift demo edit is unbuilt (Swift is
  macOS-only): stall timeouts and `clear` verbs (bounded_buffer,
  channel_aggregator, pipeline), stdout line buffering in all six demos, the
  count modes of msg_que, send_recv and chat, and the send_recv default-mode
  fixes. The macOS job of `.github/workflows/demos.yml` covers them.
- [ ] **The new CI.** `.github/workflows/demos.yml` and the Zig steps added to
  the Linux jobs of `.github/workflows/xlang.yml` have not run yet. On macOS the
  C++ audio services may be skipped if Apple clang lacks C++23 `<print>`
  (`THOTH_IPC_HAS_STD_PRINT`); `--require cpp` would then fail the job.
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

## Known gaps

- [ ] **Receiver connect window.** In every port (C++ included) a receiver
  claims its connection bit and then reads the write cursor; a message pushed
  between the two is missed by that receiver. Reading the cursor right after the
  claim (`8b8c2c9`) moved the slow `/proc` read out of the window and fixed the
  flaky route tests, but the window itself remains. Closing it changes the
  connect protocol (context/xlang-channel-abi.md) in all four ports.
- [ ] **Zig receive spins.** `ChanInner.recv` / `ChannelInner.recv` wait by
  spinning with adaptive yield instead of sleeping on the route's waiter, which
  burns CPU on long waits (e.g. the Zig send_recv receiver and linux_service
  client in their default modes).
- [ ] **Zig channel clear is incomplete.** `transport/channel.zig`
  `clearStorage` removes the ring, `AC_CONN__` and `LV_CONN__` segments but not
  the RD/WT/CC waiter condition and mutex segments, which C++
  `conn_info_head::clear_storage` also removes.
- [ ] **FFI audio service not in the demo matrix.** `rt_audio_service_rs`
  (cpp/thoth-ipc/demo/audio_realtime/rust_service) needs bindgen/libclang, so
  `tools/demos.toml` and the demos workflow leave it out.

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
