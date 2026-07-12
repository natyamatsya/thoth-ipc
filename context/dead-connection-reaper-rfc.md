# RFC: Dead-connection reaping for broadcast routes

Status: **Phase 1 implemented (C++)** · Author: agent-control integration ·
Revised after cross-language review (owner table is now an xlang ABI; notify
cleanup added) and again to record the lock-free implementation ·
Relates to [`macos_ipc_roadmap.md`](macos_ipc_roadmap.md) (reuses its PID-liveness
primitive) and [`xlang-channel-abi.md`](xlang-channel-abi.md) (the byte-exact
cross-language contract this extends).

## Problem

A broadcast route (`ipc::route = chan<single, multi, broadcast>`) tracks connected
receivers as a **32-bit atomic bitmask**, `conn_head_base::cc_`
(`circ/elem_def.h`, `cc_t = uint_t<32>`). A receiver claims the lowest free bit on
connect:

```cpp
// circ/elem_def.h  conn_head<P,true>::connect()
cc_t next = curr | (curr + 1);   // set lowest zero bit
if (next == curr) return 0;      // all 32 slots taken -> connect fails
```

and releases it on clean disconnect (`disconnect(cc_id) => cc_.fetch_and(~cc_id)`).

When a peer is **SIGKILLed** (or crashes) it never runs its destructor, so its bit
is never cleared. The bit becomes a *phantom*. Observed empirically: a single live
Sourcetrail plus repeated killed clients drove `st.agent.cmd` to
`conn_count() == 13`.

Phantom bits are not cosmetic. They are load-bearing:

1. **Broadcast waits on them.** Each pushed element records the current reader set;
   a slot is reclaimed only once every connected reader has consumed it. A phantom
   never consumes, so the ring stops reclaiming and eventually `force_push` fires —
   whose current "recovery" is the sledgehammer
   `disconnect_receiver(~cc_t{0})`, i.e. **drop *all* readers, including live ones**
   (`prod_cons.h`).
2. **The slot space is finite (32).** 32 phantoms ⇒ `connect()` returns 0 and the
   channel is permanently unjoinable until `clear_storage()`.
3. **`recv_count` / `wait_for_recv` / the send delivered-bool count phantoms**, so
   sends spuriously report "not delivered" or block for the timeout.

Today the only cure is `chan_wrapper::clear_storage(name)` — wipe the whole
segment. The agent-control app calls it on startup (owner resets its own channels),
but that is a blunt instrument: it also evicts any *live* peer and cannot run on a
shared, long-lived channel.

## Why not a ping / heartbeat protocol

The instinctive fix is a heartbeat: each connection periodically bumps a shared
timestamp; a reaper evicts slots whose timestamp is stale. It works, but for *this*
failure mode it is the wrong tool:

- **It can false-reap a live peer.** A process that is alive but momentarily not
  heartbeating (GC pause, debugger breakpoint, scheduler starvation) looks dead.
  Picking the stale threshold is an unwinnable tradeoff: short ⇒ false reaps, long
  ⇒ phantoms linger.
- **It needs cooperation from every peer** — a heartbeat thread/timer in each
  process, including ones that are otherwise purely passive receivers.
- **thoth-ipc already has a better primitive.** `platform/apple/mutex.h` recovers a
  dead lock *holder* by storing its PID and asking the OS:

  ```cpp
  // apple/mutex.h:104
  static bool is_process_alive(pid_t pid) noexcept {
      if (pid <= 0) return false;
      return (::kill(pid, 0) == 0) || (errno != ESRCH);
  }
  ```

  `kill(pid, 0)` is definitive for process existence, needs zero cooperation, and —
  critically — **never reports a live process as dead**. So a PID-liveness reaper
  cannot evict a live-but-idle peer, which is exactly the guarantee a heartbeat
  cannot give.

**Recommendation:** reap by PID liveness, reusing the mutex layer's pattern. Keep a
heartbeat only as an optional Phase 4 for the genuinely distinct case of a
*hung-but-alive* peer (deadlocked process still holding a slot). That is rarer and
should be opt-in.

## Design: per-slot owner table + PID-liveness reaper

### 1. Record the owner per slot — a dedicated `LV_CONN__` segment

The owner table lives in its **own shared segment**, not appended to any existing
one. `cc_` (in the ring header) and the `CA_CONN__`/`RD_/WT_/CC_CONN__` segments
are byte-exact across C++/Rust/Swift ([`xlang-channel-abi.md`](xlang-channel-abi.md));
overlaying a table on them would break that contract. A new segment is purely
additive and independently versioned:

- **Name** `make_prefix(prefix, "LV_CONN__", name)` = `"{prefix}__IPC_SHM__LV_CONN__{name}"`
  (same convention as `QU_CONN__` etc.), reached via `conn_info_head` alongside the
  existing waiters.
