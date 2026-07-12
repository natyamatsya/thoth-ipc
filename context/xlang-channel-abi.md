# Cross-language channel wire ABI (broadcast route/channel)

**Status:** Reference spec for aligning the Rust and Swift ports to the C++
implementation (thoth-ipc is expressly intended for cross-language interop; the
pure ports currently diverge — this is the target to fix).

**Canonical implementation:** C++ (`cpp/libipc`), the original cpp-ipc lock-free
`prod_cons`. Rust (`rust/libipc`) and Swift (`swift/libipc`) must match it
byte-for-byte and semantically. Verify every change against the C++↔port harness
(`context/` prototype: C++ writer ↔ port reader message exchange + `recv_count`).

All offsets/sizes below are for **`ipc::route` / `ipc::channel`** =
`chan<single|multi, multi, broadcast>` on a 64-bit target. Two values are
**platform-dependent** and must be computed, not hard-coded:
`AlignSize = min(64, alignof(max_align_t))` (8 on Apple arm64, 16 on x86-64 /
Linux aarch64) and the `spin_lock` type in the header (below).

## 1. Object names (per channel)

C++ `make_prefix(prefix, TAG, name, …) = prefix + "__IPC_SHM__" + TAG + name + …`;
POSIX names then get `/` prefixed and, when > `LIBIPC_SHM_NAME_MAX` (31 on macOS),
FNV-1a-shortened to `/<first-13-chars>_<16-hex>`.

| object | logical name | notes |
|---|---|---|
| ring | `__IPC_SHM__QU_CONN__<name>__<DataSize>__<AlignSize>` | DataSize=64, AlignSize=8/16 |
| rd waiter | `__IPC_SHM__RD_CONN__<name>` | Waiter appends `_WAITER_COND_` / `_WAITER_LOCK_` |
| wt waiter | `__IPC_SHM__WT_CONN__<name>` | |
| cc waiter | `__IPC_SHM__CC_CONN__<name>` | |
| cc-id counter | `__IPC_SHM__CA_CONN__<name>` | shared `atomic<u32>` |
| notify (Layer 1) | key `ipc.ntf.<16-hex FNV-1a of __IPC_SHM__NOTIFY__<name>>` | libnotify (macOS) |

## 2. Ring shm layout — `elem_array<broadcast, DataSize=80, AlignSize=8>`

The queue element type is `T = msg_t<64, 8>` (§4); the elem_array is parameterised
by `sizeof(T)=80`, `alignof(T)=8`. Total `sizeof(elem_array)` = **22784 bytes**
(Apple arm64) — verified against the real C++ type. The bytes after `block_`
(offset 192 + 88·256 = 22720) hold `elem_array`'s trailing `sender_checker`
(`atomic_flag`, single-producer guard) + `receiver_checker`, then align-64 padding.
Ports must `shm_open`/`ftruncate` the ring to the full 22784 so the sender flag
maps.

```
offset  size  field
------  ----  -----------------------------------------------------------
   0     4    conn_head_base.cc_        atomic<u32>  connection bitmask
   4     4    conn_head_base.lc_        spin_lock (Apple: os_unfair_lock = u32)
   8     1    conn_head_base.constructed_ atomic<bool>   (DCLP init flag)
  [9..64 padding — head_ is alignas(64)]
  64     4    head_.wt_                 atomic<u32>  write index      (cache line 1)
 128     8    head_.epoch_              u64          writer epoch     (cache line 2)
 192   88*256 block_[256] of elem_t                                  (§3)
------
22720        total
```

- `conn_head_base` = `{ cc_(u32), lc_(spin_lock), constructed_(atomic bool) }`,
  size 12, align 4. **`lc_` is platform-specific**: Apple `os_unfair_lock` (u32);
  Linux uses the fork's `spin_lock` (check `platform/*/spin_lock.h` for size).
- `head_` (`prod_cons_impl<…,broadcast>`) = `{ alignas(64) wt_(atomic u32);
  alignas(64) epoch_(u64); }`, size 128, align 64.

## 3. Slot — `elem_t` (broadcast)

```
offset  size  field
   0     80   data_[80]     holds a msg_t<64,8> (§4); alignas(8)
  80      8   rc_           atomic<u64> read-counter
------
  88          sizeof(elem_t), align 8
```

`rc_` packs a per-reader "still needs to read" bitmask and an epoch generation:
`ep_mask = 0x0000_0000_ffff_ffff` (low 32 = connection bits), `ep_incr =
0x0000_0001_0000_0000` (high 32 = epoch). A slot is free when `(rc_ & ep_mask) == 0`
or its epoch ≠ the writer's current `epoch_`.

