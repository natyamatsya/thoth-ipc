# Handoff: native x86_64 ABI conformance (drop the Rosetta emulation)

- **Status:** **Not started — handoff.** Authored on macOS/arm64, which cannot run
  x86_64 without emulation, so the native run must be wired up (and ideally
  confirmed on bare-metal x86_64) by whoever picks this branch up.
- **Scope:** small — a CI job, **no code changes expected** (see "Why no code
  change" below).
- **Roadmap item:** the "Native x86_64 / Windows" entry in
  [`../abi/README.md`](../abi/README.md). This branch covers the x86_64 half;
  Windows is [`handoff-windows-abi-target.md`](handoff-windows-abi-target.md).

## Goal

Confirm the **align-16** ABI semantic gate (`abi/dump_abi.cpp` values diffed vs
`abi.json`'s `x86_64` target) on a **native x86_64** toolchain, dropping the
Rosetta cross-compile that stands in for it today.

## What already exists

- `.github/workflows/xlang.yml` → job **`abi-conformance`** (on `macos-latest`,
  Apple Silicon) checks two align classes:
  - `apple_arm64` natively (`cargo run -p abi -- check`), AlignSize 8.
  - `x86_64` by **cross-compiling** the dumper (`-arch x86_64`) and running it
    **under Rosetta** (`cargo run -p abi -- check --target x86_64`), AlignSize 16.
- The **behavioral** matrix already runs on native x86_64: job **`matrix-linux`**
  (`ubuntu-latest`, which is x86_64) runs the C++↔Rust xlang matrix. So x86_64
  *behavior* is native today; only the x86_64 *semantic dump gate* is Rosetta.

The gap is therefore narrow: run the **semantic dump gate** for align-16 on native
x86_64 silicon, so nothing about the align-16 layout rests on emulation.

## Why no code change is expected

`tools/abi` already does the right thing on a native x86_64 host:

- `host_target()` (`tools/abi/src/main.rs:178`) returns `"x86_64"` on any non
  apple-aarch64 host.
- The `-arch` cross-compile flag is added **only when `target != host_target()`**
  (`tools/abi/src/main.rs:228`). On a native x86_64 Linux host,
  `check --target x86_64` (or plain `check`) compiles `dump_abi.cpp` with the host
  `c++` **natively — no `-arch`, no Rosetta**.

So this is a CI-wiring task, not a tool change. (If you find the tool *does* need a
tweak on your host, that discovery belongs in this doc and the fix in `tools/abi`.)

## Implementation

Add an x86_64-native conformance job to `.github/workflows/xlang.yml`. GitHub's
`ubuntu-latest` runners are x86_64, so this runs native there:

```yaml
  # Native x86_64 ABI conformance: build + run the align-16 dumper on real x86_64
  # (no -arch / Rosetta), so the align-16 wire layout is confirmed without
  # emulation. Complements abi-conformance (macOS), which reaches x86_64 only via
  # Rosetta cross-compile.
  abi-conformance-x86_64-native:
    runs-on: ubuntu-latest        # x86_64 GitHub runner
    steps:
    - uses: actions/checkout@v4
      with:
        submodules: recursive
    - name: Install Rust toolchain
      uses: dtolnay/rust-toolchain@stable
    - name: Install GCC 14
      run: sudo apt-get update && sudo apt-get install -y g++-14
    - name: Check ABI conformance — x86_64 (native, align 16)
      run: cargo run --manifest-path tools/abi/Cargo.toml -- check --target x86_64
      env:
        CXX: g++-14
    - name: Check ABI conformance — host default (native, align 16)
      run: cargo run --manifest-path tools/abi/Cargo.toml -- check
      env:
        CXX: g++-14
```

Both invocations should build natively and report `0 mismatch(es)` for the 3
align-dependent values (`route_elem.size` 96, `route_ring.size` 24832,
`chunk_header_size` 16) plus the 17 align-independent ones.

## Optional: true bare-metal confirmation

`ubuntu-latest` runners are native x86_64, which satisfies "drop the emulation." If
you want confidence beyond a cloud VM (e.g. a specific libc / alignment concern),
run the same command on a physical x86_64 Linux box:

```sh
CXX=g++-14 cargo run -p abi -- check --target x86_64   # expect: 0 mismatches
```

## Acceptance criteria

- [ ] A native-x86_64 CI job builds `dump_abi.cpp` **without `-arch`/Rosetta** and
      the align-16 semantic gate reports 0 mismatches.
- [ ] The job is wired into `xlang.yml` (and green on a PR).
- [ ] If any `tools/abi` change was needed for the native host, it's committed and
      this doc updated to say so.
- [ ] `abi/README.md`: strike x86_64 from the "Native x86_64 / Windows" remaining
      item (leave Windows until its branch lands).

## Notes / gotchas

- Keep the existing macOS `abi-conformance` job — the Rosetta cross-check is still
  valuable as the *Apple-Silicon-side* proof that x86_64 layout is reproducible
  from an arm64 host. This job is additive.
- `matrix-linux` (behavioral) and this job (semantic) are complementary: one proves
  bytes round-trip between ports on x86_64, the other proves the C++ layout matches
  the single source of truth on x86_64.
