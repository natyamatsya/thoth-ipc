# Changelog

Notable changes to thoth-ipc. The format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow SemVer
(pre-1.0: minor bumps may include behavioural changes).

## [Unreleased]

### Added
- **The Zig port runs on Linux.** It joins every xlang scenario there, byte-exact
  with the C++ and Rust Linux ports: the `linux_a0` robust priority-inheriting
  futex mutex and requeue-PI condition (a port of the C++/Rust alephzero code,
  robust list included), the `sem_open` semaphore with C++'s naming and
  last-handle unlink, per-reader FIFO notify readiness, a `/proc/<pid>/stat`
  start token and zombie check for the reaper, and the align-16 ring layout.
  Route waiters on Linux wake a parked C++/Rust peer by requeueing it onto the
  waiter's mutex, as a0 requires. The macOS backends are unchanged; each
  primitive is one type whose backend is chosen at comptime, so `Condition`'s
  `notify`/`broadcast` now take the paired mutex on both platforms. An opener
  of a fresh shm segment now waits for its creator to size it instead of risking
  a SIGBUS.
- **Every demo runs bounded, in every port that has it, and on Linux.** chat,
  msg_que, send_recv and linux_service gained an opt-in count mode (`chat bot
  <lines> <peers>`, `msg_que s|r <count>`, `send_recv send|recv ... <count>`,
  `linux_service|linux_client <count>`) with the same CLI and success lines in
  every port, timeouts that exit non-zero, and a `clear` verb; their interactive or
  run-forever default modes are unchanged. New ports: Zig chat, msg_que,
  send_recv, async_gateway and linux_service, and Rust linux_service. The Rust
  async gateway gives up after 20 s instead of waiting forever for a dead agent,
  and the C++ send_recv sender sends exactly `<size>` bytes like the others (it
  sent a trailing NUL too).
- **A Zig secure_pos demo.** The point-of-sale AEAD demo (pinpad seals card
  events onto a broadcast route, the gateway opens them, the keyless POS must
  not) now has a Zig port, wire-identical with the C++ and Rust roles: the same
  protobuf card event in a SIPC v1 AES-256-GCM envelope via std.crypto.
- **A cross-language demo matrix.** `demo-runner` (a second binary of
  `tools/xlang-runner`) runs every demo in `tools/demos.toml` with every present
  language in every role: the Cartesian product over the demo's slots (all 81
  four-hop source/stage/stage/sink pipelines for three languages), plus fan-in
  roles started once per language. It checks each process's exit code and
  stdout, so a lost message or a hung role fails the case; demos with fixed IPC
  names run one case at a time. Console, JUnit and JSON reporting as in
  `xlang-runner`. It covers all eleven demos (162 cases with C++, Rust,
  the FFI Rust audio service and Zig on Linux, in about 30 s). A slot takes the
  languages that ship the binaries its processes run, so the Rust audio_realtime
  service built against the C++ proto through a C FFI wrapper
  (`rt_audio_service_rs`) joins as `rust_ffi` in just the service slot; CI builds
  it (with libclang for bindgen) and requires it.