## 4. Message framing — `msg_t<64, 8>` (lives inside `elem_t.data_`)

```
offset  size  field
   0     4    cc_id_    u32   sender identity (self-message filtering)
   4     4    id_       u32   message id (fragments of one message share it)
   8     4    remain_   i32   bytes remaining after this fragment (see below)
  12     1    storage_  bool  payload is a storage_id (large-message path)
  [13..16 padding]
  16     64   data_[64] payload fragment (or a storage_id when storage_)
------
  80          sizeof(msg_t<64,8>), align 8
```

Fragmentation: a message larger than `data_length` (64) is split; each fragment's
`remain_` is the count still to come, so the receiver reassembles by `id_` until
`remain_ <= 0`. `data_length + remain_` gives the fragment's byte count.

## 5. Init protocol (DCLP) — critical for cross-language

`conn_head_base::init()` is a double-checked-locking construct: if
`constructed_ == false`, it takes `lc_` (the spin_lock), placement-news the header
(zeroing `cc_`), then sets `constructed_ = true`. **A port that opens the ring
without participating will (a) be re-zeroed by a C++ peer that sees
`constructed_==0`, and (b) corrupt `lc_`/`constructed_` if it lays other fields
over offsets 4–8.** Ports must replicate `conn_head_base` exactly and run the same
DCLP (on Apple, via `os_unfair_lock_lock`/`unlock`).

## 6. Connect / count / push / pop (broadcast, `prod_cons_impl<single,multi,broadcast>`)

- **connect (receiver):** CAS `cc_ = cc_ | (cc_+1)` (set lowest clear bit); the
  returned single-bit value is this receiver's `connected_id`. `recv_count` =
  popcount(`cc_`).
- **cursor:** `wt_` (acquire).
- **push:** if `cc_==0` return false; `el = block_[wt_ % 256]`; if
  `(cc_ & (rc_ & ep_mask))` and `rc_`'s epoch == `epoch_`, slot still busy → false;
  else CAS `rc_ = epoch_ | cc_`; write `data_`; `wt_ += 1`.
- **force_push:** `epoch_ += ep_incr`; like push but disconnects readers whose bits
  linger (`disconnect_receiver(rem_cc)`).
- **pop:** if `cur == wt_` return empty; read `block_[cur++ % 256].data_`; CAS
  `rc_ &= ~connected_id`; message fully consumed when `(rc_ & ep_mask) == 0`.

See `cpp/libipc/src/libipc/prod_cons.h` for the exact CAS/memory-order details —
match them verbatim.

## 6a. Identity & message-id counters (self-filtering + reassembly)

Two shared `atomic<u32>` counters, distinct from the ring:

- **`cc_id_` (endpoint identity)** — from `cc_acc(prefix)` = shm
  `__IPC_SHM__CA_CONN__` (**prefix-global, NO channel name**), `fetch_add(1)+1`
  (never 0). Written into every `msg_t.cc_id_`; a receiver drops a fragment when
  `msg.cc_id_ == its own cc_id_` (self-message filter). **A port must draw
  `cc_id` from this exact prefix-global counter** — a per-channel counter makes a
  C++ sender and a port receiver collide on `cc_id` and the receiver silently
  drops every message.
- **`id_` (message id)** — from `__IPC_SHM__AC_CONN__<name>` (per-channel),
  `fetch_add(1)`. Groups fragments of one message in the receiver's reassembly
  cache. Irrelevant for single-fragment (≤64 B) messages.

## 6b. Reassembly (receiver cache, keyed by `id_`)

Per fragment: skip if self; `r_size = data_length + remain_` (must be > 0).
- **not cached, `r_size ≤ data_length`** → single fragment, return `data_[0..r_size]`.
- **not cached, `r_size > data_length`** → first fragment: allocate an `r_size`
  buffer, copy the first `data_length` bytes, cache `{offset=data_length, buf}`.
- **cached, `remain_ > 0`** → append `data_length` bytes, advance offset.
- **cached, `remain_ ≤ 0`** → last fragment: append `data_length + remain_` bytes,
  return the buffer, erase the cache entry.

Fragments of one message arrive in ring order (single producer), so the append is
sequential.

## 6c. Large messages (>`large_msg_limit` = 64) — chunk storage

C++ does **not** fragment messages >64 B by default: it stores the payload in a
separate chunk shm and pushes a single `msg_t` with `storage_ = true` and the
`storage_id` (i32) in `data_[0..4]`; `remain_ = size - data_length` still carries
the total. Fragmentation is only the fallback when storage acquisition fails.

