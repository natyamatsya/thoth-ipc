# Cross-platform parity: what's missing off macOS, and how to close it

**C++↔Rust are now at full parity on macOS, Linux, and Windows** — the byte-exact
wire ABI, Layer-1 notify, Layer-2 async (C++ stdexec **and** coroutines; Rust
`AsyncRoute`), and the dead-connection reaper are implemented and **matrix-verified**
on all three via `tools/xlang-runner` in CI (Windows in full only since
2026-10-21 — footnote 2). Swift adds a third language on macOS
(it is a macOS-only SwiftPM package — out of scope on Linux/Windows). FreeBSD /
other POSIX remain untested. The open items are that last row plus native-runtime
CI for the new `clear_storage` orphan-safety row (implemented + locally verified;
see the Remaining section).

## Status matrix

Legend: ✅ done + CI-verified · 🧪 implemented + unit-test-verified locally,
native-runtime CI pending · — n/a.

| Capability | macOS | Linux | Windows |
|---|---|---|---|
| Wire ABI ring/msg_t (C++↔C++) | ✅ | ✅ | ✅ |
| Wire ABI **byte-exact** C++↔Rust (ring offsets + message interop) | ✅ | ✅¹ | ✅² |
| Byte-exact **spin_lock** (`lc_`@4) / chunk `lock_`@36 in the ports | ✅ | ✅¹ | ✅² |
| Chunk storage (>64B) C++↔Rust | ✅ | ✅¹ | ✅² |
| Layer-1 notify (source+sink) — C++ | ✅ libnotify | ✅ FIFO | ✅ Event² |
| Layer-1 notify — Rust | ✅ | ✅ FIFO | ✅ Event² |
| Layer-1 notify — Swift | ✅ | — | — |
| Reactor — C++ | ✅ kqueue | ✅ epoll | ✅ thread-pool² |
| Async recv — C++ stdexec `async_recv` + coroutines | ✅ | ✅ | ✅² |
| Async recv — Rust `AsyncRoute` | ✅ `AsyncFd` | ✅ `AsyncFd` | ✅ thread-pool² |
| Async recv — Swift `AsyncRoute` (`DispatchSource`) | ✅ | — | — |
| Dead-connection reaper (PID-liveness + start-token) | ✅ | ✅ | ✅² |
| Sync mutex/condition backend C++↔Rust (sync ABI id) | ✅ ulock (2) | 🧪⁵ a0 (5) | ✅ win32 (4)² |
| Sync `clear_storage` orphan-safety (double-owner) — C++ | 🧪³ | 🧪³ | —⁴ |
| Sync `clear_storage` orphan-safety (double-owner) — Rust | 🧪³ | 🧪³ | —⁴ |
| Sync `clear_storage` orphan-safety (double-owner) — Swift | 🧪³ | — | — |
| xlang CI matrix (sync / async / reap) | ✅ full 3-lang + coro | ✅ C++↔Rust | ✅ C++↔Rust² |

Footnotes / code pointers:
1. **Linux ports: done.** The Rust ring `lc_`@4 and chunk `lock_`@36 are now an
   `AtomicU32` running C++'s generic `spin_lock` protocol (an `atomic<u32>`
   test-and-set spin, `rw_lock.h:117`) on non-Apple targets, so the DCLP first-init
   and chunk-pool critical sections serialise byte-for-byte with a C++ peer. The
   layout is proven at compile time (the `offset_of!`/`size` asserts run for the
   Linux target) and message + chunk-storage interop runs in CI (`matrix-linux`,
   sizes incl. 200/3000 B). Also fixed a latent bug that made the Linux FIFO
   notify backend fail to compile (`sigtimedwait` takes `*mut siginfo_t`).