### Fixed
- **Zig's channel clear removes everything C++'s does.** `clearStorage` (and so
  the Zig demos' `clear` verbs) removed the ring and the `AC_CONN__` and
  `LV_CONN__` segments, but not the RD/WT/CC waiter conditions and mutexes,
  their guard sidecars, or the Linux notify FIFOs. After a process died holding
  a channel, 12 of its 15 shm objects survived a Zig `clear`; none do now, as
  with C++ `clear_storage`.
- **Zig receivers and senders sleep while they wait.** `recv` on an empty ring,
  a send whose slot is still unread and `waitForRecv` spun, yielded and then
  polled every millisecond, about 1000 wake-ups a second for an idle receiver.
  They now spin briefly and then park on the route's RD/WT/CC waiter, as C++,
  Rust and Swift do, and are woken by the peer's signal, re-checking at least
  every 100 ms. An idle receiver went from about 950 to about 10 context switches a
  second. The waiter (`transport/waiter.zig`) gains its wait side and is one type
  over the macOS and Linux condition and mutex. A disconnecting receiver now also
  wakes a parked sender.
- **A reconnecting broadcast receiver no longer stalls the writers (ABI 1.3.0).**
  A writer could stamp an element for a receiver between the receiver claiming its
  connection bit and reading the cursor, and a receiver that disconnected left its
  bit on what it had not read, for the next owner of the bit to inherit. A lap
  later the writer found those elements still unread and stalled until
  `force_push` disconnected the receiver, which timed out after about 255
  messages. Under load this hit about 0.25 % of reconnects. A receiver now reads
  the cursor before it claims its bit and records that position in its liveness
  slot (`slot_owner.since`, previously padding). It then reads what was addressed
  to it in between. The route writer ignores marks from before a receiver started
  and never disconnects a receiver over one. On a channel, where a concurrent
  writer makes that unsafe, the connecting receiver releases the stale marks of
  its bit instead. An element a writer has claimed but not yet committed is
  handled too: the receiver waits up to 50 ms for the commit. The fix is in all
  four ports (Swift unverified here); peers older than 1.3.0 interoperate as
  before. New churn tests in C++ and Rust, and a C++ test that holds a writer
  between claim and commit, fail without the fix. Spec:
  `context/xlang-channel-abi.md` §9a.
- **send_recv's default mode works whichever side starts first.** The Rust,
  Swift and Zig senders cleared the channel before connecting, which left an
  already running receiver with nothing; the channel is now cleared only by the
  `clear` verb. The Rust and Swift senders wait for a receiver in short slices,
  so SIGINT ends the wait (the Rust one could not be stopped). The C++ sender and
  receiver flush every line, so piped output is not delayed or lost, and the
  Swift sender pauses correctly for intervals of a second or more.
- **A C++ `recv` blocked during `disconnect()` returns an empty buffer.** It
  returned 64 zero bytes instead: `disconnect` quits the handle's waiter, whose
  wait returns at once without popping a message, and `recv` then read its
  zeroed message slot as a 64-byte fragment. A quit path that disconnects a
  receiver from another thread (the interactive C++ chat) printed them. `recv`
  now returns an empty buffer unless a message was actually popped.
- **Demos report a stall as a failure.** A pipeline sink, a bounded-buffer
  consumer or a channel-aggregator collector that timed out waiting printed a
  note and exited 0, in every port; it now exits 5. The Swift bounded buffer
  waited on its semaphores without a timeout and could hang forever; it now
  times out after 10 s like the other ports. The bounded buffer and channel
  aggregator gained a `clear` verb that removes their fixed-name IPC objects,
  and the Zig ports print their summaries sorted by producer, as the others do.
- **The realtime audio demo works across C++ and Rust.** The Rust host and
  service stamped and read the shared heartbeat with the wall clock
  (`SystemTime`), the C++ ones with `std::chrono::steady_clock`, so a mixed pair
  reported a heartbeat age of decades. Rust now uses
  `thoth_ipc::proto::steady_clock_ns()`, which reads the clock C++'s
  steady_clock does on each platform. The native Rust service ignored SIGTERM and
  was killed after the grace period without unregistering; it now stops. Both
  hosts remove their instances' ring and state segments at shutdown (the crash
  simulation SIGKILLs a primary, whose segments otherwise outlived the run and
  carried its counters into the next). The Rust audio hosts print roles, statuses
  and parameters in the C++ hosts' format.
- **The pipeline and bounded-buffer launchers run on Linux.** Both `run.sh`
  scripts required all four ports, Swift included, so they ran only on macOS. They
  now use whichever ports are built (the pipeline chains them source → stages →
  sink; the bounded buffer starts one producer per port) and say how to build a
  missing one. The bounded-buffer launcher clears the ring first.
- **The secure_pos demo no longer passes a role that saw nothing.** The POS
  role counted an empty receive (a timeout) as "sealed envelope observed", and
  the gateway reported a timeout as a rejected envelope; both now receive the
  raw envelope first and fail on a timeout. The Rust pinpad ignored a failed
  wait for its two subscribers and sent anyway; it now stops, as the C++ one
  does. secure_pos gained a `clear` verb. C++ secure_pos, the C++ audio hosts
  and the Swift demos line-buffer stdout, so their status lines appear
  immediately when piped instead of at exit.
- **A Rust semaphore on Linux stays shared until its last handle closes.**
  Dropping an `IpcSemaphore` unlinked its name unconditionally, so a later
  opener in any process got a fresh semaphore while the others kept the old one:
  in the cross-language bounded-buffer demo, every post after one producer exited
  went to a semaphore nobody waited on. Like C++, the semaphore now keeps a 1-byte
  shm segment whose ref counter counts the handles, and only the last one
  unlinks.
- **Rust `ShmHandle::grow` keeps the segment's contents on Linux.** It reopened
  the segment by name at the new size and then dropped the old handle; the ref
  counter trails the mapped size, so the old counter fell to zero and unlinked
  the name, and the next opener created a fresh, zeroed segment. It also waited
  out the 2 s creator-sizing timeout on every call. `grow` now enlarges the
  object in place and moves its reference to the new counter.
- **A Rust or Zig receiver no longer misses a message sent as it connects.**
  Between claiming its connection bit and reading the ring's write cursor, the
  receiver recorded its liveness owner, which on Linux reads `/proc/self/stat`.
  A sender that saw the bit could push in that window, and the receiver's cursor
  then started past the message; a release build lost it often enough to fail
  `route_send_recv_string` and `typed_route_send_raw_bytes` intermittently. The
  cursor is now read right after the bit is claimed, as C++ `queue::connect`
  does.
