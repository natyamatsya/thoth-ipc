#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
#
# Cross-language round-trip matrix driver.
#
# thoth-ipc's C++, Rust and Swift ports share one byte-exact wire ABI
# (context/xlang-channel-abi.md). This driver proves it by running every
# (writer-language x reader-language) pairing over an ipc::route channel and
# checking that the reader receives exactly the messages the writer sent —
# byte-for-byte — across a range of payload sizes that exercise the
# single-fragment, multi-fragment and chunk-storage paths.
#
# Each language ships one harness binary with a uniform CLI:
#   <bin> write <name> <count> <size>   send <count> pattern messages
#   <bin> read  <name> <count> <size>   recv+verify; exit 0 iff all match
#   <bin> clear <name>                  unlink the channel's shm segments
# Payload pattern: byte[i] = 'A' + (i % 26).
#
# Usage:
#   xlang_matrix.py --lang cpp:/path/to/xlang_ipc \
#                   --lang rust:/path/to/xlang \
#                   --lang swift:/path/to/xlang-harness
# Any subset of languages may be given; the matrix covers all provided pairs.
# Exit code is non-zero if any pairing fails.

import argparse
import os
import subprocess
import sys
import time

# Payload sizes (bytes) and why each matters on the ipc::route wire:
#   40    <= data_length (64): a single msg_t fragment.
#   65    just over 64: C++ sender uses chunk storage; ports fragment (2 msg_t).
#   200   chunk storage (C++ sender); multi-fragment for port senders.
#   3000  large chunk storage / many fragments.
SIZES = [40, 65, 200, 3000]
COUNT = 5
# How long to give a pairing before declaring it hung (writer wait_for_recv is
# 5s; reader recv timeout is 8s per message).
PAIR_TIMEOUT = 30


def run(bin_path, verb, name, count=None, size=None, timeout=PAIR_TIMEOUT):
    cmd = [bin_path, verb, name]
    if count is not None:
        cmd += [str(count), str(size)]
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def clear(bin_path, name):
    try:
        subprocess.run([bin_path, "clear", name], timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def run_pair(w_lang, w_bin, r_lang, r_bin, size, idx, read_verb="read"):
    """Start the reader, then the writer; return (ok, detail)."""
    name = f"xm_{w_lang}_{r_lang}_{size}_{os.getpid()}_{idx}"
    # Clear any stale segment from a previous run using both endpoints' clearers.
    clear(r_bin, name)
    clear(w_bin, name)

    reader = run(r_bin, read_verb, name, COUNT, size)
    # Give the reader a moment to create the ring and register as a receiver.
    time.sleep(0.4)
    writer = run(w_bin, "write", name, COUNT, size)

    detail = ""
    try:
        w_rc = writer.wait(timeout=PAIR_TIMEOUT)
    except subprocess.TimeoutExpired:
        writer.kill(); w_rc = -1; detail += "writer-timeout "
    try:
        r_rc = reader.wait(timeout=PAIR_TIMEOUT)
    except subprocess.TimeoutExpired:
        reader.kill(); r_rc = -1; detail += "reader-timeout "

    ok = (w_rc == 0 and r_rc == 0)
    if not ok:
        w_err = (writer.stderr.read() or b"").decode(errors="replace").strip()
        r_err = (reader.stderr.read() or b"").decode(errors="replace").strip()
        detail += f"w_rc={w_rc} r_rc={r_rc}"
        if w_err:
            detail += f" | writer: {w_err.splitlines()[-1]}"
        if r_err:
            detail += f" | reader: {r_err.splitlines()[-1]}"
    clear(r_bin, name)
    return ok, detail


def parse_langs(specs, flag):
    langs = {}
    for spec in specs:
        name, _, path = spec.partition(":")
        if not path:
            print(f"error: bad {flag} '{spec}', expected NAME:BIN", file=sys.stderr)
            return None
        if not (os.path.isfile(path) and os.access(path, os.X_OK)):
            print(f"error: harness for '{name}' not executable: {path}", file=sys.stderr)
            return None
        langs[name] = path
    return langs


def run_matrix(langs, read_verb, title, idx_start):
    """Run the full writer x reader matrix; return (failures, count, next_idx)."""
    names = sorted(langs)
    print(f"{title}: languages={names} sizes={SIZES} count={COUNT}\n")
    failures = []
    idx = idx_start
    for w in names:
        for r in names:
            for size in SIZES:
                idx += 1
                ok, detail = run_pair(w, langs[w], r, langs[r], size, idx, read_verb)
                status = "PASS" if ok else "FAIL"
                line = f"  [{status}] {w:>5} -> {r:<5}  {size:>5}B"
                if not ok:
                    line += f"   {detail}"
                    failures.append((w, r, size, detail))
                print(line)
    total = len(names) * len(names) * len(SIZES)
    print(f"\n  {total - len(failures)}/{total} {title} pairings passed.\n")
    return failures, total, idx


def main():
    ap = argparse.ArgumentParser(description="Cross-language IPC round-trip matrix")
    ap.add_argument("--lang", action="append", default=[], metavar="NAME:BIN",
                    help="a language whose harness does blocking read/write (repeatable)")
    ap.add_argument("--async-lang", action="append", default=[], metavar="NAME:BIN",
                    dest="async_lang",
                    help="a language whose harness `write` posts a notify and `aread` "
                         "does an async (readiness-fd-driven) receive (repeatable)")
    args = ap.parse_args()

    sync = parse_langs(args.lang, "--lang")
    asyncl = parse_langs(args.async_lang, "--async-lang")
    if sync is None or asyncl is None:
        return 2
    if not sync and not asyncl:
        print("error: no languages provided", file=sys.stderr)
        return 2

    failures = []
    total = 0
    idx = 0
    if sync:
        f, t, idx = run_matrix(sync, "read", "sync matrix", idx)
        failures += f; total += t
    if asyncl:
        # Async matrix: a writer's notify must wake an async receiver on the
        # readiness fd. Divergent notify keys (name or hash) fail the pairing.
        f, t, idx = run_matrix(asyncl, "aread", "async matrix (notify wakeup)", idx)
        failures += f; total += t

    print(f"TOTAL: {total - len(failures)}/{total} pairings passed.")
    if failures:
        print("FAILURES:")
        for w, r, size, detail in failures:
            print(f"  {w} -> {r} @ {size}B: {detail}")
        return 1
    print("All cross-language pairings round-tripped byte-for-byte.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
