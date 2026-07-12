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

## 7. Verification

Every port change is validated by a C++-writer ↔ port-reader round-trip
(message payload + `recv_count`), added as a standing regression test so any future
drift in names **or** layout fails CI. Same-language suites do **not** catch ABI
drift and never have.