- **C++ `mutex::clear()` no longer frees a mutex other handles still use.** On
  Linux, macOS and other POSIX systems all handles to one name in a process
  share a cached node, and `clear()` destroyed it unconditionally. A route's
  sender and receiver share their waiter mutexes that way, so `clear()` on one
  of them left the other dangling: a heap use-after-free, seen as a segfault in
  `NotifyFd.EnqueueSignalsHandleAndRecvSucceeds` on Linux. When other in-process
  handles remain, `clear()` now releases only its own and unlinks the name,
  orphaning the node as `clear_storage` does. A cleared waiter's
  `notify`/`broadcast` is now a no-op, instead of a futex call through a
  released mutex (`fail condition broadcast[14]`/`[22]`).
- **The xlang runner probes conformance only on full harnesses.** `conform`
  cases were planned for every configured language, including the async-only
  C++ endpoints (`xasync`, `xcoro`), which have no `conform` verb; their empty
  traces failed as mismatches whenever a job configured them next to `cpp`.

## [0.7.0] - 2026-10-21

### Fixed
- **Large messages from a C++ sender survive the sender on Windows.** A message
  over 64 B is stored in a chunk segment (`CHUNK_INFO__<size>`), which a receiver
  maps lazily, on the first large message it reads. A Windows section is
  destroyed with its last handle (a POSIX segment exists until removed), so a
  sender that exited first took the payloads with it and the receiver read a
  fresh, zeroed segment: the right size, all-zero bytes. On Windows the C++
  sender no longer uses chunk storage: it splits a large message into 64 B
  fragments carried in the ring, which every receiver holds from connect — the
  wire form the Rust sender always uses, which every receiver already
  reassembles. POSIX keeps chunk storage, and receivers on every OS still read
  chunk-storage messages. The cost is on Windows only: a large message takes
  ⌈size / 64⌉ ring slots and pushes instead of one, the receiver copies it out
  of the ring instead of reading it in place, and a message over the ring's
  16 KiB (256 × 64 B) needs its receiver reading while it is sent, as with a
  Rust sender.
- **C++ async receivers no longer split fragmented messages.** The C++
  receiver reassembled fragments in a thread-local cache, but `async_recv` /
  `coro_recv` receive on the consumer thread first and then on the reactor
  thread, so a message whose fragments were popped on both arrived short (its
  tail only). The cache is now per handle. Fragmented messages come from any
  Rust sender and, now, from a C++ sender on Windows.
- **`new_delete_resource` frees over-aligned blocks correctly on MSVC.**
  `allocate()` used `_aligned_malloc` for alignments over `max_align_t` but
  `deallocate()` used `std::free`, corrupting the heap; `test-ipc` died in
  `memory_resource.new_delete_resource` on Windows.
- **Rust and C++ share mutexes and conditions on Linux.** The C++ Linux backend
  is the vendored alephzero robust PI futex mutex/condition (`a0_mtx_t` /
  `a0_cnd_t`, sync ABI backend 5 = `linux_a0`), but the Rust port used
  `pthread_mutex_t` / `pthread_cond_t` (backend 1 = `posix_pthread`) on every
  non-macOS Unix, so a Rust process opening a channel a C++ process created
  failed with `sync ABI mismatch for mutex: expected ... backend=1 ... payload=40
  but found ... backend=5 ... payload=24` (and the Linux xlang matrix with it).
  The Rust crate now implements the a0 protocol natively on Linux/Android
  (`platform/linux.rs`: raw futex syscalls over the abi.json `a0_mtx` /
  `a0_cnd` layouts, no C compiled) — the per-thread kernel robust list,
  FUTEX_LOCK_PI / FUTEX_UNLOCK_PI with the CAS fast paths, FUTEX_WAIT_REQUEUE_PI
  / FUTEX_CMP_REQUEUE_PI for the condition, re-registration after fork — with
  the C++ wrappers' semantics: owner-died recovery (consistent, unlock,
  re-lock), CLOCK_BOOTTIME millisecond timeouts, `u32::MAX` = no timeout.
  One difference: a condition wait that re-acquires the mutex from a dead
  owner makes it consistent (C++ leaves it owner-died, so its next unlock makes
  it unrecoverable). FreeBSD and other POSIX stay on `posix_pthread`, as in C++.
- **A killed sender no longer blocks its route for good.** A route's single sender
  was guarded by a one-byte `atomic_flag` in the ring trailer that only a clean
  shutdown cleared, so after a SIGKILLed (or crashed) sender every later sender on
  the channel failed with `que->ready_sending() == false` until `clear_storage()` —
  e.g. an app restarted with the same channel names could no longer publish. The
  flag is now a sole-owner record (`slot_owner {pid, start_tok}`, the reaper's
  layout) in the same place, claimed by CAS and taken over from a dead holder by
  the reaper's PID-liveness rule, never from a live one; the ring size is
  unchanged (`route_ring.sender_owner` in `abi.json`, xlang-channel-abi.md §2a).
  Unicast policies get the same for their sole receiver.