**Asymmetry that helps:** C++ `recv` reassembles fragments too, so a port
*sender* may keep fragmenting >64 B (C++ reassembles). Only a port *receiver*
must decode C++'s storage messages. For the agent bridge (app sends >64 B JSON
events; bridge receives), the **read path is the one that matters.**

Byte-exact chunk-storage layout (Apple arm64):

- **`calc_chunk_size(size)`** = `ceil((8 + size) / 1024) * 1024`
  (= `make_align(8, align_chunk_size(make_align(8, sizeof(atomic<cc_t>)=4) + size))`,
  `large_msg_align = 1024`). The chunk-shm name embeds this, so it must match.
- **shm name** `__IPC_SHM__CHUNK_INFO__<chunk_size>` — **per (prefix, chunk_size)**,
  NOT per channel. Size = `sizeof(chunk_info_t) + max_count·chunk_size`.
- **`chunk_info_t`** = `{ id_pool pool_; spin_lock lock_; }`:
  `pool_` = `{ next_[max_count] (u8 each); cursor_ (u8); prepared_ (bool) }`
  (`max_count = large_msg_cache = 32`; 34 B), then `lock_` (os_unfair_lock) at
  offset 36 → `sizeof = 40`. Chunks start at offset 40 (`this + 1`).
- **`id_pool`** free-list: `init` sets `next_[i] = i+1`; `acquire` → `id = cursor_;
  cursor_ = next_[id]`; `release(id)` → `next_[id] = cursor_; cursor_ = id`.
  `prepare()` runs `init` once when the pool is all-zero (`invalid()` = memcmp
  vs a zeroed pool). A cross-language *receiver* only needs `release` (recycle);
  the C++ sender already `prepare`d + `acquire`d.
- **`chunk_t`** at `chunks_mem + chunk_size·id`: `conns` (AtomicU32) `@0`, payload
  `data()` `@ make_align(8, 4) = 8`.
- **read (`find_storage`)**: `chunk(id).data()` (offset 8), read `r_size` bytes.
- **recycle (`recycle_storage`)**: clear this receiver's bit from `chunk.conns`
  (broadcast `sub_rc`); when it reaches 0, `lock_`; `pool_.release(id)`; unlock.

`storage_id_t = i32`. Rust's current `chunk_storage` diverges on all of the above
(tag `CH_CONN__` vs `CHUNK_INFO__`, header 4 vs 8, `calc_chunk_size`, field order)
and must be realigned.

## 7. Verification

Every port change is validated by a writer ↔ reader round-trip (message payload
+ `recv_count`). Same-language suites do **not** catch ABI drift and never have,
so this is a standing, automated regression test.

**Standing matrix test.** Each language ships a small harness binary with a
uniform CLI (`<bin> write|read|clear <name> <count> <size>`):

| language | harness | built by |
|---|---|---|
| C++ | `xlang_ipc` | `cpp/libipc/test/xlang/xlang.cpp` (CMake, `LIBIPC_BUILD_TESTS`) |
| Rust | `xlang` | `rust/libipc/src/bin/xlang.rs` (`cargo build --bin xlang`) |
| Swift | `xlang-harness` | `swift/libipc/Sources/XlangHarness` (SwiftPM) |

`tools/xlang_matrix.py` runs **every writer→reader pairing** (the full N×N
matrix) over an `ipc::route` channel at payload sizes `{40, 65, 200, 3000}` —
covering single-fragment (≤64), just-over-64, and chunk-storage paths — and
checks the reader receives exactly what the writer sent, byte-for-byte (payload
pattern `byte[i] = 'A' + (i%26)`). Any drift in names **or** layout fails a
pairing. `.github/workflows/xlang.yml` runs the C++↔Rust matrix on Linux and the
full C++/Rust/Swift 3×3 on macOS.

## 8. Layer 1 — notify readiness (optional async receive)

An **opt-in** notify layer turns channel readiness into a waitable fd so an async
receiver (C++ stdexec `async_recv`, Rust `AsyncRoute`) can be woken by any
language's sender instead of blocking a thread. It sits *on top of* the wire ABI
(the shm ring is unchanged); it is off unless enabled: C++ `LIBIPC_NOTIFY_FD`,
Rust `notify`/`async-tokio` features. **A sender posts on enqueue; a receiver
registers a readiness fd** — so for a port send to wake a C++ `async_recv`, the
notify identity must be byte-exact.

- **Channel identity hash** — `notify_hash(prefix, name)` = 16-lowercase-hex of
  `fnv1a_64("{prefix}__IPC_SHM__NOTIFY__{name}")` (i.e. `make_prefix(prefix,
  "NOTIFY__", name)`). Golden: `("", "xchan") → d7484adebb2d170d`;
  `("app", "st.agent.cmd") → ad223836b598bfaa`.
