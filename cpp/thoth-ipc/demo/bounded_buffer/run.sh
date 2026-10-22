#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
# SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
#
# Cross-language bounded buffer launcher. One consumer drains a small shared
# ring fed by one producer per built port — C++, Rust, Zig and Swift —
# all synchronising through a byte-exact named mutex + two counting semaphores
# (empty/full). The 4-slot ring forces the semaphores to actually block, so this
# exercises real cross-language producer/consumer coordination.
#
# The consumer is Swift when it is built, else the first of C++, Rust,
# Zig. For every language as the consumer, run the demo matrix instead:
#   tools/xlang-runner's demo-runner --demo bounded_buffer (see tools/demos.toml).
#
# Usage:  ./run.sh [per_producer_count]   (default 4)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)"
N="${1:-4}"

LANGS=(swift cpp rust zig)
declare -A BIN=(
  [swift]="$ROOT/swift/thoth-ipc/.build/release/demo-bounded-buffer"
  [cpp]="$ROOT/cpp/thoth-ipc/build/bin/bounded_buffer"
  [rust]="$ROOT/rust/thoth-ipc/target/release/demo_bounded_buffer"
  [zig]="$ROOT/zig/thoth-ipc/zig-out/bin/demo_bounded_buffer"
)
declare -A BUILD=(
  [swift]="(cd swift/thoth-ipc && swift build -c release --product demo-bounded-buffer)"
  [cpp]="(cd cpp/thoth-ipc  && cmake -B build -DTHOTH_IPC_BUILD_DEMOS=ON . && cmake --build build --target bounded_buffer -j)"
  [rust]="(cd rust/thoth-ipc && cargo build --release --bin demo_bounded_buffer)"
  [zig]="(cd zig/thoth-ipc  && zig build -Doptimize=ReleaseSafe)"
)

langs=()
for lang in "${LANGS[@]}"; do
  if [[ -x "${BIN[$lang]}" ]]; then
    langs+=("$lang")
  else
    echo "note: no $lang bounded buffer (${BIN[$lang]}); build it with ${BUILD[$lang]}" >&2
  fi
done
if (( ${#langs[@]} == 0 )); then
  echo "no bounded-buffer demo is built" >&2
  exit 1
fi
consumer="${langs[0]}"
TOTAL=$(( N * ${#langs[@]} ))

echo "bounded buffer:  ${consumer} consumer ← {${langs[*]}} producers × $N  (4-slot ring)"
echo

# Start from a clean ring and semaphores (an aborted run leaves counts behind),
# then the consumer, so the ring + primitives are initialised, then the producers.
"${BIN[$consumer]}" clear
"${BIN[$consumer]}" consume "$TOTAL" &
sleep 0.4
for lang in "${langs[@]}"; do
  "${BIN[$lang]}" produce "$lang" "$N" 2>/dev/null &
done
wait
