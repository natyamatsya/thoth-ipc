# Swift libipc — Porting Roadmap

This document tracks the port of the C++ libipc library to Swift, following the
same structure and phasing used for the Rust port (`rust/libipc/`).

The goal is **binary compatibility**: a Swift sender must be able to communicate
with a C++ or Rust receiver without any bridging layer, because all three
implementations share the same shared-memory layout, wire format, and
synchronisation protocol.

---

## Guiding principles

- **No C bridging on the data path.** The Swift port reimplements the primitives
  natively, just as the Rust port does. `Foundation` and Darwin system calls are
  used directly where needed.
- **Symmetric module structure.** Every Rust module has a Swift counterpart at
  the same conceptual level.
- **Test-first per phase.** Each phase ends with a test suite that mirrors the
  Rust test files. Interop tests (Swift ↔ C++ / Swift ↔ Rust) are added as soon
  as the transport layer is complete.
- **macOS first, Linux later.** The Rust port targets macOS and Linux. The Swift
  port starts on macOS (Darwin POSIX) and extends to Linux (Swift on Linux /
  FoundationEssentials) in a later phase.

---

## Modern Swift idioms

These conventions apply across all phases. They are not optional style
preferences — they define what "idiomatic Swift" means for this codebase.

### Structured concurrency (`async`/`await`, `Actor`)

- Blocking operations (`lock`, `recv`, `wait`) are exposed as `async` functions
  using `withCheckedThrowingContinuation` or run on a custom executor, never
  blocking the cooperative thread pool.
- Shared mutable state (e.g. the process-local shm cache) is encapsulated in an
  `actor`, replacing the Rust `Mutex<HashMap<…>>` pattern.
- Long-running service loops (`ServiceGroup` health checks, waiter loops) are
  `Task`s, cancellable via structured cancellation.

```swift
// ✅ idiomatic
func recv(timeout: Duration) async throws -> [UInt8]

// ❌ avoid — blocks a thread
func recv(timeoutMs: UInt64) -> [UInt8]?
```

### `Sendable` and data-race safety

- All types that cross actor or task boundaries conform to `Sendable`.
- Shared-memory handles (`Shm`, `IpcMutex`, etc.) are `@unchecked Sendable`
  with an explicit safety comment where the invariant is upheld by the
  underlying OS primitive rather than Swift's type system.
- The codebase compiles clean under `StrictConcurrency = complete`.

### Typed errors (`throws(E)`)

- Every throwing function declares a concrete error type using Swift 6 typed
  throws rather than `any Error`:

```swift
enum IpcError: Error { case timeout, invalidHandle, nameTooLong(String) }

func lock(timeout: Duration) async throws(IpcError)
```

### `~Copyable` for RAII handles

- `Shm`, `IpcMutex`, `IpcSemaphore`, `IpcCondition`, `Channel`, `Route` are
  `~Copyable` (`consuming` / `borrowing` parameter ownership), mirroring the
  Rust ownership model and preventing accidental handle duplication.
- `ScopedAccess` becomes a `~Copyable` struct with a `deinit` that calls
  `unlock()`.

```swift
struct ScopedAccess: ~Copyable {
    private let mutex: borrowing IpcMutex
    deinit { mutex.unlock() }
}
```

### `RawRepresentable` and `@frozen` for wire types

- Enums and structs that map directly to shared-memory layouts are `@frozen`
  and `RawRepresentable` with explicit raw types to guarantee ABI stability.
- Fixed-width integer types (`UInt32`, `UInt64`, `Int32`) are used everywhere
  on the wire — never `Int` or `UInt`.

### `UnsafeRawBufferPointer` / `UnsafeMutableRawBufferPointer` for shm access

- Direct shared-memory reads and writes use `withUnsafeMutableBytes` /
  `withUnsafeBytes` scoped accessors, never raw pointer arithmetic outside a
  clearly delimited unsafe block.
