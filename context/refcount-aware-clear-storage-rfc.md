# RFC: Ref-count-aware `clear_storage` for named sync objects

Status: **Implemented (C++ core, mutex-only)** · Author: Sourcetrail fan-out
integration · Motivated by a memory-corruption incident root-caused in
Sourcetrail-TS (`IpcSharedMemory`, 2026-07-14); relates to
[`dead-connection-reaper-rfc.md`](dead-connection-reaper-rfc.md) (same
"global cleanup vs. live users" tension) and the central-allocator
immortalization fix (`852937e`), which is what makes the current failure
mode *recycled-heap* garbage rather than a clean crash.

> **Implementation note (2026-07-14).** Tracing the code during
> implementation showed the hazard is **mutex-only**, not shared across all
> named sync objects as this RFC's first draft assumed. `condition` and
> `semaphore` hold an `thoth::shm::handle` **by value** and their
> `clear_storage` is already a pure `shm_unlink` (POSIX-unlink semantics; no
> in-process node to dangle), and the Windows mutex `clear_storage` is a
> no-op. Only the **mutex** carries the vulnerable per-process
> `curr_prog::mutex_handles` node cache. The fix therefore landed on
> `platform/{apple,posix,linux}/mutex.h` only; the cond/sem/win sections
> below are retained for the record but require no code change. See
> **Implementation status** at the end.

## Problem

`thoth::sync::mutex::clear_storage(name)` (and its condition/semaphore
siblings) force-erases the **per-process handle cache entry** for `name`
regardless of how many live handles in the calling process still point into
it:

```cpp
// platform/{apple,posix,linux}/mutex.h — identical shape on all three
static void clear_storage(char const *name) noexcept {
    if (name == nullptr) return;
    release_mutex(name, [] { return true; });   // <-- unconditional erase
    thoth::shm::handle::clear_storage(name);      // unlink global backing
}
```

Every open handle holds raw pointers (`shm_`, `ref_`, `data_`) into that
cache entry (`curr_prog::mutex_handles`, an `thoth::map<std::string, shm_data>`
backed by the central allocator). Erasing the entry destroys the `shm_data`
— unmapping the segment and returning the node to the allocator's recycling
pool — while the live handles keep dereferencing it.

The result is silent corruption, not a crash. Observed in the wild
(Sourcetrail-TS, two `CREATE_AND_DELETE` owners of one segment in one
process, root-caused with lldb):

- the surviving handle's `data_->state` read `0x4C494241` (ASCII "ABIL" —
  recycled allocator memory, not a lock word);
- `data_->holder` read `1`, so the dead-holder recovery pinged **launchd**,
  found it alive, and refused to reset;
- every subsequent `lock()` burned the full retry budget and timed out
  (10 × 500 ms), surfacing hundreds of lines away from the actual bug.

Note the asymmetry: for **other processes** `clear_storage` already has
clean unlink semantics — their mappings survive the unlink, their caches are
per-process, and they simply keep using a stale-but-valid segment until they
close. Only the **calling process's** live handles are corrupted. The fix is
to make in-process behavior match the cross-process behavior that already
works.

## Current behavior (summary)

| Observer                          | Today                                          |
|-----------------------------------|------------------------------------------------|
| Other process, open handle        | Keeps stale-but-valid mapping (unlink semantics) ✅ |
| Other process, new `open(name)`   | Creates/joins fresh segment ✅                  |
| Same process, open handle         | **Dangles into recycled heap — UB** ❌          |
| Same process, new `open(name)`    | Creates fresh cache entry + segment ✅          |

## Proposal

Make `clear_storage` consult the in-process ref count and **orphan** (rather
than destroy) cache entries that still have live users:

1. If the cache entry for `name` has `ref == 0` (or does not exist):
   behavior unchanged — erase and unlink.
2. If `ref > 0`: log a warning (`THOTH_IPC_LOG`), **move the node out of the
   by-name map into an orphan list**, and still unlink the global backing.
   The live handles keep their intact mapping and ref counter; a subsequent
   `open(name)` in the same process misses the by-name map and creates a
   fresh entry — exactly what a new opener in another process gets.
3. `close()` on an orphaned handle decrements its node's counter and frees
   the node when it reaches zero.

Point 3 requires re-keying `close()`: today it looks its node up **by name**
(`release_mutex(shm_->name(), ...)`), which after orphaning would find — and
corrupt the ref count of — a *newer* entry under the same name. `close()`
must instead operate on the node identity it already holds (each handle
keeps `shm_`/`ref_` pointers into its node): decrement directly, then erase
the node from whichever container currently owns it by address comparison.
Both containers are tiny (a handful of names per process), so a linear scan
of the orphan list is fine.