- **Layout** — one `slot_owner` per `cc_` bit, indexed by bit position
  (`circ::index_of` = `ctz`). This is a **cross-language ABI** (§8), so the offsets
  are fixed:

  ```cpp
  struct slot_owner {                     // 16 bytes, align 8
      std::atomic<int32_t>  pid{0};       // @0  0 = free
      // @4..8 padding
      std::atomic<uint64_t> start_tok{0}; // @8  process start-time; defeats PID reuse (§5)
  };
  struct conn_liveness { slot_owner slots[32]; };  // 512 bytes, one per cc_ bit
  ```

- `connect_receiver()` — after `connect()` returns the single-bit mask, write
  `slots[index_of(bit)] = { getpid(), self_start_token() }` **before** the bit is
  observable to the reaper (owner store, then the bit set — or both under `lc_`,
  §3). A set bit whose `pid` is still 0 is *skipped* by the reaper (safe), so the
  ordering only affects promptness, not correctness.
- `disconnect_receiver(cc_id)` — clear `slots[index_of(cc_id)] = {0,0}` in addition
  to clearing the bit, and reclaim the slot's notify FIFO (§6).

### 2. The reaper

A single routine, callable by any participant:

```cpp
cc_t reap_dead_receivers() {
    cc_t reaped = 0;
    guard g{lc_};                          // conn_head_base::lc_ spin_lock
    cc_t live = cc_.load(acquire);
    for (cc_t m = live; m; m &= m - 1) {   // iterate set bits
        cc_t bit = m & (~m + 1);
        auto& o  = slots[index_of(bit)];
        pid_t p  = o.pid.load(acquire);
        if (p != 0 && !is_process_alive(p, o.start_tok.load(acquire))) {
            disconnect_receiver(bit);      // existing API: clears the cc_ bit
            unblock_inflight(bit);         // §4 — release ring elements waiting on it
            notify_clear_slot(bit);        // §6 — reclaim the dead reader's FIFO
            o.pid.store(0, release);
            reaped |= bit;
        }
        // p == 0: owner unknown (e.g. a port that doesn't populate the table, or a
        // connect mid-flight) — never reaped. Safe degradation, no false eviction.
    }
    return reaped;
}
```

`is_process_alive` is the mutex-layer function, extended with the start-token
compare from §5.

### 3. Concurrency — lock-free (implemented)

The implementation is **lock-free** — no new shared lock, and `conn_head`'s
byte-exact `lc_` is left untouched. Two rules give the same TOCTOU guarantee a
lock would:

- **Connect writes its owner *after* claiming the bit** (`que->connect()`'s CAS,
  then `slots[i].pid.store(getpid())`). A set bit whose owner is still `0`
  (mid-connect, or a non-participating port) is *skipped* by the reaper — safe,
  never a false reap.
- **The reaper CAS-claims the owner** (`pid.compare_exchange(dead, 0)`) before
  clearing the bit. A slot cannot be reused by a newcomer until the reaper frees
  the bit, so between "read dead PID" and "CAS" no live PID can appear; and if two
  reapers race, only one CAS wins. The newcomer is never evicted.

This is simpler than an `lc_`-guarded scan and — importantly — keeps the connect
path a plain CAS, so **the ports need only the same "owner store after bit set,
CAS-clear before reap" discipline**, not a shared spin-lock protocol.

### 4. Unblocking in-flight elements (the careful part)

Clearing the bit stops *future* pushes from waiting on the phantom, but elements
already in the ring recorded the old reader set. `unblock_inflight(bit)` must clear
`bit` from each outstanding element's pending-reader accounting so reclamation can
proceed — a bounded scan of `elem_max` (256) slots, mirroring what
`force_push`/`pop` already do to a reader's bit, but targeted to one slot instead of
`~0`. Two details:

- Use the **same atomic CAS** as `pop` (`rc_.fetch_and(~bit)` semantics), never a
  plain store — producers may be racing on `rc_`.
- `rc_` packs the epoch in its high 32 bits (`EP_MASK`); clear only the low-32
  connection bit, preserve the epoch generation.

This is the one piece that touches the hot path's element layout
(`circ/elem_array.h`) and deserves the most test scrutiny (a killed-mid-stream
receiver, then a live receiver that must still drain the backlog).

### 5. PID-reuse hardening

`kill(pid, 0)` alone is fooled if the OS recycles a dead receiver's PID for an
unrelated live process — the slot then looks alive forever. Store a process
*start token* to disambiguate:

- macOS: `proc_pidinfo(pid, PROC_PIDTBSDINFO, …)->pbi_start_tvsec/uvsec`.
- Linux: `/proc/<pid>/stat` field 22 (starttime, in jiffies since boot).

`is_process_alive(pid, tok)` ⇒ `kill(pid,0)==0 && start_token(pid)==tok`. The
current mutex `is_process_alive(pid)` is the token-less base; both can coexist.

