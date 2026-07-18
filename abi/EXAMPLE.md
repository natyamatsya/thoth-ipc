<!-- SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors -->

# The ABI as a single source of truth — a walkthrough

thoth-ipc's four ports (C++, Rust, Swift, Zig) must agree **byte-for-byte** on a
large surface of constants and layouts. When each port hand-maintains those
numbers, a value fixed in one port but not another is silent, cross-language
drift — the exact failure the project exists to prevent.

[`abi/abi.json`](abi.json) is the fix: **one machine-readable spec** the ports
are generated from and checked against. This page walks a single constant
through the whole pipeline and shows the gates catching a deliberate mistake.
For the *design rationale* (why JSON, why C++ is a "checked peer", ABI
versioning), see [`abi/README.md`](README.md); this page is the hands-on tour.

> A real bug this pipeline caught: `syncabi_magic` was once `1279613249`
> (`0x4C455941`, "LEYA") — a decimal typo contradicting its own `0x4C495341`
> ("LISA") description. It was harmless only because no port *consumed* the
> generated value yet; the moment they did, all four would have written the wrong
> magic. The C++ compile-time check below is what surfaced it.

---

## 1. One spec → four ports

A constant is one line in [`abi.json`](abi.json):

```json
{ "name": "data_length", "type": "usize", "value": 64,
  "description": "msg_t payload fragment size (large_msg_limit)" }
```

`tools/abi` generates a per-language module from it. The *same* value lands in
every port, in each language's idiom:

```
rust   pub const data_length: usize = 64;                    // rust/thoth-ipc/src/abi_generated.rs
swift  public static let data_length: Int = 64               // swift/…/Generated/abi_generated.swift
zig    pub const data_length: usize = 64;                    // zig/thoth-ipc/src/abi_generated.zig
cpp    inline constexpr std::size_t data_length = 64;        // cpp/…/include/libipc/abi_generated.hpp
```

Each port then re-exports its own hand-named constant from the generated module
(Rust/Swift/Zig), or `static_assert`s its template-derived layout against it
(C++ — see §3). A change to `abi.json` reaches every port by **regeneration**,
not by hand-editing four files.

To (re)generate a module:

```sh
cargo run --manifest-path tools/abi/Cargo.toml -- generate --lang rust   # or swift | zig | cpp
```

---

## 2. Four gates keep the spec honest

Running the checker with no arguments runs the two static gates and reports
coverage:

```sh
$ cargo run --manifest-path tools/abi/Cargo.toml
✓ structural: abi.json valid against abi.schema.json
✓ semantic: 15 value(s) match the deployed C++, 0 mismatch(es)
  (10 not yet C++-dumped, matrix-verified only: chunk_header_size, chunk_info_size, …)
✓ ABI conformance OK
```

1. **Structural** — `abi.json` is validated against
   [`abi.schema.json`](abi.schema.json) (JSON Schema): fields, types, the semver
   `version` pattern, u64 masks as hex strings.
2. **Semantic** — the checker compiles + runs [`dump_abi.cpp`](dump_abi.cpp),
   which emits the values the canonical C++ *actually compiles to*
   (`sizeof`/masks/`def.h` constants), and diffs them against `abi.json`. The
   spec can never silently diverge from the deployed C++.
3. **Staleness** — every generated module must be byte-current with `abi.json`
   (CI runs `generate --lang <l> --check` for all four):

   ```sh
   $ for l in zig rust swift cpp; do \
       cargo run --manifest-path tools/abi/Cargo.toml -- generate --lang $l --check; done
   ✓ zig/thoth-ipc/src/abi_generated.zig is up to date with abi.json
   ✓ rust/thoth-ipc/src/abi_generated.rs is up to date with abi.json
   ✓ swift/thoth-ipc/Sources/LibIPC/Generated/abi_generated.swift is up to date with abi.json
   ✓ cpp/thoth-ipc/include/thoth-ipc/abi_generated.hpp is up to date with abi.json
   ```

4. **Behavioural** — the [xlang matrix](../tools/xlang-runner) proves the
   *protocols* interoperate end to end. An IDL owns data, not lock-free
   algorithms; those stay hand-written per language and are verified here.

Plus a compile-time gate: **C++ is a checked peer.** `ipc.cpp` keeps *deriving*
its layout from its own templates and `static_assert`s the result against the
generated `ipc::abi`, so the derivations stay independent of the spec (that is
why the `dump_abi.cpp` gate above is non-vacuous):

```cpp
static_assert(ipc::data_length == ipc::abi::data_length, "abi drift: data_length");
static_assert(sizeof(AbiRouteP::elem_t<80, 8>) == ipc::abi::route_elem_size, "abi drift: route_elem.size");
```

---

## 3. Watch the gates catch a mistake

Break `data_length` on purpose — change its `value` in `abi.json` from `64` to
`128` — and re-run the checker. The **semantic** gate diffs the spec against what
C++ compiles to and rejects it:

```sh
$ cargo run --manifest-path tools/abi/Cargo.toml
✓ structural: abi.json valid against abi.schema.json
  ✗ data_length: abi.json = 0x80 (128) but C++ = 0x40 (64)
✓ semantic: 14 value(s) match the deployed C++, 1 mismatch(es)
```

Break the **structure** instead — set `version` to `"LEYA-not-semver"` — and the
schema gate rejects it before any semantics are even checked:

```sh
$ cargo run --manifest-path tools/abi/Cargo.toml
✗ abi.json failed schema validation:
    "LEYA-not-semver" does not match "^[0-9]+\.[0-9]+\.[0-9]+$" (at /version)
```

And if a wrong value ever slips past the dumper's coverage (as the
`syncabi_magic` typo did — it was in the "matrix-verified only" list), the C++
`static_assert` catches it at **compile time**: regenerate the C++ header with
the bad value, rebuild, and the build fails with `static_assert failed: "abi
drift: <name>"`. That compile error is exactly how the "LEYA" typo was found.

---

## 4. Try it yourself

```sh
# 1. See the two static gates pass (needs Rust + a C++20 compiler):
cargo run --manifest-path tools/abi/Cargo.toml

# 2. Trace one constant into all four ports:
grep data_length \
  rust/thoth-ipc/src/abi_generated.rs \
  swift/thoth-ipc/Sources/LibIPC/Generated/abi_generated.swift \
  zig/thoth-ipc/src/abi_generated.zig \
  cpp/thoth-ipc/include/thoth-ipc/abi_generated.hpp

# 3. Break a value and watch a gate reject it, then restore:
cp abi/abi.json /tmp/abi.bak
sed -i '' 's/"value": 64,   "description": "msg_t payload/"value": 128,  "description": "msg_t payload/' abi/abi.json
cargo run --manifest-path tools/abi/Cargo.toml   # ✗ data_length mismatch
cp /tmp/abi.bak abi/abi.json                     # restore

# 4. Regenerate a port module from the spec:
cargo run --manifest-path tools/abi/Cargo.toml -- generate --lang rust
```

The point: a wire/shm constant is edited in **one** place, flows to **four**
ports by regeneration, and any drift — spec vs C++, generated vs spec, or
protocol vs protocol — is caught by a gate before it ships.
