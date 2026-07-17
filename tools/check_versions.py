#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
# SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
"""Verify that every dependency pin matches versions.json.

versions.json is the single source of truth for third-party dependency
versions across all language ecosystems. This script checks that

  * each vendored git submodule is pinned to the commit recorded for its
    dependency (the same dependency vendored in two places must therefore
    point at the same commit), and
  * each Cargo manifest pins the crate to exactly "=<version>".

Exit code is non-zero on any mismatch, so CI fails on version drift.

To upgrade a dependency: edit versions.json, move the submodule
checkout(s) to the new commit, update the Cargo pin, and commit it all
together — this check keeps the three in lockstep.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def submodule_commit(path: str) -> str:
    """Commit a submodule is pinned to, from the worktree if initialized,
    otherwise from the git index."""
    probe = subprocess.run(
        ["git", "-C", str(ROOT / path), "rev-parse", "HEAD"],
        capture_output=True, text=True,
    )
    if probe.returncode == 0:
        return probe.stdout.strip()
    listing = subprocess.run(
        ["git", "ls-files", "-s", path],
        capture_output=True, text=True, cwd=ROOT, check=True,
    ).stdout.split()
    if len(listing) < 2 or listing[0] != "160000":
        raise RuntimeError(f"{path} is not a submodule in the git index")
    return listing[1]


def cargo_pin(manifest: str, crate: str) -> str:
    """The version string a Cargo manifest pins `crate` to."""
    text = (ROOT / manifest).read_text()
    match = re.search(
        rf'^{re.escape(crate)}\s*=\s*(?:"(?P<bare>[^"]+)"|\{{.*?version\s*=\s*"(?P<table>[^"]+)".*?\}})',
        text, re.MULTILINE,
    )
    if not match:
        raise RuntimeError(f"{manifest}: no dependency entry for '{crate}'")
    return match.group("bare") or match.group("table")


def main() -> int:
    deps = json.loads((ROOT / "versions.json").read_text())
    failures = []

    for name, spec in deps.items():
        version, commit = spec["version"], spec["commit"]

        for sub in spec.get("submodules", []):
            actual = submodule_commit(sub)
            if actual == commit:
                print(f"ok   {name} {version}: {sub} @ {actual[:12]}")
            else:
                failures.append(
                    f"{name}: submodule {sub} is at {actual[:12]}, "
                    f"versions.json wants {commit[:12]} (v{version})")

        cargo = spec.get("cargo")
        if cargo:
            pin = cargo_pin(cargo["manifest"], cargo["crate"])
            if pin == f"={version}":
                print(f"ok   {name} {version}: {cargo['manifest']} pins ={version}")
            else:
                failures.append(
                    f"{name}: {cargo['manifest']} pins '{pin}', "
                    f"versions.json wants '={version}' (exact pin required)")

    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    if failures:
        print(f"\n{len(failures)} version drift issue(s) — versions.json is "
              "the source of truth; align the pins or update it.",
              file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