Sketch (apple; posix/linux are structurally identical):

```cpp
struct curr_prog {
    thoth::map<std::string, shm_data*> mutex_handles;  // owning via node pool
    std::vector<shm_data*>           orphans;        // cleared-while-in-use
    spin_lock lock;
};

static void clear_storage(char const *name) noexcept {
    if (name == nullptr) return;
    orphan_or_erase(name);                  // NEW: ref-count-aware
    thoth::shm::handle::clear_storage(name);  // unchanged: unlink global name
}

void close() noexcept {
    // decrement own node; erase from map-or-orphans by node address when 0
    ...
}
```

~~The same treatment applies to `condition` and `semaphore`, which share the
`curr_prog` cache pattern~~ — **struck: they do not.** `condition` and
`semaphore` hold `thoth::shm::handle` by value and are already unlink-safe (see
the implementation note above); no change was needed. The aggregate
`waiter::clear_storage` fans out to `condition::clear_storage` +
`mutex::clear_storage`, so it inherits the mutex fix automatically.

### Resulting semantics

| Observer                          | After this RFC                                  |
|-----------------------------------|--------------------------------------------------|
| Other process, open handle        | Stale-but-valid mapping (unchanged) ✅            |
| Other process, new `open(name)`   | Fresh segment (unchanged) ✅                      |
| Same process, open handle         | **Stale-but-valid mapping + warning log** ✅      |
| Same process, new `open(name)`    | Fresh segment (unchanged) ✅                      |

`clear_storage` becomes uniformly "POSIX unlink" semantics: existing users
anywhere keep a private stale object; new opens get a fresh one; nobody
dereferences freed memory.

### What does NOT change

- The global unlink always happens — `clear_storage` still guarantees the
  *name* is reset for future openers.
- No API/ABI change; `clear_storage` stays `static void(char const*)
  noexcept`. The cross-process shared-memory layout is untouched (this is
  purely per-process bookkeeping).
- The last-user reset-and-wake logic in `close()` is preserved for the
  normal (non-orphaned) path.

## Alternatives considered

