# Review: why the ABI machinery missed a wrong lock in three ports

**Date:** 2026-08-15. **Prompted by:** `conn_head_base::lc_` and
`chunk_info_t::lock_` being driven with `os_unfair_lock` in the Rust, Swift and
Zig ports while the C++ takes them with `thoth::spin_lock` (atomic<u32>
test-and-set). Wrong in three ports, in `abi/abi.json`, and in
`context/xlang-channel-abi.md` — while a 363-case cross-language matrix passed.

This reviews *why*, not the bug itself.

## What the ABI machinery actually guarantees

It is three tiers, and only two of them are mechanised.

**Tier 1 — layout. Strong.** `abi/abi.json` holds sizes, offsets and alignment
per target; `tools/abi` generates per-language constants; every port asserts its
structs against them (`const _: () = { assert!(offset_of!(..) == abi::..) }` in
Rust, `static_assert` in C++, `assertHeaderLayout()` in Swift). Drift in a field
offset cannot survive a build.

**Tier 2 — sync-primitive identity. Strong, but narrow.** `syncabi_stamp` is a
sidecar carrying `magic / ver_major / ver_minor / backend_id / primitive_id /
payload_size`. The first participant stamps it; later ones `validate()` and fail
loudly on mismatch. This is a genuine runtime negotiation of *which algorithm*
two processes are running over shared bytes — exactly the right idea.

Its `primitive_id` vocabulary is `1=mutex, 2=condition`. That is all.

**Tier 3 — every other protocol over shared bytes. Prose only.** Nothing checks
these:

- the two in-shm spin locks (`lc_` @4, `chunk_info_t::lock_` @36)
- the `id_pool` free-list algorithm (`next_`/`cursor_`/`prepared_`), and the
  `invalid()` rule for detecting a fresh pool
- the `conns` bitmask protocol (which bit, cleared by whom, who releases the
  chunk when it hits 0)
- ring-slot `rc_` release, cursor/epoch advance rules

Each port reimplements these from the C++ by hand, guided by comments. The lock
lived here.

## Why the field type could not have helped

In `abi.json` the ring header's lock is `{"name": "lc", "type": "lock"}`. `lock`
is a category with no semantics: the generator can emit an offset and a size
from it and nothing else. All the meaning — *what algorithm operates on these
four bytes* — lived in the field's `description` string, which said
"os_unfair_lock on Apple" and was wrong. A prose field in a machine-readable
schema reads as authoritative and is checked by nothing.

`chunk_info_t` is worse: it has no struct entry at all. Only two loose constants
(`chunk_info_size`, `chunk_header_size`) are generated, and every port hardcodes
the field offsets — `0/32/33/36` appear as literals in Rust, Swift and Zig
alike. The structure whose lock was wrong is the one shared structure the ABI
does not describe.

## Why the 363-case matrix passed

Two independent reasons, and both generalise.

**1. The divergence is benign on the happy path.** Both algorithms acquire only
from 0 and store non-zero, so they *do* exclude each other uncontended —
measured: `os_unfair_lock_trylock` over a TAS-held lock fails. The undefined
behaviour is in os_unfair_lock's contended path, where it treats the field as a
thread token to park on and donate priority to, and the peer stores `1` there.
A matrix of one-writer/one-reader pairings barely contends the chunk pool.

**2. The matrix asserts payloads, not control state.** Cases check that the
bytes a reader received equal the bytes a writer sent. That is insensitive to
*how* the two coordinated, as long as coordination happened to work. No case
inspects a lock, a pool cursor, or a conns mask.

Note the matrix has caught a tier-3 bug before — the cpp↔port semaphore gap
recorded in `tools/xlang-ci.toml`. It caught that one because a semaphore
mismatch breaks liveness: things hang. A lock mismatch does not hang. So the
matrix catches tier-3 divergences only when they happen to break liveness, which
is a property of the bug, not of the test.

## What would have caught it

A ten-line probe: take the lock, print the raw u32. C++ writes `0x00000001`;
os_unfair_lock writes a thread token (`0x00000103` in the same probe). That
difference is visible in milliseconds and needs no contention, no matrix, and no
reasoning about which header declares what.

The repo already has the shape of this idea for *names* —
`chunk_shm_name_matches_generated_golden` asserts a port's constructed shm name
against a generated golden. The same trick applied to *state transitions* rather
than names is the missing tier-3 guard.

