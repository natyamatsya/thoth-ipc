<!-- SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors -->

# RFC: Cross-language `thoth::channel` (multi-writer broadcast)

**Status:** ✅ Complete. **All four ports (C++, Rust, Swift, Zig) implement the
multi-writer channel byte-exact.** The full `channel` scenario — every
two-language sender pair into every reader, at 40/65/3000 B — passes (72/72), and
the scenario's expected-fail flag has been cleared
(`tools/xlang-runner/src/config.rs`). Implementations:
`zig/thoth-ipc/src/transport/channel_multi.zig`, `rust/thoth-ipc/src/channel.rs`,
`swift/thoth-ipc/Sources/LibIPC/Transport/Channel.swift`. This document is the
target ABI and the per-language roadmap that closed the last remaining
cross-language gap in the matrix: multi-writer `thoth::channel`. It complements
[`xlang-channel-abi.md`](xlang-channel-abi.md), which specifies the
single-writer `thoth::route` (already byte-exact across all four ports).

**Canonical implementation:** C++ (`cpp/thoth-ipc`),
`prod_cons_impl<multi, multi, broadcast>` in
[`src/libipc/prod_cons.h`](../cpp/thoth-ipc/src/thoth-ipc/prod_cons.h) L301-441. Rust,
Swift and Zig must match it byte- and memory-order-exact.

---

## 1. Why it's a gap today

`thoth::route` = `chan<single, multi, broadcast>`; `thoth::channel` =
`chan<multi, multi, broadcast>` (`cpp/thoth-ipc/include/thoth-ipc/ipc.h` L258 / L267).
They are **different producer-consumer rings**, but every port currently reuses
the single-writer route ring for both. Two independent problems, both must land:

- **Part A — ring layout (the hard part).** C++ channel uses 96-byte slots with
  a per-slot `f_ct_` commit flag and a commit-index (`ct_`) two-phase handshake;
  the ports reuse route's 88-byte slots and plain `wt_` write cursor. Same shm
  **name**, different slot stride and header semantics → garbage on the wire, at
  every payload size.
- **Part B — message-id counter (small).** C++ draws `msg_t.id_` from the shared
  per-channel `AC_CONN__<name>` shm atomic; the ports draw it from a
  process-local counter, so two concurrent writers both emit `id_ = 0,1,2,…` and
  collide in the receiver's reassembly cache. Only bites multi-fragment
  payloads (>64 B, i.e. the 3000 B matrix size); the ring bug bites all sizes.

Zig currently has **no** channel path at all (route ring only; harness has just
`write`/`read`). C++ is the reference and needs no change.

---

## 2. The multi-writer ABI (normative target)

All offsets/sizes are for a 64-bit target; `AlignSize = min(64,
alignof(max_align_t))` (8 on Apple arm64) is computed, not hard-coded, exactly
as for route. The message framing (`msg_t<64,8>`, §4 of the route ABI),
chunk-storage (§6c), notify (§8) and reaper (§9) layers are **unchanged** — only
the ring element and the producer-consumer protocol differ.

### 2.1 Slot — `elem_t` (multi-multi broadcast), **96 bytes**

```
offset  size  field
   0     80   data_[80]   msg_t<64,8>, alignas(8)
  80      8   rc_         atomic<u64>  read-counter
  88      8   f_ct_       atomic<u64>  commit flag   ← route does NOT have this
------
  96          sizeof(elem_t)                          (route's is 88)
```

### 2.2 `rc_` bit-packing (channel-specific — route's math cannot be reused)

```
rc_mask = 0x00000000_ffffffff   // low 32: per-reader "still needs to read" bitmask
ep_mask = 0x00ffffff_ffffffff   // low 56: rc bits + internal read-generation
ep_incr = 0x01000000_00000000   // epoch increment (top byte)
ic_mask = 0xff000000_ffffffff   // invert-carry mask
ic_incr = 0x00000001_00000000   // internal read-generation increment (bits 32..)

inc_rc(rc)   = (rc & ic_mask) | ((rc + ic_incr) & ~ic_mask)
inc_mask(rc) = inc_rc(rc) & ~rc_mask
```

(Route packs a plain 32-bit epoch in the high word: `ep_mask=0xffffffff`,
`ep_incr=0x1_00000000`. Channel splits `rc_` into three regions — connection
bits, an internal read-generation counter, and a top-byte epoch.)

### 2.3 Header — `ct_` + `epoch_` (vs route's `wt_` + `epoch_`)

The `conn_head_base` prefix (`cc_`@0, `lc_`@4, `constructed_`@8; DCLP init) is
identical to route. The cache-line-aligned policy head then differs:

```
 64   ct_     atomic<u32>   commit index   (route has wt_ here)
128   epoch_  atomic<u64>                  (route's epoch_ is a plain u64, NOT atomic)
192   block_[256] of elem_t
```

`cursor()` returns `ct_` (not `wt_`). There is **no `wt_`**.

### 2.4 Push — the `ct_`/`f_ct_` two-phase commit (`prod_cons.h` L337-372)

