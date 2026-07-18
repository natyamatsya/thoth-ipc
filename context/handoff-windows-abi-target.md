# Handoff: Windows ABI target — pin the `Local\` object-namespace prefix as a golden

- **Status:** **Not started — handoff.** Authored on macOS/arm64. The naming and
  layout below **must be validated on Windows/MSVC** (the object names a running
  process actually creates), so complete this on a Windows box.
- **Scope:** medium — a new `abi.json` target + a per-target object-namespace
  prefix threaded through the naming gate + generator, then re-sourced by the
  Windows ports. **Not** a behavioral change: Windows C++↔Rust already works.
- **Roadmap item:** the "Native x86_64 / Windows" entry in
  [`../abi/README.md`](../abi/README.md). This branch covers the Windows half;
  x86_64 is [`handoff-native-x86_64-abi.md`](handoff-native-x86_64-abi.md).
- **Relates to:** [`windows-parity-rfc.md`](windows-parity-rfc.md) (implemented +
  validated on Windows 2026-07-12),
  [`xlang-channel-abi.md`](xlang-channel-abi.md) §1 (names).

## Goal

Add a `windows` (windows-msvc x64) target to the ABI single source of truth so the
**Windows object-namespace prefix (`Local\`)** — and the Windows-resolved align
class — are **pinned as checked goldens**, not merely matrix-verified. Today
`abi.json` has only `apple_arm64` and `x86_64`; Windows naming rests entirely on the
behavioral `matrix-windows` job.

## What already exists (do not redo)

- Windows C++↔Rust parity is **implemented and validated on Windows**
  (`windows-parity-rfc.md`): sync 16/16, reap 8/8, async 36/36 green on
  `windows-latest`/MSVC. The ports create the right object names *today*; this task
  only lifts that contract into `abi.json` as a golden.
- `matrix-windows` / `async-matrix-windows` in `.github/workflows/xlang.yml` run the
  behavioral matrix on MSVC.

## Two Windows-specific facts (get these right)

1. **AlignSize is `8` on windows-msvc x64, NOT 16.** MSVC `alignof(max_align_t)==8`
   (vs 16 on Linux/macOS x86-64) — see `windows-parity-rfc.md` §"Corrections",
   point 2. So Windows resolves the **same align class as `apple_arm64`**: the ring
   name is `…__QU_CONN__xchan__64__8`, `route_elem.size` 88, `route_ring.size`
   22784, `chunk_header_size` 8. The `windows` target will therefore **dedup with
   `apple_arm64`** for every align-dependent value in the generator. The one thing
   that is genuinely Windows-only is the object-namespace prefix.
2. **The `Local\` prefix is an OS-handle-layer prefix, like POSIX `/`.** The
   `names[]` `{prefix}` field is the *user channel prefix* (default `""`), applied
   to the **logical** object name. `Local\` is prepended separately when the name
   becomes a Win32 kernel object (`CreateFileMapping`/`CreateEvent`), exactly as
   `make_shm_name` prepends `/` on POSIX and records it in `posix_golden`. So the
   Windows name gets its own golden analog (a `win_golden`), not a change to
   `{prefix}`.

## Implementation

### 1. `abi/abi.schema.json`

- Extend the `targets.*` object schema (currently `align_size` + `shm_name_max`,
  around line 22–26) with an optional object-namespace prefix, e.g.:
  ```json
  "obj_ns_prefix": { "type": "string",
    "description": "OS-handle-layer object-namespace prefix prepended when the logical name becomes a kernel object (Win32 \"Local\\\\\"; \"\" on POSIX, which uses make_shm_name's leading '/' instead)." }
  ```
- Add an optional `win_golden` to the `names[]` item schema (sibling of
  `posix_golden`, ~line 132): the expected OS object name on Windows =
  `obj_ns_prefix + <logical golden>` (with the Win32 length rule applied — see
  step 3). Per-target string.

### 2. `abi/abi.json`

- Add the target (note `align_size: 8`, and JSON needs the backslash escaped):
  ```json
  "windows": { "align_size": 8, "shm_name_max": 0, "obj_ns_prefix": "Local\\",
    "description": "windows-msvc x64 — MSVC alignof(max_align_t)=8 (same align class as apple_arm64); kernel objects live in the session-local BNO namespace (Local\\). No POSIX shortening." }
  ```
  Leave `apple_arm64`/`x86_64` with `obj_ns_prefix: ""` (POSIX uses `/` via
  `make_shm_name`, already covered by `posix_golden`).
- For each `names[]` entry, add the `windows` key to `golden`/`posix_golden` where
  they are per-target, and add `win_golden`. Because Windows == apple's align class,
  the **logical** goldens equal the `apple_arm64` ones; only the prefix differs. E.g.
  for `ring`:
  ```
  golden.windows     = "__THOTH_SHM__QU_CONN__xchan__64__8"          (== apple_arm64)
  win_golden.ring    = "Local\\__THOTH_SHM__QU_CONN__xchan__64__8"
  ```
  Confirm the Win32 max object-name length (≈ MAX_PATH 260, minus the `Local\`
  namespace) — the ring name is short, so no truncation is expected, but pin the
  rule so an over-long name can't silently pass.

### 3. `tools/abi/src/main.rs`

- Resolve `obj_ns_prefix` per target (like `align_size`/`shm_name_max`,
  `~main.rs:99`).
- Add a `make_win_name(name, obj_ns_prefix, max_len)` reference alongside
  `make_shm_name` (`~main.rs:79`): prepend the prefix verbatim; **no FNV shortening**
  (that is a POSIX-only device). Apply the Win32 length rule you settled in step 2.
- In the naming gate, when a target has a non-empty `obj_ns_prefix`, reference-check
  `win_golden == make_win_name(logical_golden, obj_ns_prefix, …)` and diff it, the
  same way `posix_golden` is checked for POSIX targets.
- Emit the pinned prefix into the generated modules (a `obj_ns_prefix` /
  `name_golden_ring_win` constant) so the ports can re-source it instead of
  hard-coding `Local\`.

### 4. Ports re-source the prefix

Replace the hard-coded `Local\` in the Windows shm/event name builders with the
generated constant, and add a golden assertion (mirroring the existing per-port
`name_golden_*` tests) that the built OS object name equals `win_golden`. Windows
touches the C++ `win/` platform layer and the Rust `windows` module. (Swift is a
macOS-only SwiftPM package — out of scope, as in the RFC.)

### 5. Regenerate + gates

```sh
for l in zig rust swift cpp; do cargo run -p abi -- generate --lang "$l"; done
cargo run -p abi -- check                     # structural + semantic gate
for l in zig rust swift cpp; do cargo run -p abi -- generate --lang "$l" --check; done  # staleness 4/4
```

## Validation (must run on Windows/MSVC)

- `matrix-windows` + `async-matrix-windows` stay green (no behavioral regression).
- The new per-port golden test asserts the **actual created** object name equals
  `win_golden` (`Local\__THOTH_SHM__QU_CONN__xchan__64__8`). Verify against a real
  handle (e.g. log the name passed to `CreateFileMapping`), not just the builder —
  the point of this item is to catch a divergence the matrix would miss.

## Acceptance criteria

- [ ] `windows` target in `abi.json` (align 8, `obj_ns_prefix: "Local\\"`),
      schema updated, structural gate passes.
- [ ] `win_golden`s pin the `Local\`-prefixed OS object names; the naming gate
      reference-computes and diffs them.
- [ ] C++ `win/` and Rust `windows` re-source the prefix from the generated module;
      per-port golden tests assert the real object name matches `win_golden`.
- [ ] All four `abi_generated.*` regenerated; staleness 4/4; `abi -- check` green.
- [ ] `matrix-windows` green on a PR.
- [ ] `abi/README.md`: strike Windows from the "Native x86_64 / Windows" remaining
      item (the x86_64 half is a separate branch).

## Gotchas

- **Escaping:** `Local\` is `"Local\\"` in JSON, and `"Local\\\\"` inside a schema
  `description` string. Double-check the generated ports emit a single backslash.
- **Dedup surprise:** because Windows shares apple's align class, most `windows`
  values will *not* produce a distinct `#if`/`#cfg` branch in the generated modules
  — only the object-namespace prefix is Windows-distinct. That is expected; don't
  force per-target branches for values that are identical.
- **Don't touch `{prefix}`:** the logical-name channel prefix and the OS-namespace
  prefix are different layers. Keep them separate (mirrors POSIX `/` living in
  `make_shm_name`/`posix_golden`, not in the template).