- Atomic operations use `Atomics` from
  [swift-atomics](https://github.com/apple/swift-atomics) (`ManagedAtomic`,
  `UnsafeAtomic`) rather than hand-rolled loads/stores.

### `Duration` and `Clock` instead of millisecond integers

- All timeout parameters use `Swift.Duration` (Swift 5.7+) and are measured
  against `ContinuousClock`, matching the Rust `Duration` / `Instant` pattern.
- Internal conversion to `timespec` / `mach_timespec_t` is encapsulated in a
  private extension.

### Swift Testing framework

- All tests use the **Swift Testing** framework (`import Testing`, `@Test`,
  `#expect`, `#require`) introduced in Swift 6, not XCTest.
- Parameterised tests (`@Test(arguments:)`) replace the Rust `#[test]` +
  loop pattern used in stress and property tests.

### Package structure

```text
swift/libipc/
  Package.swift
  Sources/
    LibIPC/          ← library (phases 1–4)
      Platform/      ← Darwin-specific shm / pthread wrappers
      Sync/          ← IpcMutex, IpcSemaphore, IpcCondition, SpinLock, RwLock
      Transport/     ← IpcBuffer, Waiter, Circ, Channel, Route, ChunkStorage
      Proto/         ← ShmRing, ServiceRegistry, ProcessManager, TypedChannel
      RT/            ← RtPriority, ServiceGroup
  Tests/
    LibIPCTests/     ← mirrors tests/ in rust/libipc
  Sources/
    demo-send-recv/  ← executable targets (phase 5)
    demo-chat/
    demo-msg-que/
    demo-audio-service/
    demo-audio-host/
    demo-rt-audio-service/
    demo-rt-audio-host/
```

### Minimum toolchain

- **Swift 6.0** — required for typed throws, `~Copyable`, strict concurrency,
  and Swift Testing.
- **swift-atomics 1.2+** — for `ManagedAtomic` / `UnsafeAtomic`.
- **flatbuffers** Swift runtime (phase 3+) — via SPM dependency on
  `google/flatbuffers`.

---

## Phase 1 — Platform & synchronisation primitives

*Mirrors: `shm.rs`, `platform/posix.rs`, `mutex.rs`, `semaphore.rs`,
`condition.rs`, `spin_lock.rs`, `rw_lock.rs`, `scoped_access.rs`,
`shm_name.rs`*

*C++ headers: `shm.h`, `mutex.h`, `semaphore.h`, `condition.h`, `rw_lock.h`*

### 1.1 Shared memory (`Shm`)

- `shm_open` / `mmap` wrapper with `open(name:create:size:)` and `close()`
- File-backed fallback (`LIBIPC_USE_FILE_SHM` equivalent) via `open(2)` + `mmap`
- macOS `PSHMNAMLEN` name-length constraint → FNV-1a hash truncation
  (same algorithm as `shm_name.rs` / `shm_name.h`)
- Process-local shm cache (required on macOS for `PTHREAD_PROCESS_SHARED` —
  all threads in a process must map the same virtual address)

### 1.2 `ShmName` — name hashing

- FNV-1a 32-bit hash, same constants as C++ and Rust
- `makeShm(name:)` → `"/libipc_<hex>"` with length capping

### 1.3 `IpcMutex`

- `pthread_mutex_t` in shared memory with `PTHREAD_PROCESS_SHARED`
- `lock()`, `tryLock()`, `lock(timeout:)`, `unlock()`, `clearStorage()`

### 1.4 `IpcSemaphore`

- macOS: `sem_open` (named POSIX semaphore)
- `wait(timeout:)`, `post(count:)`, `clearStorage()`

### 1.5 `IpcCondition`

- `pthread_cond_t` in shared memory with `PTHREAD_PROCESS_SHARED`
- `wait(mutex:timeout:)`, `notify()`, `broadcast()`, `clearStorage()`