```
epoch = epoch_.load(acquire)
loop:
  cc = connections()                      ; if cc == 0 return false (no reader)
  cur_ct = ct_.load(relaxed)
  el = block_[cur_ct % 256]
  cur_rc = el.rc_.load(relaxed)
  rem_cc = cur_rc & rc_mask
  if (cc & rem_cc) and (cur_rc & ~ep_mask) == epoch:  return false   // busy
  else if rem_cc == 0:
      cur_fl = el.f_ct_.load(acquire)
      if cur_fl != cur_ct and cur_fl != 0:            return false   // full
  # claim: CAS rc_ AND re-validate epoch, both must succeed
  if el.rc_.CAS(cur_rc, inc_mask(epoch | (cur_rc & ep_mask)) | cc, relaxed)
     and epoch_.CAS(epoch, epoch, acq_rel):
       break
  yield
ct_.store(cur_ct + 1, release)            // single owner of the won slot advances
write data_
el.f_ct_.store(~cur_ct, release)          // publish commit flag for the reader
```

### 2.5 Pop — `f_ct_` emptiness test + slot-free (`prod_cons.h` L413-440)

```
el = block_[cur % 256]
if el.f_ct_.load(acquire) != ~cur:  return false     // empty (not the flag we expect)
++cur
copy data_
loop:
  cur_rc = el.rc_.load(acquire)
  if (cur_rc & rc_mask) == 0:
      el.f_ct_.store(cur + N - 1, release)            // free slot for the next lap
      return last=true
  nxt_rc = inc_rc(cur_rc) & ~connected_id
  if (nxt_rc & rc_mask) == 0:  el.f_ct_.store(cur + N - 1, release)
  if el.rc_.CAS(cur_rc, nxt_rc, release):  return last=((nxt_rc & rc_mask)==0)
  yield
```