- **A zombie counts as dead.** `is_process_alive` treated a peer that had exited
  but was not yet reaped by its parent as alive: `kill(pid, 0)` succeeds for a
  zombie and its start token can no longer be read, which the conservative rule
  answered with "alive" — for as long as the parent lived (e.g. a parent that
  cannot `wait()` for a child a debugger traces). Every port now detects zombies
  (macOS `sysctl KERN_PROC_PID` → `p_stat == SZOMB`, Linux `/proc` state `Z`), so
  a zombie's receiver slot is reaped and its sender slot taken over.

- **The in-shm locks are taken the way C++ takes them, in every port.** The
  ring header's `lc_` and the chunk pool's `lock_` are `thoth::spin_lock`, an
  atomic test-and-set, on every target. Rust, Swift and Zig drove
  `os_unfair_lock` over the same bytes on Apple instead, following ABI notes that
  said so; the ports and the notes now agree.
- **Rust drops half-reassembled messages when a receiver disconnects**, as C++
  `disconnect_receiver()` does. The cache is keyed by the sender's message id, so
  a stale partial could be completed by a later message's fragments.
- **The Rust route slot is 16-byte aligned off Apple and MSVC.** `ElemT` was
  `align(8)` everywhere (88 bytes); C++ aligns the slot to `AlignSize`, which is
  16 on x86_64 Linux.
- **Linux builds of `ipc.cpp` compile again.** The SIGPIPE guard passed an `int*`
  to `sigtimedwait`, which takes a `siginfo_t*`.
- **The secure codec builds with MSVC.** `secure_codec.h` spells
  `(std::numeric_limits<T>::max)()` like the other public headers, so
  `<windows.h>`'s `max` macro no longer breaks it, and the Rust crate builds its
  secure-crypto C archive with `cc::Build` (cl.exe and lib.exe on MSVC) instead of
  hand-rolled `cc -c` and `ar`/`libtool` calls.
- **The Windows cross-language matrix runs, and passes.** It had stopped at
  configure since July (the unpinned Chocolatey OpenSSL moved to 4.0 and to
  another directory); it now installs OpenSSL 3.5 from slproweb, checked against
  slproweb's published SHA-256. The runner compares `conform` traces without the
  CRLF the Windows C++ harness writes, and keeps a killed holder's channel alive
  on Windows, where killing its only holder destroyed the segment the `reap`
  probes inspect.
- **The `audio_realtime` demo names the `thoth_ipc` target**, so configuring with
  demos (and the C/C++ CI) works again after the rebrand.

### Changed
- **Rust `IpcCondition::notify` / `broadcast` take the paired mutex**
  (`notify(&mtx)`, `broadcast(&mtx)`), as C++ `condition::notify(mutex&)` does:
  the Linux a0 condition requeues woken waiters onto the mutex futex, so it must
  know it. Other platforms ignore the argument. `Waiter` is unchanged.
- **Single-sender is enforced across languages.** Rust, Swift and Zig senders now
  claim and honour the route's sole-sender record (they ignored the C++ flag, so a
  port could send alongside a live sender on a single-writer ring). A second live
  sender on a route is refused: Rust `send` returns `ErrorKind::AddrInUse`, Swift
  throws `EBUSY`, Zig returns `error.SenderBusy`; `Route::sender_ready()` /
  `senderReady()` report (and retry) the claim, like C++ `ready_sending`.
- **ABI tooling checks field offsets.** `tools/abi check` compares every struct
  field offset the C++ dumper emits against `abi.json` (so far
  `route_ring.sender_owner`), not only sizes and constants.

### Added
- `abi.json` registers every sync backend id (`syncabi_backend_posix_pthread` = 1,
  `_apple_mach` = 3, `_win32` = 4, `_linux_a0` = 5, beside `_ulock` = 2); C++
  `sync_abi.h` static-asserts its `backend_id()` literals against them and the
  Rust port selects its backend from them.
- `abi.json` describes the sync payloads (ABI contract 1.1.0 → 1.2.0):
  `ulock_mutex` / `ulock_cond` (apple_arm64) and `a0_mtx` / `a0_cnd` (x86_64 =
  LP64 Linux), with protocols `ulock-mutex`, `ulock-cond`, `robust-list`,
  `pi-futex` and `requeue-pi-cond`. The schema gains a struct-level `targets`
  list and a `ptr` field type; C++ static-asserts `ulock_mutex_t` /
  `ulock_cond_t` / `a0_mtx_t` / `a0_cnd_t` and the Rust port its mirrors against
  the generated constants. The xlang runner accepts a protocol covered by the
  `primitives` scenario (`[scenarios.primitives].protocols`), since these run
  through the kernel and leave no byte trace for `conform`.