- **macOS backend — libnotify** (default on Apple): service key
  `"ipc.ntf." + notify_hash`. Sender `notify_post(key)` (multicast — one post
  wakes every registered reader, honouring 1→N/N→N broadcast). Reader
  `notify_register_file_descriptor(key, &fd, 0, &tok)` → an fd that receives a
  token int per post; drain by reading ints until `EAGAIN`.
- **POSIX backend — named FIFO** (Linux; Apple with `LIBIPC_NOTIFY_FIFO` /
  Rust `notify_fifo`): per reader **slot** `s ∈ 0..31`, path
  `<dir>/ipcntf_<notify_hash>.<s>` (`dir` = `$LIBIPC_NOTIFY_DIR` or `/tmp`).
  FIFO is point-to-point, so a sender pokes every connected slot except its own;
  a receiver owns the FIFO for its connection slot (`s = ctz(connected_id)`).
- **native_wait_handle()** returns the reader's fd (or the invalid handle if the
  peer lacks the notify layer / is not a receiver). The Rust/Swift sink is
  registered **lazily** on first `native_wait_handle()`, keeping the blocking recv
  path zero-cost even with the feature compiled in.

**Consumers per language:** C++ stdexec `async_recv` (sender + reactor); Rust
`AsyncRoute::recv().await` (tokio `AsyncFd`); Swift `AsyncRoute.recv() async`
(`DispatchSource` on the fd). All three sit on the same byte-exact notify key, so
a `send()` in any language wakes an async receiver in any other.

**Verification.** `xlang_matrix.py --async-lang …` runs the async matrix: a
writer's notify must wake an async receiver (verb `aread`) on its readiness fd —
so divergent notify keys fail a pairing. Harnesses: C++ `xasync`
(`LIBIPC_STDEXEC`), Rust `xlang aread` (`async-tokio`), Swift `xlang-harness
aread`. CI runs the C++↔Rust async matrix on Linux (FIFO) and the full
C++/Rust/Swift 3×3 on macOS (libnotify). A Rust unit test also pins `notify_hash`
to the golden values above.

## 9. Dead-connection reaper owner table (LV_CONN__)

A SIGKILLed broadcast receiver never clears its `cc_` bit — a *phantom* that
stalls ring reclamation, exhausts the 32-slot space, and inflates `recv_count`
(RFC: [`dead-connection-reaper-rfc.md`](dead-connection-reaper-rfc.md)). Each
receiver records `{ pid, start_token }` in a dedicated segment so **any**
participant (any language) can reap a slot whose owner process has died. Because
any language's reaper may check any language's owner, the table **and** the token
formula are cross-language ABI.

- **Segment** `make_prefix(prefix, "LV_CONN__", name)` =
  `"{prefix}__IPC_SHM__LV_CONN__{name}"`, size **512 B**.
- **`slot_owner`** (one per `cc_` bit, indexed by `ctz(bit)`), **16 B**:
  `pid` (int32) `@0`, `start_tok` (uint64) `@8`. Array `slot_owner[32]`.
- **`start_token(pid)`** — a stable id of *this* incarnation of a PID (defeats PID
  reuse). 0 = "couldn't determine". macOS: `proc_pidinfo(PROC_PIDTBSDINFO)` packed
  as `pbi_start_tvsec * 1'000'000 + pbi_start_tvusec` (`proc_bsdinfo` is 136 B,
  `pbi_start_tvsec @120`, `pbi_start_tvusec @128`). Linux: `/proc/<pid>/stat`
  field 22 (starttime jiffies). **This formula must be identical across ports** —
  otherwise a reaper of language A would compute a different token than language B
  stored and *false-reap a live B receiver*.
- **Protocol.** On connect (broadcast receiver): reap dead peers, then claim a
  `cc_` bit, then store `{ getpid(), start_token(getpid()) }` (token first, pid
  with release). On disconnect: clear the slot. Reap = for each set `cc_` bit
  whose owner is dead (`kill(pid,0)` gone, *or* a live PID whose token no longer
  matches), CAS the owner `pid: p→0` and clear the bit. **Safe by default:** a
  slot with `pid == 0` (an un-upgraded port, or mid-connect) is skipped — never a
  false reap. C++ additionally reaps in `force_push` (route policy).
- **Non-broadcast** channels do not use this table (`cc_` is a plain count).

**Verification.** `xlang_matrix.py --reap-lang …` runs the reap matrix: every
`{holder} × {reaper}` pairing, `dead` (holder SIGKILLed → reaper's `count` must be
1) and `live` (holder alive → `count` must be 2, proving no false reap and thus a
matching token). Harness verbs `hold` / `probe` / `count` in all three ports.