(`N` = ring size = 256; `connected_id` = this receiver's single `cc_` bit.)

### 2.6 `force_push` (`prod_cons.h` L374-411)

`epoch_.fetch_add(ep_incr, release)` (atomic, unlike route's plain `+=`), then
reclaim; on a stuck live reader it does a blanket `disconnect_receiver(rem_cc)`
(no reaper, unlike route). It may recurse into `push`. Only needed once the port
drives contention/timeouts; a first cut can spin-wait like route's pushFragment.

### 2.7 Ring shm size and sender-checker

`elem_array` = `conn_head_base`(→ block at **192**) + `block_[256]` +
`sender_checker` + `receiver_checker`, align-64. With 96-byte slots:
`192 + 96*256 (=24576) = 24768` → round to **≈24832** (compute per target; do not
hard-code). Multi-producer `sender_checker<true>` is **stateless** — no
`atomic_flag` guard byte, `connect()` always true (route's is `<false>`, single
guard). Ports must `ftruncate` to the full computed size.

### 2.8 Naming and counters — same names as route

- **Ring name is identical to route:** `…QU_CONN__<name>__64__<AlignSize>`
  (`ipc.cpp` L464-472 embeds only `DataSize` and `AlignSize`, never the policy or
  `sizeof(elem_t)`). Route and channel are distinguished purely by in-memory
  layout at the same name — so a channel ring is a **distinct ring type**, never
  a rename, and the two must not be opened under the same name concurrently.
- **`cc_id_`** from the prefix-global `CA_CONN__` counter — already correct in
  every port.
- **`msg_t.id_`** from the shared per-channel `AC_CONN__<name>` shm `atomic<u32>`,
  `fetch_add(1)` — this is Part B. `AC_CONN__` is the same segment route uses for
  its (single-writer) id; the fix is that channel writers must actually open and
  share it instead of using a process-local counter.

Waiters (`RD/WT/CC_CONN__`), liveness (`LV_CONN__`) and chunk storage
(`CHUNK_INFO__`) are the same segments as route.

---

## 3. Rollout order

1. **Zig (Phase 1) — ✅ done.** `zig/thoth-ipc/src/transport/channel_multi.zig`
   implements the multi-producer ring + `AC_CONN__` counter + `cwrite`/`cread`
   byte-exact with C++; `cpp+zig → {cpp,zig}` pass at 40/65/3000 B and `zig→zig`
   works. De-risked the hardest lock-free protocol against the reference.
   Scenario stays `xfail` overall until Rust/Swift land.
2. **Rust (Phase 2) — ✅ done.** `rust/thoth-ipc/src/channel.rs` adds the
   multi-producer ring + `AC_CONN__` counter behind a `multi` flag on `ChanInner`
   (route path untouched; `push_fragment`/`recv` dispatch to `_multi` variants).
   All `{cpp,rust,zig}` channel pairings pass.
3. **Swift (Phase 3) — ✅ done.** `swift/thoth-ipc/Sources/LibIPC/Transport/Channel.swift`
   adds the multi-producer ring + `AC_CONN__` counter behind the same `multi`
   flag on `ChanInner` (route path untouched; `pushFragment`/`recv` dispatch to
   `pushFragmentMulti`/`recvMulti`). All `{cpp,rust,swift,zig}` channel pairings pass.
4. **Flip the expectation — ✅ done.** `ChannelScenarioConfig::default().xfail`
   (`tools/xlang-runner/src/config.rs`) is now `false`; the whole `channel`
   scenario is expected-pass (72/72).

Each phase is independently verifiable: a port that implements the ring
correctly interoperates with C++ immediately (and with any other already-migrated
port), so progress is visible in the matrix pairing-by-pairing.

---

## 4. Per-language roadmaps

### 4.1 C++ — reference (no change)

C++ `thoth::channel` is the target ABI. `prod_cons.h` L301-441 is the source of
truth; keep it stable while the ports converge.

### 4.2 Zig — Phase 1 (next up)

Reuses all of the route port's infrastructure (shm, waiters, liveness, chunk,
notify, framing); only the ring element and push/pop protocol are new.

**Files**
- `zig/thoth-ipc/src/transport/channel_ring.zig` *(new)* — the multi-producer ring:
  the 96-byte `elem_t`, the `ct_`/`epoch_` header helpers, and `push`/`pop` per
  §2.4/§2.5 with comptime `@sizeOf`/`@offsetOf` guards (`elem_t` = 96, ring total
  ≈24832, `ct_`@64, `epoch_`@128).
- `zig/thoth-ipc/src/transport/channel.zig` — factor the shared open/connect/
  disconnect (DCLP init, `cc_` connect, waiters, liveness) so a `ChannelInner`
  can pick the multi-producer ring while `ChanInner` keeps the route ring;
  add the `AC_CONN__<name>` id counter (open the segment, `fetch_add(1)` per
  message) used by the channel send path.
- `zig/thoth-ipc/src/xlang.zig` — `cwrite`/`cread` verbs (mirror `write`/`read` but
  over the channel ring; reader expects `2*count`).
- `tools/xlang-ci.toml` — add `"channel"` to `[languages.zig].modes`.

**Steps**
1. Layout + comptime asserts (`channel_ring.zig`); confirm the ring shm total
   matches C++ (`zig build test`).
2. Push commit protocol (`ct_` claim + `f_ct_ = ~ct`), then pop (`f_ct_ == ~cur`
   emptiness + slot-free), memory orders per §2.
3. `AC_CONN__` id counter on the send path (Part B).
4. `cwrite`/`cread` + mode wiring; run `--scenario channel --require cpp,zig`.
5. Green criteria: `zig→cpp`, `cpp→zig`, `zig→zig` pass at sizes {40, 65, 3000}
   (3000 exercises Part B / multi-fragment reassembly).

**Not needed for the first cut:** `force_push` eviction (spin-wait like the route
`pushFragment`; the matrix readers are all live).

### 4.3 Rust — Phase 2 (✅ done)

**Files**
- `rust/thoth-ipc/src/channel.rs` — today `Route` and `Channel` are both thin
  wrappers over one `ChanInner` (88-byte route ring; comment L997-999 says so).
  Split `Channel` onto a new multi-producer inner: 96-byte `ElemT`
  (`f_ct_` field; drop the `size_of == 88` assert for the channel variant),
  `RingHeader` with `ct_`/`epoch_` instead of `write_cursor`, and the §2.4/§2.5
  protocol. Add the `AC_CONN__<name>` counter for `msg_t.id_` (replace the
  process-local `send_seq`, L255/L532-533).
- `rust/thoth-ipc/src/bin/xlang.rs` — `cwrite`/`cread` already call
  `Channel::connect` (L29-72); no verb change, just point at the new inner.

**Green criteria:** all `{cpp, rust, zig}` channel pairings pass.

### 4.4 Swift — Phase 3 (✅ done)

**Files**
- `swift/thoth-ipc/Sources/LibIPC/Transport/Channel.swift` +
  `ChannelTail.swift` — `Route` and `Channel` share `ChanInner`
  (`elemStride 88`, `writeCursor`@64, `ringShmSizeBytes 22784`). Add a
  multi-producer variant: 96-byte stride, `ct_`/`epoch_` header, channel `rc_`
  math, the §2.4/§2.5 protocol, ring size ≈24832, and the `AC_CONN__` id counter
  (replace `sendSeq`, L158/L364).
- `swift/thoth-ipc/Sources/XlangHarness/main.swift` — `doCwrite`/`doCread` already
  wired (L344-359); point them at the channel inner.

**Green criteria:** the full 4-language `channel` matrix passes; flip the xfail.

---

## 5. Done criteria

- `--scenario channel --require cpp,rust,swift,zig --strict-caps` is green across
  every `{w1,w2}→r` pairing at sizes {40, 65, 3000}.
- `ChannelScenarioConfig::default().xfail` flipped to `false`
  (`tools/xlang-runner/src/config.rs`).
- README known-gaps and [`xlang-channel-abi.md`](xlang-channel-abi.md) updated to
  move multi-writer `channel` from "gap" to "supported".