- **Opt-in C++20 named module `thoth.ipc`** (`THOTH_IPC_BUILD_MODULES`, off by
  default), re-exporting the core surface from the existing headers; builds under
  MSVC's C++20 modules.
- **An importable Zig module `thoth-ipc`**, and the Zig chunk allocator half
  (`poolPrepare` / `poolAcquire` / `acquireStorage`).
- `abi.json` describes `chunk_info_t`, and a field that runs a coordination
  algorithm carries a `protocol` tag naming its conformance probe
  (`abi/protocols.txt`); the xlang runner fails when a listed probe has no case.
- xlang `conform` scenario (each port's byte trace of `spinlock` / `idpool`
  sequences diffed against C++) and `contend` scenario (contended chunk-pool
  paths across languages); payload mismatches report where and how they differ.
- `sole-owner` conformance probe and the `reap` scenario's `shold` / `sclaim` cases
  (every holder × taker language pairing, dead / live / traffic), plus `zombie`
  cases for senders and receivers (the runner kills the holder without reaping it).

## [0.6.0] - 2026-07-18

### Changed
- **`elem_array` composes `conn_head` (was inheritance); ring-header offsets gated.**
  `elem_array` inherited `conn_head`, and a base class with data members made it
  non-standard-layout — so `offsetof` was ill-formed and the ring-header field
  offsets (`cc`/`lc`/`constructed`/`cursor`/`epoch`) were matrix-only. Unlike
  `msg_t`'s gratuitous base, `conn_head` is a real abstraction (the connection state
  machine + DCLP `init()`), so rather than flatten it away, its interface is now a
  `ConnHead` **concept** and `elem_array` *composes* the head (`conn_` member). The
  ring is byte-identical (the full matrix confirms) but `elem_array` is now
  **standard-layout**, so the ring-header field offsets are `offsetof`-`static_assert`ed
  against `thoth::abi` in `ipc.cpp` (via `conn_head_base`/policy field offsets +
  `elem_array::{conn,head}_offset()`).
- **Flattened `msg_t` and gated its field offsets.** `msg_t` was a two-level
  template inherited from cpp-ipc — a header-only `msg_t<0, AlignSize>` base and a
  `msg_t<DataSize, AlignSize>` derived adding the payload. The base was never used
  on its own, and the inheritance made `msg_t` non-standard-layout, so `offsetof`
  was ill-formed and its field offsets were matrix-only. Collapsed it into a single
  **standard-layout** struct (byte-identical — same fields/order/`alignas`, matrix
  confirms), so all five field offsets (`cc_id`/`id`/`remain`/`storage`/`payload`)
  are now `offsetof`-`static_assert`ed against `thoth::abi`.
- **POSIX shm-name shortening is now statically gated.** `abi.json` gained
  `shm_name_max` per target (macOS 31, else 0) and a `posix_golden` for the ring
  name (its 35-char form exceeds macOS `PSHMNAMLEN`, so it shortens to
  `/__THOTH_SHM___7d090bf7fa85c547` = `/<13 body chars>_<16-hex fnv1a of the
  /-name>`). The `abi` checker reference-implements `make_shm_name` and diffs it
  against the golden (both targets), and Rust/Swift/Zig each run their own
  `make_shm_name` against the generated `name_golden_ring_posix` — so the
  shortening algorithm is verified per port, previously matrix-only.
- **Every port is now a checked peer for the shm-name contract.** The `abi.json`
  `names[]` goldens are generated into each port's `abi_generated` module
  (`name_golden_*`, ring per-target), and Rust/Swift/Zig each carry a unit test
  asserting their name-builders produce the goldens for the canonical binding
  (`prefix=""`, `name="xchan"`) — so a wrong shm name is caught statically per
  port, not only by the behavioural matrix. Rust additionally **extracted** the
  ring/cc_id/msg_id/liveness names (previously inlined in two places, `open()` and
  `clear_storage()`) into shared builders; Swift gained a `msgIdName` builder for
  symmetry. C++ remains covered by the dumper's checked-peer gate.
- **Branded the shm-name wire namespace: `__IPC_SHM__` → `__THOTH_SHM__`,
  `ipc.ntf.` → `thoth.ntf.`, `ipcntf_` → `thothntf_`.** These are the byte-exact
  shm object-name / libnotify-key identifiers all four ports must agree on; they
  now say which library owns the memory (and avoid collision with other generic
  `IPC` users). **Wire/shm-breaking** — an old-name build won't rendezvous with a
  new one — but all ports move together, so the matrix stays byte-exact. The
  notify hash recomputes accordingly (`fnv1a_64("__THOTH_SHM__NOTIFY__xchan")` =
  `098e889ce378ae04`), cascading through the goldens, generated modules, the C++
  compile-time `static_assert`, and the port tests. Verified three ways: the xlang
  matrix, the naming gate (C++-built-name + template + FNV, both targets), and the
  C++ hash `static_assert`. (The `_CONN__` tags and the `"LISA"` SyncAbi magic are
  generic/derived, not `ipc`-branded — left unchanged.)
