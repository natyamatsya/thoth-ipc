# ADR-0001: Cross-language synchronization backend contract

- Status: Accepted
- Date: 2026-03-03
- Owners: libipc maintainers

## Context

`libipc` synchronization primitives are shared across language boundaries (C++, Rust, Swift) via named shared memory objects. On macOS, we currently have diverging backend choices:

- C++ selects Apple backend variants at compile time (`ulock` or `mach`) for both mutex and condition.
- Rust now selects Apple `ulock` mutex on macOS.
- Rust condition remains POSIX `pthread_cond_t` on Unix and assumes the mutex pointer is a `pthread_mutex_t`.
- Swift mutex/condition are currently POSIX `pthread_*` based on Darwin.

When two languages open the same named primitive with different backend assumptions, behavior is undefined (e.g. invalid pointer casts, deadlocks, missed wakeups, or memory corruption).

## Decision

We standardize synchronization interop with an explicit cross-language contract.

### 1) Backend is part of ABI

Each sync primitive has an ABI identity:

- `backend_id` — registered in `abi/abi.json` (`syncabi_backend_*`):
  `posix_pthread` = 1, `apple_ulock` = 2, `apple_mach` = 3, `win32` = 4,
  `linux_a0` = 5
- `abi_version_major`
- `abi_version_minor`
- `primitive_kind` (`mutex`, `condition`)
- `payload_size`

#### ABI versioning policy

- **Library version != ABI version.**
  Two binaries compiled from different libipc releases may interoperate if ABI
  identity matches.
- **Major mismatch is always incompatible.**
  Open must fail with an explicit ABI mismatch error.
- **Minor mismatch is initially treated as incompatible (fail-fast).**
  We intentionally start strict to avoid silent semantic drift in synchronization
  behavior. Relaxing minor compatibility is allowed later only with explicit
  compatibility tests and rules.

### 2) Backend selection is paired

Backend selection must be performed as a single profile for the synchronization family, not per primitive:

- `mutex` and `condition` must always come from the same backend profile.
- A language binding may not mix `apple_ulock` mutex with POSIX condition (or vice versa).

### 3) Runtime validation on open

On `open/create`, implementations must validate that the named object's ABI identity matches the caller expectations.

- Creator writes ABI identity metadata.
- Joiner validates metadata before use.
- Mismatch returns a deterministic backend/ABI mismatch error (fail fast), not undefined behavior.

For mixed-version clients (e.g. C++ and Rust built against different library
releases), validation is based on ABI identity, not package version strings.

### 4) macOS backend profiles

We define explicit macOS profiles:

- `apple_ulock` (default for non-App-Store builds)
- `apple_mach` (App-Store-safe profile)

Current implementation status:

- C++ can be built as either `apple_ulock` or `apple_mach`.
- Rust and Swift currently implement the `apple_ulock` profile only.
- Mixed deployments where C++ uses `apple_mach` and Rust/Swift use `apple_ulock`
  are intentionally rejected by the sync ABI guard at open-time.

If `apple_mach` is selected in one language, all participating language runtimes in that deployment must use `apple_mach` for synchronization primitives.

### 5) Linux and other POSIX profiles

The backend follows the C++ platform classification (`detect_plat.h`,
`sync_abi.h` `backend_id()`):

- **Linux (incl. Android, `THOTH_IPC_OS_LINUX`) -> `linux_a0` (5).** The mutex
  is the vendored alephzero robust, priority-inheriting, error-checking futex
  mutex `a0_mtx_t` (`{next, prev, ftx}`, 24 B on LP64) and the condition is
  `a0_cnd_t` (a `u32` futex word, 4 B), vendored in
  `cpp/thoth-ipc/src/thoth-ipc/platform/linux/a0`. Like every shared protocol,
  it is a contract a port implements natively, not code it links: the layouts
  are abi.json `a0_mtx` / `a0_cnd`, the field protocols (`robust-list`,
  `pi-futex`, `requeue-pi-cond`) are listed in `abi/protocols.txt` and proved by
  the xlang `primitives` scenario, and the Rust crate ports `mtx.c` / `ftx.h`
  operation by operation in `platform/linux.rs` (FUTEX_LOCK_PI / FUTEX_UNLOCK_PI
  behind CAS fast paths, FUTEX_WAIT_REQUEUE_PI / FUTEX_CMP_REQUEUE_PI, the
  per-thread kernel robust list), as `platform/apple.rs` ports the ulock mutex.
  Because waiters are requeued onto the mutex futex, notify/broadcast take the
  paired mutex in every language. Timeouts are milliseconds against
  CLOCK_BOOTTIME.
- **FreeBSD, QNX and other POSIX -> `posix_pthread` (1)**: process-shared,
  robust `pthread_mutex_t` / process-shared `pthread_cond_t`.

Status: C++ and Rust implement `linux_a0` (C++ through the vendored a0 C, Rust
natively). (Until 2026-10 the Rust port used
`posix_pthread` on Linux, so every C++<->Rust channel on Linux failed the open
with a backend 1 vs 5 mismatch.) Swift and Zig are macOS-only and implement
`apple_ulock` only.

### 6) Interop tests are required

CI must include cross-language tests for every supported profile:

- C++ <-> Rust
- C++ <-> Swift
- Rust <-> Swift

for lock/unlock, wait/notify/broadcast, timeout semantics, and dead-owner behavior where applicable.

## Consequences

### Positive

- Prevents silent backend drift across languages.
- Converts undefined behavior into explicit runtime errors.
- Gives a stable path for adding new backends without accidental interop breakage.

### Trade-offs

- Slightly more metadata and validation logic in open paths.
- Requires coordinated rollout in all language bindings.
- Existing stale SHM objects created by old layouts may need cleanup on upgrade.

## Implementation plan (phased)

1. **Phase A (safety first):**
   - Make Rust condition backend match Rust mutex backend on macOS.
   - Remove/forbid invalid pthread condition path against non-pthread mutex backend.

2. **Phase B (ABI contract):**
   - Introduce sync ABI metadata and open-time validation in C++, Rust, Swift.
   - Add structured mismatch error codes/messages.

3. **Phase C (profile parity):**
   - Provide explicit profile wiring in all languages (`apple_ulock` / `apple_mach`).
   - Ensure deployment chooses one profile consistently.

4. **Phase D (verification):**
   - Add cross-language interop test matrix in CI for each profile.

## Alternatives considered

1. **Keep backend selection language-local**
   - Rejected: causes runtime UB when names collide across language runtimes.

2. **Force one global backend forever**
   - Rejected: blocks App-Store-safe deployment constraints and future backend evolution.

3. **Rely only on documentation (no runtime checks)**
   - Rejected: too fragile; drift is hard to detect and failures are non-deterministic.
