#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
# SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
#
# Polyglot pipeline launcher: one thoth::route hop per stage, one process per
# stage, a DIFFERENT language each. With all four ports built, a single item flows
#
#     Zig source → [ppl_A] → Rust stage → [ppl_B] → Swift stage → [ppl_C] → C++ sink
#
# and the C++ sink prints the fully-transformed line, e.g.
#     item-0 [zig] -> rust -> swift -> [cpp sink]
# — one line showing every language the message crossed. The wire format is
# byte-exact across the ports, so this "just works".
#
# The chain uses whichever ports are built (at least two), in the order above:
# without Swift it is Zig source → Rust stage → C++ sink.
# For every mix of languages in every role, run the demo matrix instead:
#   tools/xlang-runner's demo-runner --demo pipeline (see tools/demos.toml).
#
# Usage:  ./run.sh [count]     (default 5)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)"
COUNT="${1:-5}"

LANGS=(zig rust swift cpp)
declare -A BIN=(
  [zig]="$ROOT/zig/thoth-ipc/zig-out/bin/demo_pipeline"
  [rust]="$ROOT/rust/thoth-ipc/target/release/demo_pipeline"
  [swift]="$ROOT/swift/thoth-ipc/.build/release/demo-pipeline"
  [cpp]="$ROOT/cpp/thoth-ipc/build/bin/pipeline"
)
declare -A BUILD=(
  [zig]="(cd zig/thoth-ipc  && zig build -Doptimize=ReleaseSafe)"
  [rust]="(cd rust/thoth-ipc && cargo build --release --bin demo_pipeline)"
  [swift]="(cd swift/thoth-ipc && swift build -c release --product demo-pipeline)"
  [cpp]="(cd cpp/thoth-ipc  && cmake -B build -DTHOTH_IPC_BUILD_DEMOS=ON . && cmake --build build --target pipeline -j)"
)

chain=()
for lang in "${LANGS[@]}"; do
  if [[ -x "${BIN[$lang]}" ]]; then
    chain+=("$lang")
  else
    echo "note: no $lang pipeline (${BIN[$lang]}); build it with ${BUILD[$lang]}" >&2
  fi
done
if (( ${#chain[@]} < 2 )); then
  echo "need at least two built ports for a pipeline" >&2
  exit 1
fi

last=$(( ${#chain[@]} - 1 ))
hop() { printf 'ppl_%s' "$(printf "\\$(printf '%03o' $((65 + $1)))")"; } # 0 -> ppl_A
label=""
for i in "${!chain[@]}"; do
  role=stage; (( i == 0 )) && role=source; (( i == last )) && role=sink
  label+="${chain[$i]} $role"; (( i < last )) && label+=" → [$(hop "$i")] → "
done
echo "polyglot pipeline (count=$COUNT):  ${chain[*]}"
echo "  $label"
echo

# Start downstream-first so each producer finds its consumer within the
# 5-second wait_for_recv window. Stage/source status goes to stderr; the sink
# writes the transformed items to stdout.
"${BIN[${chain[$last]}]}" sink "$(hop $((last - 1)))" "$COUNT" "${chain[$last]}" &
for (( i = last - 1; i >= 1; i-- )); do
  sleep 0.3
  "${BIN[${chain[$i]}]}" stage "$(hop $((i - 1)))" "$(hop "$i")" "$COUNT" "${chain[$i]}" 2>/dev/null &
done
sleep 0.3
"${BIN[${chain[0]}]}" source "$(hop 0)" "$COUNT" "${chain[0]}" 2>/dev/null &
wait
