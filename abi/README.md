<!-- SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors -->

# thoth-ipc ABI — language-neutral source of truth

The C++, Rust, Swift and Zig ports must agree byte-for-byte on a large surface of
ABI **constants and layouts**: ring sizes/offsets, the `rc_` masks, shm-name
tags, the SIPC envelope and `SyncAbi` stamp framing, enum ids, and so on. Today
each port hand-maintains these; a mask updated in one port but not another is
exactly the silent drift the xlang matrix exists to catch.

This directory is the (in-progress) fix: **one machine-readable spec the ports
are generated from and checked against, as peers.** C++ is *not* privileged here
— its historical role as the reference (it's the cpp-ipc fork base) is decoupled
from the source of truth. See
[`context/xlang-channel-multiwriter-rfc.md`](../context/xlang-channel-multiwriter-rfc.md)
for the parallel channel work and
[`context/xlang-channel-abi.md`](../context/xlang-channel-abi.md) for the prose ABI.

## Files

| file | role |
|---|---|
| [`abi.json`](abi.json) | the ABI spec — constants, enums, structs, naming templates, per-target values |
| [`abi.schema.json`](abi.schema.json) | JSON Schema for `abi.json` — the **structural** gate + editor validation |
| [`dump_abi.cpp`](dump_abi.cpp) | tiny C++ probe that emits the *deployed* ABI values (`sizeof`/masks/constants) as JSON |
| [`../tools/abi`](../tools/abi) | Rust `check` + `generate` — validates `abi.json` and emits per-language modules |
| [`EXAMPLE.md`](EXAMPLE.md) | **hands-on walkthrough** — trace one constant through all four ports and watch the gates catch a deliberate mistake |

The generated modules live in each port's own tree (`rust/…/abi_generated.rs`,
`swift/…/abi_generated.swift`, `zig/…/abi_generated.zig`,
`cpp/…/abi_generated.hpp`) — every port consumes its own, so there is no longer a
shared `generated/` directory.

## Three gates

1. **Structural** — `abi.json` is validated against `abi.schema.json` (well-formed
   document: fields, types, patterns). *Not* ABI semantics.
2. **Semantic** — `tools/abi` compiles + runs `dump_abi.cpp` and diffs its
   ground-truth values against `abi.json`, so the spec can never silently diverge
   from what C++ actually compiles. The dumper covers the header-introspectable
   surface (ring/elem sizes, `rc_` masks, `def.h` constants); values it can't yet
   reach (e.g. `msg_t`, which lives in `ipc.cpp`) are reported as coverage gaps
   and remain matrix-verified.
3. **Behavioural** — the [xlang matrix](../tools/xlang-runner) proves the
   *protocols* interoperate. An IDL owns *data*, not lock-free algorithms; those
   stay hand-written per language and are verified end-to-end here.

Run the first two locally (from the repo root; needs Rust + a C++20 compiler):

```sh
cargo run --manifest-path tools/abi/Cargo.toml
```

## Design decisions

- **JSON + JSON Schema.** Neutral — every port's generator reads it with a stdlib
  parser, so the format privileges no language (unlike a `.fbs` or a proc-macro).
  JSON has no comments → use `description` fields (they also become doc-comments
  in generated output).
- **u64 masks are hex strings.** JSON numbers are IEEE-754 doubles (safe only to
  2^53); masks like `0xff000000ffffffff` are stored as `"0x…"` strings and parsed
  to `u64` by the tooling.
- **Computed / platform values are stored resolved, per target.** `AlignSize =
  min(64, alignof(max_align_t))` becomes `targets.apple_arm64.align_size = 8`;
  ring totals become `{ "apple_arm64": 24832 }`. The conformance probe verifies
  the resolved values rather than the tooling re-deriving formulas.
- **C++ as a peer.** `dump_abi.cpp` *extracts* ground truth from C++ to validate
  the spec; it does not make C++ the source. Once generators exist, C++ is
  generated/checked like Rust, Swift and Zig.

## Generation

`tools/abi generate --lang <zig|rust|swift|cpp> [--target T] [--out P] [--check]`
emits a per-language constant module from `abi.json` (constants, enums, struct
sizes/field-offsets, and `abi_version`, resolved for `--target`). Each language's
idiom: Zig `pub const`, Rust `pub const` + `#[repr]` enums, Swift a caseless
`enum ABI` namespace, C++ `namespace thoth::abi` with `inline constexpr`. CI runs
`generate --lang <l> --check` for all four (staleness gate) and compiles the
generated Rust/C++ modules.

```sh
cargo run --manifest-path tools/abi/Cargo.toml -- generate --lang rust
```

**All four ports are migrated** — each generates its module into its own tree
and consumes it, so a mask/layout change in `abi.json` propagates by
regeneration. The generated file is named `abi_generated.*` in every port:

