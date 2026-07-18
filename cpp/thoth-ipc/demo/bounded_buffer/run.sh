#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
# SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
#
# Cross-language bounded buffer launcher. A Swift consumer drains a small shared
# ring fed by four producers — one C++, one Rust, one Zig, one Swift — all
# synchronising through a byte-exact named mutex + two counting semaphores
# (empty/full). The 4-slot ring forces the semaphores to actually block, so this
# exercises real cross-language producer/consumer coordination.
#
# Usage:  ./run.sh [per_producer_count]   (default 4)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)"
N="${1:-4}"
TOTAL=$((N * 4))

CPP="$ROOT/cpp/thoth-ipc/build/bin/bounded_buffer"
RUST="$ROOT/rust/thoth-ipc/target/release/demo_bounded_buffer"
SWIFT="$ROOT/swift/thoth-ipc/.build/release/demo-bounded-buffer"
ZIG="$ROOT/zig/thoth-ipc/zig-out/bin/demo_bounded_buffer"

for b in "$CPP" "$RUST" "$SWIFT" "$ZIG"; do
  if [[ ! -x "$b" ]]; then
    cat >&2 <<EOF
missing binary: $b

Build the four bounded-buffer demos first:
  (cd cpp/thoth-ipc  && cmake -B build -DLIBIPC_BUILD_DEMOS=ON . && cmake --build build --target bounded_buffer -j)
  (cd rust/thoth-ipc && cargo build --release --bin demo_bounded_buffer)
  (cd swift/thoth-ipc && swift build -c release --product demo-bounded-buffer)
  (cd zig/thoth-ipc  && zig build -Doptimize=ReleaseSafe)
EOF
    exit 1
  fi
done

echo "bounded buffer:  Swift consumer ← {cpp, rust, zig, swift} producers × $N  (4-slot ring)"
echo

# Consumer first so the ring + primitives are initialised, then the producers.
"$SWIFT" consume "$TOTAL"          &
sleep 0.4
"$CPP"   produce cpp   "$N" 2>/dev/null &
"$RUST"  produce rust  "$N" 2>/dev/null &
"$ZIG"   produce zig   "$N" 2>/dev/null &
"$SWIFT" produce swift "$N" 2>/dev/null &
wait
