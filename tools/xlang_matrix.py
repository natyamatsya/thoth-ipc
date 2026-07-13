#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
#
# Cross-language round-trip matrix driver.
#
# DEPRECATED: superseded by tools/xlang-runner (Rust), which adds declarative
# config, capability negotiation, parallel execution, secure (AEAD) scenarios
# and JUnit/JSON reporting. CI uses the runner; this script is kept for
# quick ad-hoc runs and will be removed once the runner has fully bedded in.
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


def harness_caps(bin_path):
    """Capabilities a harness reports via its `caps` verb (e.g. {'notify','async'})."""
    try:
        out = subprocess.run([bin_path, "caps", "_"], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True, timeout=10).stdout
        return set(out.split())
    except Exception:
        return set()


def check_async_caps(langs):
    """The async matrix needs each harness to post the notify (writer) and drive an
    async recv (reader). A harness built without those features would just hang, so
    verify up front and fail fast with an actionable message. Returns True if OK."""
    need = {"notify", "async"}
    ok = True
    for name in sorted(langs):
        caps = harness_caps(langs[name])
        if not need <= caps:
            ok = False
            have = " ".join(sorted(caps)) or "(none)"
            print(f"error: async matrix needs caps [notify, async] but harness "
                  f"'{name}' reports [{have}] — rebuild it with the notify/async "
                  f"feature (Rust: `--features async-tokio`; C++: LIBIPC_STDEXEC or "
                  f"LIBIPC_NOTIFY_FD).\n         {langs[name]}", file=sys.stderr)
    return ok


def run_reap_pair(h_lang, h_bin, r_lang, r_bin, kind, idx):
    """A holder connects a receiver; a reaper of another language then connects
    (reap-on-connect). `dead`: kill the holder first — the reaper must reclaim its
    slot (count == 1). `live`: holder stays up — the reaper must NOT reap it
    (count == 2), which also proves the start-token formula matches cross-language.
    """
    name = f"xr_{h_lang}_{r_lang}_{kind}_{os.getpid()}_{idx}"
    clear(r_bin, name)
    clear(h_bin, name)
    holder = subprocess.Popen([h_bin, "hold", name, "20"],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    ready = bool(holder.stdout and "READY" in (holder.stdout.readline() or ""))
    if not ready:
        holder.kill(); holder.wait()
        return False, "holder never became READY"
    if kind == "dead":
        holder.kill(); holder.wait()
    try:
        got = subprocess.run([r_bin, "count", name], stdout=subprocess.PIPE,
                             text=True, timeout=15).stdout.strip()
    except subprocess.TimeoutExpired:
        got = "<timeout>"
    if kind == "live":
        holder.kill(); holder.wait()
    clear(r_bin, name)
    exp = "2" if kind == "live" else "1"
    return got == exp, f"count={got} exp={exp}"


def run_reap_matrix(langs, idx_start):
    """Every holder x reaper x {live, dead} dead-connection reaping pairing."""
    names = sorted(langs)
    print(f"reap matrix (dead-connection): languages={names}\n")
    failures = []
    idx = idx_start
    total = 0
    for h in names:
        for r in names:
            for kind in ("dead", "live"):
                idx += 1
                total += 1
                ok, detail = run_reap_pair(h, langs[h], r, langs[r], kind, idx)
                status = "PASS" if ok else "FAIL"
                line = f"  [{status}] {h:>5} hold -> {r:<5} reap  {kind:<4}"
                if not ok:
                    line += f"   {detail}"
                    failures.append((h, r, kind, detail))
                print(line)
    print(f"\n  {total - len(failures)}/{total} reap-matrix pairings passed.\n")
    return failures, total, idx


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
    ap.add_argument("--reap-lang", action="append", default=[], metavar="NAME:BIN",
                    dest="reap_lang",
                    help="a language whose harness supports hold/count for the "
                         "dead-connection reaping matrix (repeatable)")
    args = ap.parse_args()

    sync = parse_langs(args.lang, "--lang")
    asyncl = parse_langs(args.async_lang, "--async-lang")
    reapl = parse_langs(args.reap_lang, "--reap-lang")
    if sync is None or asyncl is None or reapl is None:
        return 2
    if not sync and not asyncl and not reapl:
        print("error: no languages provided", file=sys.stderr)
        return 2

    failures = []
    total = 0
    idx = 0
    if sync:
        f, t, idx = run_matrix(sync, "read", "sync matrix", idx)
        failures += f; total += t
    if asyncl:
        # Fail fast (rather than hang 30s/pairing) if any async harness was built
        # without the notify/async features.
        if not check_async_caps(asyncl):
            return 2
        # Async matrix: a writer's notify must wake an async receiver on the
        # readiness fd. Divergent notify keys (name or hash) fail the pairing.
        f, t, idx = run_matrix(asyncl, "aread", "async matrix (notify wakeup)", idx)
        failures += f; total += t
    if reapl:
        # Reap matrix: a reaper of one language must reclaim a dead receiver of
        # another (byte-exact owner table) and never reap a live one (byte-exact
        # start token).
        f, t, idx = run_reap_matrix(reapl, idx)
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