- **`make_prefix` → `make_public_abi_prefix`, decoupled from the `fmt` library.**
  The shm-name builder (part of the byte-exact cross-language wire contract) was
  renamed to flag its significance and reimplemented as plain `std::string`
  concatenation + `std::to_string` (byte-identical output — matrix stays green)
  instead of the heavyweight printf-emulation `fmt`. It is now **header-only**, so
  `abi/dump_abi.cpp` builds real shm names with no library link — upgrading the
  naming gate to a true **C++ checked peer** (the gate diffs C++'s actual
  `make_public_abi_prefix` output against the goldens, both targets). `fnv1a_64`/
  `to_hex` are now `constexpr`, and C++ `static_assert`s the notify hash at compile
  time. (Blanket header-only-ifying `fmt` itself was rejected — 39-TU blast radius
  with heavy `<sstream>`/`<iomanip>` deps; the `.cpp` split stays.)
- **ABI naming-template gate.** Each `abi.json` `names[]` template now carries a
  `golden` (its resolution for a canonical binding: `prefix=""`, `name="xchan"`,
  `data_length=64`, `align_size` per-target, `chunk_size=1024`). The `abi` checker
  resolves each template and diffs it against the golden, and **independently
  recomputes** the notify `fnv1a_64` in Rust to validate `notify_hash_xchan` — so
  the shm-name contract (`__THOTH_SHM__…`, `thoth.ntf.…`) can't drift silently in the
  spec. Runs as part of `cargo run -p abi -- check` (both targets in CI). The ring
  golden is per-target (`…__64__8` vs `…__64__16`). Per-port name-builder
  agreement remains behaviourally matrix-verified.