2. **Windows ports: done** (2026-07-12), **matrix-verified 2026-10-21**. All six
   phases of [`windows-parity-rfc.md`](windows-parity-rfc.md) landed in July, but
   `matrix-windows` never got past installing OpenSSL from then until October, so
   the full matrix had not actually run on Windows; the July counts (sync 16/16,
   reap 8/8, async 36/36) predate most of today's scenarios. Once it ran
   (2026-10-20) it was 165/175, and `async-matrix-windows` 53/54
   (intermittently). Three Windows gaps, all fixed on `fix/windows-xlang`:
   - **conform (5 probes):** a harness artefact, not a port divergence — the C++
     harness writes stdout in text mode on Windows (CRLF) and the Rust one LF;
     the traces were otherwise identical. The runner now compares them without
     line endings.
   - **Chunk storage (payload mismatch, C++ sender only):** a Windows section is
     destroyed with its last handle, where a POSIX segment exists by name until
     removed. A C++ sender that exited before its receivers mapped a chunk
     segment (they map it lazily, on the first large message) took the payloads
     with it; the receiver's open created a fresh, zeroed section, so a >64 B
     message arrived with the right size and zero bytes. The C++ sender now
     duplicates the segment's section handle into every receiver of the message
     before publishing it (`shm::share_with`, `DuplicateHandle`, receivers found
     via the LV_CONN__ owner table). The Rust sender fragments large messages
     and never used chunk storage, so only C++ was wrong.
   - **reap `probe-noreap` (4 pairings):** the same section lifetime, in the
     test: killing the only process holding a channel destroyed the dead slot
     the probe was meant to see. Neither port's liveness code was at fault. It
     also meant every other "dead"/"zombie" reap case, and primitives' "killed
     holding mutex", passed on Windows without exercising the reaper or
     `WAIT_ABANDONED`. On Windows the runner now runs a **keeper** (the `keep`
     verb: the channel's segments and mutex held open, no slot taken) beside a
     holder it kills, so those cases test on Windows what they test on POSIX.
   With those, run 39515837537 is green on every job: `matrix-windows` 175/175
   (conform 5, sync 28, contend 4, fanout 4, channel 6, reap 36, primitives 16,
   typed 12, secure 32 + badkey 8 + negative 24) and `async-matrix-windows`
   54/54, with Linux and macOS green in the same run.
   The generic `atomic<u32>` spin_lock (same as Linux) gives byte-exact ABI;
   Layer-1 notify is a named auto-reset Event per slot; the reactor is a thin
   registry over the Win32 thread pool (`RegisterWaitForSingleObject`); the reaper
   uses `GetProcessTimes` for the start token; and async recv rides `wait_handle_t`
   (a `HANDLE`) — see [ADR-0005](../doc/adr/0005-cross-platform-async-readiness-handle.md)
   and [`cpp/thoth-ipc/doc/windows-technical-notes.md`](../cpp/thoth-ipc/doc/windows-technical-notes.md).
3. **`clear_storage` orphan-safety** (2026-07-14). Clearing a named mutex while
   a handle is still open in-process must orphan (not destroy) the segment; see
   [`refcount-aware-clear-storage-rfc.md`](refcount-aware-clear-storage-rfc.md).
   Mutex-scoped: C++ `condition`/`semaphore` hold `shm::handle` by value and are
   already unlink-safe, so the row tracks the mutex only. Verified by **local
   unit tests**, not the xlang matrix (this is per-process behavior, not a wire
   interop): C++ `MutexTest.ClearStorageOrphans{LiveHandle,SharedNode}` (macOS
   285/285 incl. an ASan+UBSan run of the double-owner sequence); Rust
   `clear_storage_orphans_{live_handle,shared_node}` (full suite green); Swift
   `clearStorageOrphansLiveHandle` (mutex suite 15/15). The C++ suite runs in the
   `c-cpp.yml` `test-ipc` step on ubuntu/macOS/windows but only on
   `workflow_dispatch`/PR (push triggers off), and **posix/linux C++ is so far
   only type-checked locally** (posix-shim / a0-mock) — native runtime lands on
   the next ubuntu dispatch. Rust/Swift unit tests are **not** in CI at all (CI
   builds only the xlang binary), so those cells are local-only. Rust `posix.rs`
   was already correct (`cached_shm_purge`); only `apple.rs` changed.
4. **Windows mutex `clear_storage` is a no-op** — Windows uses a named kernel
   mutex object with no per-process pointer cache, so there is nothing to orphan
   (matches the C++ Windows backend). n/a.
5. **Linux sync backend** (2026-10-21). C++ Linux runs the vendored alephzero
   futex mutex/condition (`a0_mtx_t`/`a0_cnd_t`, backend 5); the Rust port used
   `pthread_*` (backend 1), so every C++↔Rust channel open on Linux failed the
   sync ABI guard (every pairing opens a waiter mutex + condition), which
   qualifies the "Linux: DONE" section below; `matrix-linux` has been red since
   its last runs (2026-07-12).
   Rust now implements the a0 protocol natively (`src/platform/linux.rs`, over
   the abi.json `a0_mtx` / `a0_cnd` layouts; no C compiled). Compile- and
   link-checked for `x86_64-unknown-linux-gnu`; runtime pending the next
   `matrix-linux` run.

## How to reestablish parity

### Linux — DONE
Byte-exact spin locks landed: `RingHeader.lc`@4 and `ChunkInfo.lock_`@36 are now
an `AtomicU32` running C++'s `atomic<u32>` test-and-set spin on non-Apple targets
(`while swap(1)!=0 { yield }` / `store(0)`), so the DCLP first-init and chunk-pool
critical sections serialise byte-for-byte with a C++ peer. Verified by the Linux
compile-time layout asserts + the `matrix-linux` CI (message + chunk-storage
interop). Also fixed the Linux FIFO notify compile bug (`sigtimedwait`).
Notify (FIFO), async (epoll + tokio `AsyncFd`), and the reaper (`kill(pid,0)` +
`/proc/<pid>/stat`) already worked and are CI-covered. **Linux C++↔Rust is now at
full parity.** (Swift remains macOS-only.)

### Windows — DONE
All three layers landed and are matrix-verified on `windows-latest`/MSVC
(`matrix-windows` 175/175, `async-matrix-windows` 54/54, run 39515837537,
2026-10-21; footnote 2 has what it took):
1. **Liveness (reaper):** `is_process_alive` via
   `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` + `GetExitCodeProcess`;
   `start_token` via `GetProcessTimes` creation `FILETIME` packed as u64 (the §9
   Windows row). C++ `liveness.h` + Rust `liveness.rs` (fixing the Rust
   `self_pid==0` bug).
2. **Notify (Layer 1):** a named auto-reset Event per reader slot
   (`Local\thothntf_<hash>_<slot>`) — `SetEvent` on enqueue, the sink waits on its
   `HANDLE`. C++ `notify.h` `WINEVENT` backend + Rust `notify.rs` Windows backend.
3. **Reactor + async (Layer 2):** a thin registry over the Win32 thread pool
   (`RegisterWaitForSingleObject` / `UnregisterWaitEx`) in `reactor.cpp`; the
   `int fd` → `wait_handle_t` widening across `reactor.h`/`async_recv.h`/
   `coro_recv.h` (ADR-0005) let C++ stdexec `async_recv` **and** both coroutine
   paths work unchanged. Rust `AsyncRoute` drives the event `HANDLE` via a
   thread-pool wait + a tokio `Notify`.
4. **CI:** `matrix-windows` + `async-matrix-windows` jobs run the C++↔Rust
   matrices on `windows-latest` (`workflow_dispatch`/PR, since push triggers are
   off). Byte-exact ABI comes free from the generic `atomic<u32>` spin_lock.
5. **Segment lifetime:** Windows named sections and kernel objects die with
   their last handle; POSIX segments persist until removed. Anything that relies
   on shared state outliving the process that wrote it has to hand a handle to
   a process that lives on. Today that is chunk storage (the C++ sender
   duplicates each chunk segment into its receivers, once per sender process
   and receiver incarnation; the duplicate stays open in the receiver until it
   exits, so a long-lived receiver holds one handle per segment per sender
   process it has served) and the xlang runner's keeper for the kill cases.
   The ring itself is safe: a sender waits for a receiver, which holds it.

### FreeBSD / other POSIX
Likely close (FIFO notify, kqueue reactor, and `kill(pid,0)` are BSD-native), but
`start_token` needs a BSD source (`kinfo_proc` / `sysctl KERN_PROC_PID`) and shm
names/`AlignSize` need per-target checks. Validate by adding the target to the
byte-exact asserts + a CI run before claiming parity.

## Remaining
1. ~~**Linux spin_lock byte-exactness**~~ — **done.**
2. ~~**Windows liveness / notify / reactor / async**~~ — **done** (all six RFC
   phases; matrices green on `windows-latest`/MSVC since 2026-10-21, after the
   chunk-segment lifetime fix and the reap keeper — footnote 2).
3. **FreeBSD / other POSIX validation** — open item (medium; mostly a
   BSD `start_token` source + a CI run). Swift stays macOS-only.
4. **`clear_storage` orphan-safety native runtime on Linux** — small: the fix is
   implemented and macOS-runtime + ASan proven, but the posix/linux C++ path is
   so far only type-checked locally. Dispatch the `c-cpp.yml` ubuntu `test-ipc`
   job to promote the C++ Linux cell from 🧪 to ✅ (footnote 3).