**Cross-language caveat:** the reaper compares *its own* freshly computed
`start_token(pid)` against the *stored* token. If a C++ reaper may run against a
slot written by a Rust/Swift peer (and it can — any participant reaps), all ports
must compute the token **identically**: same source field, same units, same 64-bit
packing (macOS: `tvsec * 1'000'000 + tvusec`; Linux: the raw jiffies value). This
formula is part of the §8 ABI, and must have a golden test.

### 6. Notify-layer cleanup

Reaping a slot must also reclaim its **Layer-1 notify** state
([`xlang-channel-abi.md`](xlang-channel-abi.md) §8), or the readiness plumbing
leaks in parallel with `cc_`:

- **FIFO backend** — the dead receiver's `<dir>/ipcntf_<hash>.<slot>` node lingers
  (it is only `unlink`ed on clean disconnect). `notify_clear_slot(bit)` unlinks it.
- **libnotify backend** — self-heals: process death drops the fd registration; no
  action needed.
- **The source's per-slot write fd** to a dead reader already self-heals on
  `EPIPE`/`ENXIO` (see `notify_source::signal`), so only the FIFO node needs
  explicit reclamation.

### 7. When to run it

Cheap and idempotent, so trigger opportunistically rather than on a timer:

- **On `connect_receiver()`** — a new joiner pays to clean up before claiming, which
  also reclaims slots so the 32-cap is rarely hit.
- **In `force_push`'s full-ring path** — replace the current
  `disconnect_receiver(~0)` nuke with `reap_dead_receivers()`; only fall back to the
  nuke if reaping frees nothing (genuine live-but-wedged reader). Cost: up to 32
  `kill()` syscalls under `lc_`, acceptable because `force_push` is already the
  timeout path.
- **On `recv_count()` / `wait_for_recv()`** — a cheap reap here keeps the count (and
  the bridge's `send` delivered-bool) from reporting phantoms between joins. Optional
  but directly serves the motivating consumer.
- **Optional low-frequency timer** for long-idle channels.

## 8. Cross-language ABI

Because *any* participant can run the reaper, the owner table and its liveness
formula are a **cross-language contract**, exactly like the ring layout and the
notify key. The properties:

- **Safe by default, opt-in for the benefit.** A port that maps the ring but does
  **not** populate `LV_CONN__` leaves `slots[i].pid == 0` for its receivers → the
  reaper *skips* them (never false-reaps a live foreign peer), but they also never
  get cleaned up. So an un-upgraded port is never *broken* by a reaping peer; it just
  doesn't gain the fix until it populates the table.
- **What each port must implement to participate:** map/create `LV_CONN__<name>`
  (512 B, `slot_owner[32]`, offsets per §1); write `{getpid(), start_token()}` under
  `lc_` at connect and clear at disconnect; compute `start_token` by the identical
  formula (§5). C++ owns the reaper; Rust/Swift need only the *owner-table*
  population to be reapable (they may also expose a `reap()` entry point).
- **Verification.** Add to `xlang-channel-abi.md` a "§9 liveness owner table"
  section (name, 16-byte `slot_owner` layout, start-token formula, golden token for
  a fixed synthetic input) and extend `tools/xlang_matrix.py` with a reaping
  scenario: a writer + a receiver that is `SIGKILL`ed, then a C++ reaper run, then a
  fresh receiver must join and drain — across writer/reaper/victim language
  combinations. Same-language tests will not catch owner-table drift.

## Client integration (Sourcetrail agent-control)

Once this lands, the app-side startup `clear_storage()` sledgehammer
(`AgentControlController` ctor) can drop back to a no-op or a one-shot
`reap_dead_receivers()` — it would no longer need to wipe live peers, so a bridge
could stay connected across an app restart. The bridge's `send` delivered-bool
(already surfaced as a distinct error) then reflects a *true* reader set, and — with
the notify layer — the bridge's async receives are no longer woken by (or waiting
on) dead slots.

## Phasing

1. **C++ owner table + `reap_dead_receivers()` + reap-on-connect.** Fixes phantom
   accumulation and the 32-slot exhaustion; PID-liveness only. No hot-path element
   change yet — reaping just fixes the count and future pushes.
2. **`unblock_inflight` + `force_push` uses reaper (+ notify FIFO cleanup).** Fixes
   ring-reclamation stalls; the element-layout-sensitive part.
3. **Start-token hardening (§5).** PID-reuse safety.
4. **Cross-language: Rust + Swift populate the owner table (§8) + xlang §9 + the
   reaping matrix scenario.** Makes the fix apply to the bridge and any port peer,
   with drift protection.
5. **Optional heartbeat** for hung-but-alive detection, opt-in.

Phase 1 alone removes the observed breakage on C++-only channels; 2 makes it robust
under load; 4 extends the guarantee to the Rust bridge and closes the ABI. Phases 1
and 4 together are what let the bridge stay connected across an app restart.
