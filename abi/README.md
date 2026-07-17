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
| [`generated/`](generated/) | generated Rust / Swift / C++ modules (`abi.{rs,swift,hpp}`), not yet consumed by their ports |

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
`enum ABI` namespace, C++ `namespace ipc::abi` with `inline constexpr`. CI runs
`generate --lang <l> --check` for all four (staleness gate) and compiles the
generated Rust/C++ modules.

```sh
cargo run --manifest-path tools/abi/Cargo.toml -- generate --lang rust
```

**Zig, Rust and Swift are migrated** — each consumes its generated module,
so the rest of the port keeps its public const names and a spec change
propagates by regeneration:

| port | generated module | consumed by |
|---|---|---|
| Zig | `zig/libipc/src/abi_generated.zig` | `layout.zig` / `channel_multi.zig` / `chunk.zig` re-export |
| Rust | `rust/libipc/src/abi_generated.rs` (`pub mod abi_generated`) | `channel.rs` constants + layout `const _` asserts |
| Swift | `swift/libipc/Sources/LibIPC/Generated/ABI.swift` (`enum ABI`) | `Channel.swift` constants + `assertHeaderLayout()` |

Both the compile-time layout asserts (struct sizes/offsets checked against the
generated values) and the xlang matrix confirm each stays byte-exact.

**C++** still emits the reference copy to [`abi/generated/abi.hpp`](generated/) —
committed, compile-checked and staleness-gated, but **not yet consumed**. It is
the one remaining hand-source, and a subtle one: the semantic gate
(`dump_abi.cpp`) extracts ground truth *from* C++, so having C++ re-source the
dumper-checked surface from the generated header would make that gate
tautological. Migrating C++ therefore means compile-time `static_assert`s of its
template-derived layout against `ipc::abi` (keeping the derivations independent),
not a blind re-source — see Next steps.

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

## Next steps

1. **Migrate C++** to `static_assert` its `elem_array` / `msg_t` / header layout
   against the generated `ipc::abi` (a compile-time conformance layer that keeps
   the template-derived, per-target values independent, so the `dump_abi.cpp`
   gate stays non-vacuous). This makes C++ a *checked* peer without collapsing
   the semantic gate. Matrix-verified, like Rust/Swift/Zig.
2. Extend the migrated ports beyond the transport core to the sync/secure
   surface (`syncabi_*`, `sipc_*`, codec/alg enums, `liveness_slot_*`), which
   still lives hand-written in `sync_abi` / secure modules.
3. Grow `abi.json` + dumper coverage (`msg_t` offsets via a small introspection
   shim, SIPC / SyncAbi framing, naming-template checks).
