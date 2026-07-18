#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
# SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
#
# Polyglot pipeline launcher: one ipc::route hop per stage, one process per
# stage, a DIFFERENT language each. A single item flows
#
#     Zig source → [ppl_A] → Rust stage → [ppl_B] → Swift stage → [ppl_C] → C++ sink
#
# and the C++ sink prints the fully-transformed line, e.g.
#     item-0 [zig] -> rust -> swift -> [cpp sink]
# — one line showing every language the message crossed. The wire format is
# byte-exact across the ports, so this "just works".
#
# Usage:  ./run.sh [count]     (default 5)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)"
COUNT="${1:-5}"

CPP="$ROOT/cpp/libipc/build/bin/pipeline"
RUST="$ROOT/rust/libipc/target/release/demo_pipeline"
SWIFT="$ROOT/swift/libipc/.build/release/demo-pipeline"
ZIG="$ROOT/zig/libipc/zig-out/bin/demo_pipeline"

for b in "$CPP" "$RUST" "$SWIFT" "$ZIG"; do
  if [[ ! -x "$b" ]]; then
    cat >&2 <<EOF
missing binary: $b

Build the four pipeline demos first:
  (cd cpp/libipc  && cmake -B build -DLIBIPC_BUILD_DEMOS=ON . && cmake --build build --target pipeline -j)
  (cd rust/libipc && cargo build --release --bin demo_pipeline)
  (cd swift/libipc && swift build -c release --product demo-pipeline)
  (cd zig/libipc  && zig build -Doptimize=ReleaseSafe)
EOF
    exit 1
  fi
done

echo "polyglot pipeline (count=$COUNT):  zig ▶ rust ▶ swift ▶ cpp"
echo "  Zig source → [ppl_A] → Rust stage → [ppl_B] → Swift stage → [ppl_C] → C++ sink"
echo

# Start downstream-first so each producer finds its consumer within the
# 5-second wait_for_recv window. Stage/source status goes to stderr; the C++
# sink writes the transformed items to stdout.
"$CPP"   sink   ppl_C "$COUNT" cpp          &
sleep 0.3
"$SWIFT" stage  ppl_B ppl_C "$COUNT" swift  2>/dev/null &
sleep 0.3
"$RUST"  stage  ppl_A ppl_B "$COUNT" rust   2>/dev/null &
sleep 0.3
"$ZIG"   source ppl_A "$COUNT" zig          2>/dev/null &
wait