### 1.6 `SpinLock` / `RwLock`

- Atomic-based spin lock matching the C++ `spin_lock.h` layout
- Reader-writer lock matching `rw_lock.h`

### 1.7 `ScopedAccess`

- RAII lock guard wrapping any `IpcMutex`

### Phase 1 tests

Mirror `test_shm.rs`, `test_mutex.rs`, `test_semaphore.rs`,
`test_condition.rs`, `test_spin_lock.rs`, `test_rw_lock.rs`.

---

## Phase 2 — Transport layer

*Mirrors: `buffer.rs`, `waiter.rs`, `circ.rs`, `channel.rs`,
`chunk_storage.rs`*

*C++ headers: `buffer.h`, `ipc.h` (`route`, `channel`)*

### 2.1 `IpcBuffer`

- Fixed-size slot buffer in shared memory
- Matches the C++ `ipc::buf_t` memory layout exactly

### 2.2 `Waiter`

- Semaphore-backed waiter used by the channel to block receivers
- `waitFor(name:count:timeout:)` static helper

### 2.3 `Circ` — circular ring

- `BroadcastConnHead` and `UnicastConnHead` matching the C++ prod/cons layout
- Lock-free read/write with connection bitmask

### 2.4 `Channel` / `Route`

- `Route` — 1 writer, N readers (broadcast)
- `Channel` — N writers, N readers
- `connect(name:mode:)`, `disconnect()`, `reconnect(mode:)`
- `send(_:timeout:)`, `recv(timeout:)`, `trySend(_:)`, `tryRecv()`
- `clearStorage(name:)`

### 2.5 `ChunkStorage`

- Large-message overflow storage in a secondary shm segment

### Phase 2 tests

Mirror `test_buffer.rs`, `test_waiter.rs`, `test_circ.rs`,
`test_channel.rs`, `test_chan_wrapper.rs`, `test_channel_stress.rs`.

**Interop test** (new): Swift sender → C++ receiver and Rust receiver using the
same named channel. Mirrors `tests/interop.rs`.

---

## Phase 3 — Typed protocol layer

*Mirrors: `proto/shm_ring.rs`, `proto/service_registry.rs`,
`proto/process_manager.rs`, `proto/message.rs`, `proto/typed_channel.rs`,
`proto/typed_route.rs`*

*C++ headers: `proto/` — `shm_ring.h`, `service_registry.h`,
`process_manager.h`, `message.h`*

### 3.1 `ShmRing<T, N>`

- Lock-free single-producer single-consumer ring over shared memory
- `write(_:)`, `writeOverwrite(_:)`, `read(_:)`, `isEmpty`, `isFull`
- Same slot layout as C++ and Rust (binary compatible)

### 3.2 `ServiceRegistry`

- Named service directory in shared memory
- `register(name:control:reply:)`, `find(name:)`, `findAll(prefix:)`,
  `unregister(name:)`, `gc()`, `clear()`
- `[UInt8; 64]` fixed-width name fields — same layout as Rust `ServiceEntry`

### 3.3 `ProcessHandle` / `ProcessManager`

- `spawn(executable:arguments:)`, `shutdown(_:)`, `waitForExit(_:timeout:)`

### 3.4 `Message<T>` + `TypedChannel<T>` / `TypedRoute<T>`

