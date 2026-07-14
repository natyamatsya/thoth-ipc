# RFC: Ref-count-aware `clear_storage` for named sync objects

Status: **Proposed** · Author: Sourcetrail fan-out integration ·
Motivated by a memory-corruption incident root-caused in Sourcetrail-TS
(`IpcSharedMemory`, 2026-07-14); relates to
[`dead-connection-reaper-rfc.md`](dead-connection-reaper-rfc.md) (same
"global cleanup vs. live users" tension) and the central-allocator
immortalization fix (`852937e`), which is what makes the current failure
mode *recycled-heap* garbage rather than a clean crash.

## Problem

`ipc::sync::mutex::clear_storage(name)` (and its condition/semaphore
siblings) force-erases the **per-process handle cache entry** for `name`
regardless of how many live handles in the calling process still point into
it:

```cpp
// platform/{apple,posix,linux}/mutex.h — identical shape on all three
static void clear_storage(char const *name) noexcept {
    if (name == nullptr) return;
    release_mutex(name, [] { return true; });   // <-- unconditional erase
    ipc::shm::handle::clear_storage(name);      // unlink global backing
}
```

Every open handle holds raw pointers (`shm_`, `ref_`, `data_`) into that
cache entry (`curr_prog::mutex_handles`, an `ipc::map<std::string, shm_data>`
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
2. If `ref > 0`: log a warning (`LIBIPC_LOG`), **move the node out of the
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
    ipc::map<std::string, shm_data*> mutex_handles;  // owning via node pool
    std::vector<shm_data*>           orphans;        // cleared-while-in-use
    spin_lock lock;
};

static void clear_storage(char const *name) noexcept {
    if (name == nullptr) return;
    orphan_or_erase(name);                  // NEW: ref-count-aware
    ipc::shm::handle::clear_storage(name);  // unchanged: unlink global name
}

void close() noexcept {
    // decrement own node; erase from map-or-orphans by node address when 0
    ...
}
```

The same treatment applies to `condition` and `semaphore`, which share the
`curr_prog` cache pattern, and to the aggregate `waiter::clear_storage`
(which fans out to cond/mutex/sem).

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

The Rust implementation (`rust/libipc/src/mutex.rs`, `condition.rs`,
`semaphore.rs`, `waiter.rs`) exposes the same `clear_storage` entry points
and needs the equivalent audit: whatever per-process caching it does must
either already be orphan-safe or adopt the same orphan-list treatment.
Swift consumes libipc through the C++ core, so it inherits the fix. Add the
double-owner scenario to the existing cross-language parity test matrix
(`os-parity.md`).

## Rollout

1. Land the C++ core change (apple → posix → linux → win, in that order;
   apple is where the corruption was observed).
2. Audit/align the Rust side; extend parity tests.
3. Bump the thoth-ipc pin in Sourcetrail-TS. Its `IpcSharedMemory`
   double-owner warning stays (it documents a *design* smell even once the
   behavior is safe), but the S3-era test comment about dangling views can
   then be relaxed.
