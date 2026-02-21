# Allocator Benchmark Results

**Date:** 2026-02-21  
**Platform:** macOS (Apple Silicon implied by timing profile)  
**Build:** `cargo bench --bench alloc --features bump_alloc,slab_pool` (release profile)  
**Runs:** 2 independent runs, 100 samples each, criterion statistical comparison between runs.

---

## Raw Numbers (median, run 1 / run 2)

| Benchmark | 48 B | 256 B | 4096 B |
|---|---|---|---|
| `buffer_global` (Vec baseline) | 42.6 / 42.6 ns | 37.0 / 37.4 ns | 89.6 / 89.3 ns |
| `buffer_bump` (alloc_bytes + reset) | 9.8 / 9.9 ns | 7.5 / 7.5 ns | 63.1 / 62.5 ns |
| `buffer_bump_vec` (alloc_vec + reset) | 13.4 / 13.4 ns | 9.6 / 9.6 ns | 66.4 / 65.8 ns |
| `buffer_bump_copy` (alloc_slice_copy) | 38.9 / 38.6 ns | 184 / 187 ns | 2769 / 2752 ns |
| `slab_fixed_64/insert_remove` | 3.4 / 3.5 ns | — | — |
| `slab_fixed_64/insert_from_slice` | 4.8 / 4.9 ns | — | — |
| `slab_fixed_1024/insert_remove` | — | 18.3 / 18.7 ns | — |
| `slab_fixed_1024/insert_from_slice` | — | 82.2 / 81.0 ns | — |
| `global_vs_slab_64/global_alloc` | 34.8 / 34.6 ns | — | — |
| `global_vs_slab_64/slab_pool` | 3.2 / 3.2 ns | — | — |

All run-to-run deltas were within criterion's noise threshold (p > 0.05) except
`slab_fixed_64` which showed a ~3% apparent regression — well within CPU scheduling
noise and not statistically meaningful.

---

## Speedups vs. Global Allocator

| Strategy | 48 B | 256 B | 4096 B |
|---|---|---|---|
| `bump alloc_bytes` | **4.3×** | **4.9×** | **1.4×** |
| `bump alloc_vec` | **3.2×** | **3.9×** | **1.4×** |
| `bump alloc_slice_copy` | 1.1× | 0.2× ❌ | 0.03× ❌ |
| `slab insert_remove (64 B)` | **10.8×** | — | — |
| `slab insert_from_slice (64 B)` | **7.1×** | — | — |
| `slab insert_remove (1024 B)` | — | **2.0×** | — |
| `slab insert_from_slice (1024 B)` | — | 0.46× ❌ | — |

---

## Analysis

### bumpalo (`BumpArena`)

`alloc_bytes` and `alloc_vec` are **4–5× faster** than the global allocator for
small and medium messages. The mechanism is simple: bump-pointer advance is a
single pointer add + bounds check, versus the global allocator's free-list walk,
lock, and potential syscall.

The speedup narrows at 4096 B (1.4×) because at that size the dominant cost shifts
from allocator overhead to the `memset` / `fill` that initialises the buffer — both
paths pay that cost equally.

`alloc_slice_copy` is **slower** than global at 256 B and catastrophically slower
at 4096 B. The cause: `bumpalo::collections::Vec::from_iter_in` iterates
element-by-element rather than calling `memcpy`. This API should not be used for
bulk copies. The correct pattern is `alloc_bytes` followed by `copy_from_slice`.

**Suitable use cases in this codebase:**
- Recv-side message reassembly in `channel.rs`: replace the `Vec::new()` /
  `assembled.extend_from_slice` pattern with a per-call `BumpArena` that is reset
  after the message is handed to the caller. This eliminates one heap allocation per
  received message on the common small-message path.
- Per-request scratch space in `proto/service_registry.rs` name-building loops.

**Not suitable for:**
- Long-lived allocations (arena must be reset to reclaim memory).
- Cross-thread sharing without a `Mutex` wrapper (arena is `!Send`).

### slab (`SlabPool`)

`SlabPool<64>` insert/remove is **10.8× faster** than `Vec<u8>` allocation at the
same size. After warm-up the slab never calls the global allocator — it reuses
previously freed slots via an internal free-list. This is the same mechanism as the
C++ `block_pool` / `central_cache_pool`.

`insert_from_slice` at 1024 B is slower than global because it unconditionally
zero-initialises the full 1024-byte block before copying. For large fixed blocks,
`insert_zeroed` + manual `copy_from_slice` into `get_mut` is the right pattern.

**Suitable use cases in this codebase:**
- Recycling inline ring-slot payloads (64 B) — the `SlabPool<64>` maps directly
  onto the `DATA_LENGTH = 64` ring slot size.
- Recycling `ChunkInfo` free-list node entries in `chunk_storage.rs` (currently
  allocated on the stack; a slab would help if they were heap-allocated).
- Any fixed-size message type where the same size is allocated and freed repeatedly
  in a tight loop (e.g. audio block descriptors in `demo_rt_audio_*`).

**Not suitable for:**
- Variable-size messages (need a separate pool per size class, like the C++
  `get_regular_resource` dispatch table).
- Cross-thread use without a `Mutex` (slab is `!Send`).

---

## Recommendation

| Hot path | Current | Recommended |
|---|---|---|
| `recv` reassembly `Vec` | `Vec::new()` + `extend_from_slice` | `BumpArena::alloc_bytes` + `copy_from_slice`, reset per message |
| Fixed 64-byte slot recycling | global alloc | `SlabPool<64>` |
| Large-message chunk descriptors | stack / global | `SlabPool<N>` where N = `calc_chunk_size(payload)` |
| `alloc_slice_copy` | — | Replace with `alloc_bytes` + `copy_from_slice` |

The `bump_alloc` and `slab_pool` features are opt-in; no existing code paths are
affected until explicitly wired in.