- **Warn-only, keep the erase.** No memory-safety gain; the consumer
  (Sourcetrail's `IpcSharedMemory`) already logs a warning at its own layer.
  Rejected: the library would still corrupt its own callers.
- **Refuse to clear while in use.** Breaks the legitimate "owner resets a
  possibly-stale channel on startup" pattern that agent-control and
  Sourcetrail rely on; the global unlink must proceed. Rejected.
- **Epoch/generation counters in the segment.** Detects staleness at use
  sites but adds a cross-process ABI change for a problem that is purely
  per-process bookkeeping. Rejected as overkill.

## Testing

- Unit (per platform): open `A(name)`; `clear_storage(name)`; assert `A` can
  still `lock`/`unlock` (memory-safe, on its orphaned segment); `open
  B(name)` → fresh object independent of `A` (locking `B` does not block
  `A`); close `A` → orphan drained (no leak under ASan); close `B` → name
  fully released.
- ASan/TSan run of the double-owner sequence that produced the original
  corruption: `open A` → `clear_storage` → `open B` → use both → destroy in
  both orders.
- Consumer-level regression: Sourcetrail-TS
  `IpcSharedMemoryTestSuite` "live-handle registry" test already constructs
  the double-owner pattern and currently only *warns*; once thoth-ipc lands
  this, that pattern becomes fully defined behavior.

## Cross-language parity

**Rust audit (2026-07-14) — done.** The Rust side is structurally more robust
than the pre-fix C++: its process-local cache is a
`HashMap<String, Arc<CachedShm>>` and each handle owns an `Arc<CachedShm>`, so
`Arc` refcounting *is* the orphan-list — a live handle keeps its mapping alive
regardless of the cache, and `Drop for CachedShm` (munmap) runs only when the
last `Arc` goes away. The C++ use-after-free class of bug therefore cannot
occur in Rust. Findings:

- **`platform/posix.rs` mutex — already correct.** `clear_storage` calls
  `cached_shm_purge` (unconditional `map.remove`), the exact orphan-by-removal
  the C++ fix adopts. Live handles keep their `Arc`; a fresh `open` misses the
  cache and creates a new segment.
- **`platform/apple.rs` mutex — was divergent; fixed.** `clear_storage` called
  `release_mutex_shm` (decrement `ref_count` + remove *only* when it hit 0).
  With two live handles that left the stale, already-unlinked entry cached, so
  a same-process re-open rejoined the dead segment while other processes got a
  fresh one (cross-process split-brain), and it corrupted `ref_count`. Replaced
  with a `purge_mutex_shm` (unconditional removal) mirroring posix.rs. No
  memory-safety impact (Arc), but a real semantic divergence now closed.
- **`condition.rs` (posix + apple) — already correct** (both use
  `cached_shm_purge`). **`semaphore.rs` — n/a** (POSIX named semaphores;
  `sem_unlink`, no cache). **`windows.rs` mutex `clear_storage` — no-op**
  (named kernel object), matching C++.
- **Known wart (not a bug, left as-is):** `Drop`/release is keyed by *name*,
  not `Arc` identity. After an orphan+reopen, a dropping old handle can remove
  a *newer* same-name cache entry — but the SHM *name* is authoritative, so the
  reopened handle still shares the same physical segment (verified by
  `clear_storage_orphans_shared_node`). The only cost is a redundant re-mmap and
  `ref_count` desync, never split-brain or UAF. Tightening to `Arc::ptr_eq`
  identity release (the Rust analogue of C++ RFC point 3) is possible but has no
  functional payoff; deferred. Present equally in posix.rs.

Tests added (`rust/thoth-ipc/tests/test_mutex.rs`):
`clear_storage_orphans_live_handle`, `clear_storage_orphans_shared_node` —
parity with the C++ gtests; full Rust suite green.

**Swift audit (2026-07-14) — already correct, no change.** ~~Swift consumes
libipc through the C++ core, so it inherits the fix.~~ **Struck: it does
not.** Swift is a native reimplementation over a thin C shm shim
(`Sources/LibIPCShim`), not a C++-core wrapper — so it needed its own audit.
It turns out to already match the fixed behavior: `CachedShm` is a
reference-counted `final class` (ARC is the orphan-list), `ShmHandle` is
`~Copyable` and munmaps only in `deinit` (so a live handle keeps its mapping),
and `IpcMutex.clearStorage` / `IpcCondition.clearStorage` already call
`ShmCache.purge` (unconditional `map.removeValue`) — the same
orphan-by-removal as posix.rs and the C++ fix. `IpcSemaphore` uses
`sem_unlink` (no cache). It carries the same benign by-name `release`-on-deinit
wart as Rust. A parity test was added (`Tests/LibIPCTests/TestMutex.swift`:
`clearStorageOrphansLiveHandle`); the Swift mutex suite passes (15 tests).

Remaining: add the double-owner scenario to the cross-language parity test
matrix (`os-parity.md`).

## Implementation status

- **C++ mutex — done** (`platform/{apple,posix,linux}/mutex.h`). Each node
  is now heap-allocated and stored as `thoth::map<std::string, shm_data*>`
  plus a `std::vector<shm_data*> orphans`. `clear_storage` orphans (logs a
  warning + moves the node) when its in-process `ref > 0`, else erases; it
  always unlinks the global name. `close()`/`clear()` were re-keyed from
  by-name lookup to **node identity** (a new `node_` member) and free via
  `destroy_node()`, which removes the node from whichever container owns it
  by address. A `~curr_prog` restores the exit-time munmap/unlink cleanup the
  old by-value map provided (safe now that the central allocator is
  immortalized — `852937e`).
- **C++ condition / semaphore / Windows mutex — no change** (already
  unlink-safe; see the implementation note at the top).
- **Tests — done** (`test/test_mutex.cpp`): `ClearStorageOrphansLiveHandle`
  (orphan a locked handle; fresh `open` yields an independent segment) and
  `ClearStorageOrphansSharedNode` (two in-process handles share one node;
  both stay valid; the orphan drains only when its last local handle closes).
  Verified under AddressSanitizer + UBSan; full C++ suite 285/285.
- **Verification caveat**: apple is runtime- and ASan-proven on macOS; posix
  and linux are type-checked locally but not yet runtime-tested on their
  native platforms (a `workflow_dispatch` CI run is the intended gate).
- **Rust parity — pending audit** (see below).

## Rollout

1. ~~Land the C++ core change (apple → posix → linux → win)~~ **Done** for
   the mutex on apple/posix/linux; Windows needs nothing (no-op
   `clear_storage`).
2. ~~Audit/align the Rust side; extend parity tests.~~ **Done** (apple.rs
   `clear_storage` aligned to posix.rs; parity tests added; see Cross-language
   parity above).
3. Bump the thoth-ipc pin in Sourcetrail-TS. Its `IpcSharedMemory`
   double-owner warning stays (it documents a *design* smell even once the
   behavior is safe), but the S3-era test comment about dangling views can
   then be relaxed.