- **Per-target ABI generation (align 8 vs 16), deduplicated.** `abi.json` stores
  the align-dependent values as per-target maps `{apple_arm64, x86_64}`; only
  three actually differ (`route_elem.size` 88/96, `route_ring.size` 22784/24832,
  `chunk_header_size` 8/16). The generator now **deduplicates** — values identical
  across targets emit a single constant; differing ones emit `#[cfg]` (Rust) /
  `#if defined(__APPLE__) && defined(__aarch64__)` (C++) variants, while
  macOS-arm64-only Swift/Zig keep a single value. The C++ conformance probe +
  `static_assert`s now use the **runtime `AlignSize`** instead of a forced 8, so
  they check the platform's real layout; `cargo run -p abi -- check --target
  x86_64` cross-compiles the dumper (`-arch`, Rosetta) and gate-checks the
  align-16 target too (both pass 20/20). Closes the rust `TODO(xlang)` — the ring
  shm size is now per-target from the generated ABI.
- **ABI semantic gate now covers the message/chunk framing.** Extracted the
  ABI-impacting wire-layout types (`msg_t`, `chunk_t`, `chunk_info_t`,
  `chunk_header_size`) out of `ipc.cpp`'s anonymous namespace into a private
  header `src/thoth-ipc/msg_layout.h`, so `abi/dump_abi.cpp` can measure them as
  ground truth instead of leaving them matrix-only. The dumper's semantic gate
  now diffs **20** values against `abi.json` (was 15): added `msg_t.size`,
  `chunk_header_size`, `chunk_info_size`, `liveness_slot.size`, and
  `ring_header.size`. Closed real gaps by `static_assert`ing `syncabi_backend_ulock`
  (2 = apple ulock) against `thoth::abi`, and by fixing `elem_array::head_size` —
  it was the naïve `sizeof(base)+sizeof(policy)` (140, and unused) rather than the
  true `block_[0]` offset (192, since `head_` is cache-line-aligned), which is the
  ring-header size. The 5 remaining not-dumper-reachable values (types in heavier
  headers) are each a compile-time `static_assert` checked-peer vs `thoth::abi`.
- Renamed the internal `IPC_`-prefixed utility macros the earlier `LIBIPC_` →
  `THOTH_IPC_` pass didn't cover: `IPC_CONSTEXPR_`, `IPC_LOCK_PAUSE_`,
  `IPC_STBIND_`, `IPC_CONCEPT_` → `THOTH_IPC_*`. Also removed a stale dev artifact
  (`rust/thoth-ipc/test_yield.patch`, a yield-tuning experiment against a
  no-longer-existent `include/thoth_ipc/` path).

## [0.5.0] — 2026-07-18

### Added
- **Channel aggregator demo** in all four ports
  ([`cpp/thoth-ipc/demo/channel_aggregator/`](cpp/thoth-ipc/demo/channel_aggregator/),
  `rust/…/demo_channel_aggregator.rs`, `swift/…/DemoChannelAggregator`,
  `zig/…/demo_channel_aggregator.zig`) — a multi-writer `thoth::channel` fan-in:
  N producers `send` into one channel, a single collector reads the merged
  stream and tallies by producer (the pattern a single-writer `route` cannot
  express). Roles are mixable across languages — verified with a collector of
  one language receiving from producers of all four.
- **Polyglot pipeline demo** in all four ports (`demo/pipeline` / `demo_pipeline`)
  with a launcher [`cpp/thoth-ipc/demo/pipeline/run.sh`](cpp/thoth-ipc/demo/pipeline/run.sh) —
  a chain of single-writer→single-reader `thoth::route` hops, one process (and one
  language) per stage. `source`/`stage`/`sink` roles compose into
  `Zig → Rust → Swift → C++`, and the sink prints one line showing every language
  a message crossed (`item-0 [zig] -> rust -> swift -> [cpp sink]`).
- **Cross-language bounded buffer demo** in all four ports
  (`demo/bounded_buffer` / `demo_bounded_buffer`) with a launcher
  [`cpp/thoth-ipc/demo/bounded_buffer/run.sh`](cpp/thoth-ipc/demo/bounded_buffer/run.sh) —
  the classic producer/consumer over a shared-memory ring, coordinated by a named
  mutex (guards `head`) + two counting semaphores (`empty`/`full`). Verified with
  a Swift consumer draining C++/Rust/Zig/Swift producers at once through a 4-slot
  ring, exercising the sync primitives 0.4.0 made cross-language.

- **ABI walkthrough** [`abi/EXAMPLE.md`](abi/EXAMPLE.md) — a hands-on tour that
  traces one constant from `abi.json` into all four generated port modules and
  shows the gates (schema / C++ dump / staleness / compile-time `static_assert`)
  rejecting a deliberately-broken value, with copy-paste commands.

### Changed
- **Renamed `libipc` → `thoth-ipc` throughout the source tree** (the fork's
  vestigial upstream naming). The four per-language directories (`cpp/libipc/`,
  `rust/libipc/`, `swift/libipc/`, `zig/libipc/`) are now `*/thoth-ipc/`; the C++
  include dir `include/libipc/` → `include/thoth-ipc/` (so `#include
  "thoth-ipc/…"`); the Rust library `libipc` → `thoth_ipc` (`use thoth_ipc::`);
  and the Swift module `LibIPC` → `ThothIPC` (`import ThothIPC`). **Breaking**
  for downstream consumers' includes/imports.
- **Rebranded the internal `LIBIPC_` C++ macro namespace → `THOTH_IPC_`**
  (`THOTH_IPC_LOG`/`EXPORT`/`OS_*`/`CPP_*`/`UNUSED`/… and the CMake options/defines
  `THOTH_IPC_BUILD_TESTS`/`_DEMOS`/`_PROTO`/`_STDEXEC`/`_SECURE_OPENSSL`, plus the
  build env `THOTH_IPC_OPENSSL_PREFIX`). **Breaking** for downstream C++ that used
  the `LIBIPC_*` config macros or `-DLIBIPC_*` CMake flags.
- **Rebranded the shared `secure-crypto-c` C ABI**: its C symbols
  `libipc_secure_*` → `thoth_ipc_secure_*` and enum constants `LIBIPC_SECURE_*` →
  `THOTH_IPC_SECURE_*`; the include dir `include/libipc/` → `include/thoth-ipc/`
  (so `#include "thoth-ipc/proto/codecs/secure_crypto_c.h"`); the CMake target
  `libipc_secure_crypto_c` → `thoth_ipc_secure_crypto_c` (alias
  `thoth_ipc::secure_crypto_c`); and the Swift product/module `LibIPCSecureCryptoC`
  → `ThothIPCSecureCryptoC`. Wire-compatible (the AEAD envelope bytes are
  unchanged — only internal symbol names moved).
- **Renamed the C++ namespace `ipc::` → `thoth::`** (the last of the fork's
  `ipc`-prefixed public surface): `ipc::route`/`ipc::channel`/`ipc::sync::*`/
  `ipc::shm::*`/`ipc::async_recv()`/… are now `thoth::…`, and the generated ABI
  module `namespace ipc::abi` → `namespace thoth::abi`. **Breaking** for every C++
  consumer (a `namespace ipc = thoth;` alias restores source-compat if needed).
  Wire/shm-compatible — a pure C++-symbol rename with no ABI-byte impact (the full
  xlang matrix stays byte-exact across all four ports).
- **Renamed the runtime wire/shm identifiers `libipc` → `thoth_ipc`**: the
  cross-process sync sidecar shm-object names `__libipc_sync_abi_mutex` /
  `_condition` → `__thoth_ipc_sync_abi_*` (byte-exact across all four ports), and
  the Swift port's internal C shim `libipc_shm_open_*` / `libipc_wifexited` / … →
  `thoth_ipc_*` (header `libipc_shim.h` → `thoth_ipc_shim.h`). The sync sidecar
  names are a **wire/shm break** — a build using the old names will not rendezvous
  with a new one — but all four ports move together, so the xlang matrix stays
  byte-exact (`primitives` 64/64). The Swift C shim is process-internal (no wire
  impact). *(The "`libipc_<hex>` shm-name format" noted as unchanged in earlier
  entries never existed as a literal — the shortened form is
  `/<truncated-original-name>_<hex>`, carrying no `libipc` string.)*