| port | generated module | consumed by |
|---|---|---|
| Zig | `zig/thoth-ipc/src/abi_generated.zig` | `layout.zig` / `channel_multi.zig` / `chunk.zig` re-export |
| Rust | `rust/thoth-ipc/src/abi_generated.rs` (`pub mod abi_generated`) | `channel.rs` constants + layout `const _` asserts |
| Swift | `swift/thoth-ipc/Sources/ThothIPC/Generated/abi_generated.swift` (`enum ABI`) | `Channel.swift` constants + `assertHeaderLayout()` |
| C++ | `cpp/thoth-ipc/include/thoth-ipc/abi_generated.hpp` (`namespace thoth::abi`) | `ipc.cpp` compile-time `static_assert` conformance layer |

**Rust/Swift/Zig re-source** their constants from the generated module (the value
literals live only in the module). **C++ is a *checked* peer**: it keeps
*deriving* its layout from the templates / `def.h` and `static_assert`s the
result against `thoth::abi`. This is deliberate — the semantic gate
(`dump_abi.cpp`) extracts ground truth *from* those same C++ derivations, so
re-sourcing them from the generated header would make that gate tautological. The
`static_assert`s make C++ conformance compile-time-enforced without collapsing
the independent gate. Both the compile-time asserts and the xlang matrix confirm
every port stays byte-exact.

## ABI versioning

`abi.json`'s `version` is the **ABI contract version** (semver), **decoupled from
the thoth-ipc release version** — the wire/shm format changes at a different
cadence than the software. It is surfaced in generated code as `abi_version`.

- **MAJOR** — incompatible wire/shm change; existing peers break. Two builds
  interoperate iff they share the same MAJOR.
- **MINOR** — backward-compatible addition (a new struct/constant); old peers
  still interoperate.
- **PATCH** — documentation/description only; no wire impact.

It currently sits at **1.0.0**: the format is byte-exact-stable (inherited from
cpp-ipc v1.4.1 and proven across four ports). This is the global contract version
*above* the per-subsystem wire versions already embedded at runtime (the
`SyncAbi` stamp's `1.0`, the SIPC envelope's `version: 1`).

## Status & next steps

**Done — the data + naming surface is statically gated, per-target:**

- **Coverage.** The semantic gate diffs **20** values against `abi.json` (transport
  ring/elem sizes, `rc_` masks, `msg_t`/`chunk_*`, `liveness_slot`, `ring_header`);
  everything else is a compile-time `static_assert` checked-peer. The enums
  (`codec_id`, `secure_alg`), the sync/secure constants (`syncabi_*`, `sipc_*`), and
  the sync sidecar suffixes are all generated and re-sourced by every port.
- **Per-target (align 8 vs 16).** Align-dependent values are per-target maps; the
  generator **deduplicates** (one constant when targets agree, `#[cfg]`/`#if`
  variants when they differ). The probe uses the runtime `AlignSize`, and the
  `abi-conformance` CI job gate-checks **both** targets on one Apple-Silicon runner
  (apple_arm64 native + x86_64 cross-compile under Rosetta), 20/20 each.
- **Naming.** Every `names[]` template has a per-target `golden`. The gate resolves
  the template, diffs the name **C++ actually builds** (`make_public_abi_prefix`,
  header-only), and independently recomputes the notify `fnv1a_64` in Rust — and
  C++ `static_assert`s the hash at compile time. (The wire-name namespace is
  `__THOTH_SHM__…` / `thoth.ntf.…`.)
- **Every port is a checked peer for shm names.** The `names[]` goldens are
  generated into each module, and Rust/Swift/Zig each carry a unit test asserting
  their name-builders equal the goldens for the canonical binding (Rust also
  extracted the previously-inlined builders into shared functions used by both
  `open()` and `clear_storage()`). C++ is covered by the dumper gate above.
- **POSIX name shortening is gated too.** `abi.json` carries `shm_name_max` per
  target (macOS 31, else 0) and a `posix_golden` for the (35-char) ring name. The
  checker reference-computes `make_shm_name` (`/<13 body>_<16-hex fnv1a>`) and
  diffs it; each port's test runs its own `make_shm_name` against the golden — so
  the shortening (`/__THOTH_SHM___7d090bf7fa85c547` on macOS) is verified per port,
  not just by the matrix.
- **`msg_t` field offsets are gated.** `msg_t` was a two-level template
  (`msg_t<0,A>` base + derived) inherited from cpp-ipc, which made it
  non-standard-layout (no `offsetof`). Since the base was never used on its own, it
  was **flattened** into one standard-layout struct — byte-identical (matrix
  confirms) — so every field offset (`cc_id`/`id`/`remain`/`storage`/`payload`) is
  now `offsetof`-`static_assert`ed against `thoth::abi`.

**Remaining**, roughly in priority order:

1. **`ring_header` field offsets.** The same story one level up: `elem_array`
   inherits `conn_head` and adds a member, so it is non-standard-layout and the
   header field offsets (`cc`/`lc`/`constructed`/`cursor`/`epoch`) stay matrix-only.
   Flattening `conn_head` in is a bigger change (it carries the connection-mgmt
   methods + DCLP init, not just data), so this is a considered refactor, not a
   quick win.
2. **Native x86_64 / Windows.** x86_64 is verified by Rosetta cross-compile today;
   a native Linux run would drop the emulation, and a Windows target entry would
   pin its object-namespace prefix.