## Outcome (2026-08-15)

All five recommendations were worked through; four landed, one was assessed and
declined.

| # | Recommendation | Outcome |
|---|---|---|
| 1 | Byte-golden conformance probes | **Done.** `conform` scenario, 9 cases. Found a second divergence on its first run (below). |
| 2 | Extend `primitive_id` to spin locks | **Declined**, see below. |
| 3 | Describe `chunk_info_t` in abi.json | **Done.** Ports assert generated offsets instead of literals. |
| 4 | Stop prose carrying semantics | **Done.** `protocol` tags + `abi/protocols.txt`; the runner refuses to run when a declared protocol has no probe. |
| 5 | Contention scenario | **Done.** `contend`, 8 cases at chunk-storage sizes. |

**What the probes found immediately.** `idpool-partial` failed on its first run:
C++ decides a pool is fresh by comparing the *whole* structure against a zeroed
one (`id_pool::invalid()` is a memcmp), while all three ports sampled only
`next_[0]`, `cursor_` and `prepared_`. A partially written pool — a torn init —
therefore read as fresh to the ports and as used to C++, and the two would
disagree about whether to rebuild the free list. Latent rather than live, but it
is precisely the tier-3 class this review is about, and it had been sitting
under a green 363-case matrix.

**Follow-on.** The probes exposed a weakness in their own design: `idpool`
bundled prepare, acquire and release, so the Zig port — which had only the
receiving half of chunk storage — could not answer for `poolRelease`, which it
did implement. Split out as `idpool-release` (seeded by writing the pool's
bytes), and Zig's allocator half was then implemented for symmetry with Rust's,
closing both remaining gaps. `conform` is 12/12 with no NOT IMPLEMENTED section.

**Why recommendation 2 was declined.** Each SyncAbi stamp is its own shm object
(`<name><sidecar_suffix>`), so covering the spin locks means a new segment per
ring *and* per chunk pool, created and validated by the C++ reference as well —
otherwise the ports stamp something nothing checks. That is a wire change across
four implementations to buy protection against run-time peer skew, which the
conformance probes now cover at build time for free, and which the application
layer already covers separately via the build-id handshake
(`git:<hash>+thoth-ipc:<version>`, reported as skew on connect). Revisit only if
a skew bug appears that neither mechanism catches.

## Recommendations, in priority order

1. **Byte-golden conformance for tier-3 primitives.** Give each harness a
   `probe <primitive>` command that performs a fixed operation sequence on a
   shared field and dumps the raw bytes after each step (lock → dump → unlock →
   dump; pool acquire ×3 → dump `next_`/`cursor_`; clear a conns bit → dump).
   The runner compares traces across languages byte-for-byte, with C++ as the
   reference. This converts "prose protocol" into something a machine checks,
   and it is cheap: no contention, no timing, no flakiness.

2. **Extend `primitive_id` to the spin locks.** Tier 2 already does runtime
   algorithm negotiation. Adding `3 = spin_lock` with a backend id (TAS vs
   unfair) would have made this a loud startup error rather than silent
   undefined behaviour. The stamp is a sidecar, so no shared layout changes.

3. **Describe `chunk_info_t` in `abi.json`** as a struct with fields, so the
   ports stop hand-copying `0/32/33/36` and the offsets become assertable like
   every other structure's.

4. **Stop letting prose carry semantics.** Two fixes: replace free-text
   `description` for protocol-bearing fields with a machine-checked
   `protocol` tag that the conformance runner consumes; and treat
   `context/xlang-channel-abi.md` as generated-or-tested rather than
   hand-maintained — it restated C++ behaviour and drifted, and three ports
   trusted it over the source.

5. **Add a contention scenario to the matrix.** Two languages hammering one
   chunk pool concurrently exercises the contended paths where tier-3
   divergences actually bite. This would not have caught the lock bug quickly,
   but it is the class of coverage the matrix is missing.

## The transferable lesson

The matrix tests the wire; nothing tested the *coordination*. Bytes arriving
intact is a weak oracle for a shared-memory protocol, because the failure modes
are timing-dependent and mostly benign until they are not. A comment asserting a
fact about a peer implementation — "the header lc_ field is an os_unfair_lock in
the C++ ABI, so we must drive the real Apple primitive, not a look-alike" — is
not evidence, and it was repeated confidently in four places at once. Facts about
a peer's behaviour should be extracted from the peer by a program, not restated
by a human.