- **The sync sidecar shm-name suffixes are now generated from `abi.json`, not
  hand-maintained.** Added `sync_abi_suffix_mutex` / `sync_abi_suffix_condition`
  string constants to `abi/abi.json` (ABI contract `1.0.0` → `1.1.0`, a
  backward-compatible addition); all four ports re-source them from their
  generated `abi_generated.*` module instead of hard-coding the literal, so a
  future change is one spec edit + regenerate and CI's staleness gate guarantees
  no port drifts. Motivated by this rename having required five hand-edits of a
  byte-exact wire string across four languages — exactly the drift the ABI
  single-source-of-truth exists to prevent. (The C++ `_unknown` sentinel and the
  Swift test keep independent literals by design.)
- **Deliberately unchanged**: the shm-name templates that were never
  `libipc`-prefixed (`__IPC_SHM__…`, `ipc.ntf.…`), the `"LISA"` SyncAbi wire magic
  (and its "LibIPC Sync ABI" acronym derivation), and upstream cpp-ipc / libipc
  attribution in `LICENSE`, `NOTICE` and `// Port of …` comments.
- **Renamed the C++ CMake library target `ipc` → `thoth_ipc`** (the nested
  `project(ipc)` in `src/CMakeLists.txt` was the last `ipc` build identifier). The
  built artifact is now `libthoth_ipc.a` (was `libipc.a`), and the exported
  package target is `thoth-ipc::thoth_ipc`. **Breaking** for downstream that
  linked `thoth-ipc::ipc` or referenced `libipc.a`. In-tree consumers
  (tests/demos/benches) and CI updated; the `xlang_ipc` test-harness executable
  name is unchanged.
- `IpcMutex.openSync(name:)` (Swift) is now `public`, mirroring
  `Route.connectBlocking` — a blocking mutex open for non-async call sites.

## [0.4.0] — 2026-07-18

### Added
- **Multi-writer `ipc::channel` across all four ports.** Zig, Rust and Swift
  gained the multi-producer broadcast ring (96-byte commit-flag slots, the
  shared `AC_CONN__` message-id counter, the channel `rc_` region packing),
  byte-exact with C++. The `channel` matrix scenario — every two-language sender
  pair into every reader — is now expected-pass (72/72). See
  [`context/xlang-channel-multiwriter-rfc.md`](context/xlang-channel-multiwriter-rfc.md).
- **Language-neutral ABI, consumed by every port.** `abi/abi.json` (+ JSON
  Schema) is the single source of truth; `tools/abi` validates it against a C++
  conformance dump and generates a per-language module. Zig, Rust and Swift
  re-source their transport / sync / secure / liveness / chunk constants from
  their generated module; C++ is a compile-time *checked* peer
  (`static_assert` against `ipc::abi`). See [`abi/README.md`](abi/README.md).

### Fixed
- **Every cross-language parity gap closed — the matrix expected-failure list is
  now empty.**
  - **C++↔port semaphores** now interoperate: the ports' macOS semaphore was
    reimplemented from POSIX `sem_open` to a shared-memory ulock counter
    byte-exact with C++ `apple/semaphore_impl.h` (a `sem_open` object cannot
    share state with C++'s shm word). Also fixes a doubled `_s` in the object
    name.
  - **Rust Apple mutex** now maintains C++'s trailing cross-process `acc_` shm
    ref counter, so a cpp/swift prober no longer mis-detects "first opener" and
    re-initialises a live rust-held lock (mutual-exclusion violation).
  - **Chunk-pool clear race** eliminated: the ports no longer unlink the
    prefix-global `CHUNK_INFO__<size>` pools in a per-channel `clearStorage`
    (matching C++), which under parallel matrix runs could split a concurrent
    channel's writer and reader across shm inodes (the intermittent secure
    `cpp→zig` "open failed").
  - **Rust slot payload soundness**: the route/channel ring slots wrap their
    `data_` in `UnsafeCell` so the in-shm interior mutation through a shared
    `&self` is no longer UB (`#[repr(transparent)]`, layout unchanged).
- Corrected a `syncabi_magic` typo in `abi.json` (`"LEYA"` → `"LISA"`,
  `0x4C495341`) that the new C++ ABI `static_assert` surfaced.

## [0.3.0] — 2026-07-17

### Added
- **Native Zig port** [`zig/thoth-ipc/`](zig/thoth-ipc/) — an independent
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
  [`secure_pos`](cpp/thoth-ipc/demo/secure_pos/) (C++ + Rust, wire-identical
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