- FlatBuffers-based typed wrapper over `Channel`
- Swift FlatBuffers via the official
  [google/flatbuffers Swift runtime](https://github.com/google/flatbuffers)
- `TypedChannel<T>.send(_:timeout:)`, `recv(timeout:) -> Message<T>`

### Phase 3 tests

Mirror `test_proto.rs`, `test_proto_typed.rs`.

---

## Phase 4 — Real-time & orchestration

*Mirrors: `proto/rt_prio.rs`, `proto/service_group.rs`*

### 4.1 `RtPriority`

- `setRealtimePriority(periodNs:computationNs:constraintNs:)` via
  `thread_policy_set` (macOS) / `pthread_setschedparam` (Linux)
- `audioPeriodNs(sampleRate:framesPerBuffer:)` helper

### 4.2 `ServiceGroup`

- Failover / respawn orchestrator wrapping `ProcessManager`
- `ServiceGroupConfig(name:executable:)` with `replicas`, `autoRespawn`,
  `spawnTimeout`
- `start()`, `stop(grace:)`, `healthCheck()`, `forceFailover()`
- `InstanceRole`: `.primary`, `.standby`, `.dead`

---

## Phase 5 — Demos

*Mirrors: `src/bin/demo_*.rs`*

All demos are Swift executables in `swift/libipc/Sources/` using Swift
Package Manager executable targets.

| Demo target | Mirrors |
| --- | --- |
| `demo-send-recv` | `demo_send_recv.rs` / `demo/send_recv/` |
| `demo-chat` | `demo_chat.rs` / `demo/chat/` |
| `demo-msg-que` | `demo_msg_que.rs` / `demo/msg_que/` |
| `demo-audio-service` | `demo_audio_service.rs` / `demo/audio_service/` |
| `demo-audio-host` | `demo_audio_host.rs` / `demo/audio_service/` |
| `demo-rt-audio-service` | `demo_rt_audio_service.rs` / `demo/audio_realtime/` |
| `demo-rt-audio-host` | `demo_rt_audio_host.rs` / `demo/audio_realtime/` |

---

## Phase 6 — Linux support

- Replace `sem_open` with `sem_init` + shm-backed semaphore where needed
- `rt_prio`: `pthread_setschedparam` path
- CI: add `ubuntu-latest` job to `.github/workflows/swift.yml`
- Validate binary compatibility with C++ and Rust on Linux

---

## CI integration

A new workflow `.github/workflows/swift.yml` is added in Phase 1 and extended
each phase:

```yaml
- swift build          # phases 1–5
- swift test           # phases 1–4
- interop test         # phase 2+: run Swift + Rust processes against each other
```

---

## Module map (C++ → Rust → Swift)

| C++ header | Rust module | Swift type |
| --- | --- | --- |
| `shm.h` | `shm.rs` + `platform/posix.rs` | `Shm` |
| `mutex.h` | `mutex.rs` | `IpcMutex` |
| `semaphore.h` | `semaphore.rs` | `IpcSemaphore` |
| `condition.h` | `condition.rs` | `IpcCondition` |
| `rw_lock.h` | `rw_lock.rs` | `RwLock` |
| *(internal)* | `spin_lock.rs` | `SpinLock` |
| *(internal)* | `scoped_access.rs` | `ScopedAccess` |
| *(internal)* | `shm_name.rs` | `ShmName` |
| `buffer.h` | `buffer.rs` | `IpcBuffer` |
| *(internal)* | `waiter.rs` | `Waiter` |
| *(internal)* | `circ.rs` | `Circ` |
| `ipc.h` (`route`) | `channel.rs` (`Route`) | `Route` |
| `ipc.h` (`channel`) | `channel.rs` (`Channel`) | `Channel` |
| *(internal)* | `chunk_storage.rs` | `ChunkStorage` |
| `proto/shm_ring.h` | `proto/shm_ring.rs` | `ShmRing<T, N>` |
| `proto/service_registry.h` | `proto/service_registry.rs` | `ServiceRegistry` |
| `proto/process_manager.h` | `proto/process_manager.rs` | `ProcessManager` |
| `proto/message.h` | `proto/message.rs` | `Message<T>` |
| *(internal)* | `proto/typed_channel.rs` | `TypedChannel<T>` |
| *(internal)* | `proto/typed_route.rs` | `TypedRoute<T>` |
| *(internal)* | `proto/rt_prio.rs` | `RtPriority` |
| *(internal)* | `proto/service_group.rs` | `ServiceGroup` |
