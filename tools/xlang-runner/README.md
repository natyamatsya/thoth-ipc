# xlang-runner — cross-language ABI test framework

thoth-ipc's C++, Rust and Swift ports share one byte-exact wire ABI
([`context/xlang-channel-abi.md`](../../context/xlang-channel-abi.md)), joined by
a native Zig port covering the transport, reaper, sync primitives, typed codec
and secure envelope (every scenario except `async`).
Same-language test suites cannot catch ABI drift; this runner proves parity by
pairing every writer language with every reader language over a real
`ipc::route` channel.

It supersedes `tools/xlang_matrix.py` with the same architecture — one harness
binary per language, a uniform CLI — but a real framework around it:

- **Declarative config** ([`tools/xlang-ci.toml`](../xlang-ci.toml)): one file
  serves every OS/CI job. Binary paths reference environment variables; a
  language whose variable is unset simply isn't present on that host.
- **Capability negotiation**: harnesses report features via their `caps` verb
  (`notify async secure secure:aes256gcm ...`). Scenarios skip (or, with
  `--strict-caps`, fail fast on) harnesses lacking a required capability
  instead of hanging into a timeout.
- **Parallel execution**: every case runs on its own uniquely named channel, so
  cases are independent and run on `[run].jobs` workers.
- **Structured reporting**: console progress plus `--junit` XML and `--json`
  for CI annotation and trend tooling. `--retries N` marks flaky-passes
  distinctly rather than hiding them.

## Scenarios

| scenario          | proves                                                                     | verbs                        |
|-------------------|-----------------------------------------------------------------------------|------------------------------|
| `sync`            | blocking round-trip, byte-for-byte, incl. 63/64/65 boundary + 64KB payloads | `write` / `read`             |
| `async`           | a writer's notify wakes an async (readiness-driven) receiver                | `write` / `aread`            |
| `fanout`          | 1 writer → N mixed-language readers: every receiver gets every message (rc_ bitmask with N>1) | `write minrecv=N` / `read` |
| `channel`         | multi-writer `ipc::channel` (2 writers of different languages → 1 reader)  | `cwrite` / `cread`           |
| `reap`            | dead receivers reclaimed, live never falsely; sender `probe` doesn't reap; traffic flows after a reap | `hold` / `count` / `probe` |
| `primitives`      | mutex contention + robust dead-holder recovery, semaphore count exactness, condition wakeup | `mhold`/`mtry`/`mlock`, `spost`/`swait`, `cvnotify`/`cvwait` |
| `typed`           | the typed codec layer end-to-end (canonical protobuf message, field-level verify) | `twrite` / `tread`      |
| `secure`          | AEAD envelope v1 interop: sealed by one language, opened by another         | `swrite` / `sread`           |
| `secure-badkey`   | fail-closed: a reader keyed with different material rejects every message   | `swrite` / `sread-badkey`    |
| `secure-negative` | fail-closed on tampered tags, wrong key ids, and algorithm mismatch         | `swrite-tamper` / `sread-reject` / `sread-badkeyid` |

The secure scenarios run per algorithm (`aes256gcm`, `chacha20poly1305`) with
the shared xlang test key that is byte-identical in all three harnesses. They
exercise the real `SecureCodec` code path (SIPC envelope framing + OpenSSL EVP
AEAD via the `secure-crypto-c` C ABI) over a raw identity inner codec, so a
pairing failure isolates envelope/AEAD divergence, not codec-library noise.

## Known gaps (expected-fail)

Cases matching `[run].xfail` entries in the config — plus the whole `channel`
scenario (`[scenarios.channel].xfail`) — run as **expected-fail**: they are
reported in every run, don't fail the build, and are flagged `XPASS` when they
unexpectedly pass so the expectation gets flipped. Current entries document
gaps this matrix discovered:

- **`channel`**: cross-language `ipc::channel` was never ABI-compatible — the
  C++ multi-producer broadcast queue uses 96-byte slots with an `f_ct_` commit
  flag and a commit-index protocol (`prod_cons.h`, multi-multi-broadcast),
  while the Rust/Swift `Channel` reuses the 88-byte route layout; port senders
  also draw message ids from a process-local counter instead of the shared
  `AC_CONN` counter (ABI §6a), so even port↔port multi-writer reassembly
  collides.
- **`primitives` semaphore cpp↔ports**: the C++ and port semaphores don't
  interop in either direction (different backing objects).
- **`primitives` mutex with a Rust holder**: probers of every language can
  acquire a mutex a live Rust process holds (suspected shm re-init of live
  state; flaky even Rust↔Rust).
- **`async` at ≥16KB** (size-capped rather than xfailed): above ring capacity
  (256 slots × 64B) a fragmenting sender posts the Layer-1 notify only after
  *all* fragments, so the message deadlocks against a parked async receiver;
  and at exactly 16384B the C++ async receiver (`xasync`) intermittently
  reassembles a Swift sender's fragments short. Async sizes stay ≤3000B until
  both are fixed.

## Running locally (macOS example)

```sh
# Build the harnesses with the secure backend:
(cd cpp/libipc && cmake -B build -DCMAKE_BUILD_TYPE=Release -DLIBIPC_BUILD_TESTS=ON \
    -DLIBIPC_SECURE_OPENSSL=ON -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" . \
    && cmake --build build --target xlang_ipc -j)
(cd rust/libipc && cargo build --release --bin xlang --features secure-crypto-openssl,async-tokio)
(cd swift/libipc && LIBIPC_SECURE_OPENSSL=1 swift build -c release --product xlang-harness)

# Point the config's env vars at them and run (from the repo root):
export XLANG_CPP_BIN=cpp/libipc/build/bin/xlang_ipc
export XLANG_RUST_BIN=rust/libipc/target/release/xlang
export XLANG_SWIFT_BIN="$(cd swift/libipc && swift build -c release --product xlang-harness --show-bin-path)/xlang-harness"
export XLANG_RUST_ASYNC_BIN=$XLANG_RUST_BIN XLANG_SWIFT_ASYNC_BIN=$XLANG_SWIFT_BIN
cargo run --release --manifest-path tools/xlang-runner/Cargo.toml -- --config tools/xlang-ci.toml
```

Useful flags: `--list` (plan only), `--scenario secure,secure-badkey` (filter),
`--jobs 1` (serialize), `--require cpp,rust --strict-caps` (CI guard against
silent skips). Exit codes: 0 all passed, 1 case failures, 2 config/planning
error.

## Adding a language

1. Implement the harness CLI in the new language (see
   `rust/libipc/src/bin/xlang.rs` for the reference contract):
   `write/read/clear` at minimum, `caps` recommended, plus the verbs of any
   scenario it should join.
2. Add a `[languages.<name>]` entry to `tools/xlang-ci.toml` with its `bin`
   env var and `modes`.
3. Export the env var in the CI jobs that build it. Done — every pairing with
   every existing language is planned automatically.

## Adding a scenario

Scenarios live in `src/cases.rs` (planning: which verbs, which caps, which
matrix axes) and, if they need a new orchestration shape beyond
reader/writer or holder/reaper, `src/exec.rs`. Most new scenarios are a new
verb pair plus a `participants(...)` loop — the secure scenario is the
template to copy.
