<!-- SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors -->

# Prioritized Remediation Plan

## Scope

Cross-language (C++/Rust/Swift/Zig) parity and hardening backlog. The original
P0 blockers and the secure test-matrix work have **shipped** (see below); what
remains is security *evidence* + *guidance* and doc hygiene.

---

## Shipped (for the record)

- **P0.1 — Cross-language interop CI matrix.** `.github/workflows/xlang.yml` runs
  the pairwise matrix (C++↔Rust on Linux; the full cpp/rust/swift/zig matrix on
  macOS), driven by `tools/xlang-runner`, and gates merges (`--require`).
- **P0.2 — Backend/profile contract.** The sync backend/profile is now a
  generated, checked contract: `abi/abi.json` + `sync_abi` (magic `LISA`, backend
  id `apple_ulock`), with the cross-platform policy documented in
  [`os-parity.md`](os-parity.md).
- **P1.4 — Secure test matrix (OpenSSL-backed + negative interop).** The
  `secure`, `secure-badkey`, and `secure-negative` scenarios run OpenSSL-backed
  AEAD across all ports (tamper / algorithm-mismatch / key-mismatch / bad-key-id),
  fail-closed, in the gated matrix.

---

## Open items

### P1.3 — Secure-path benchmark suite (all languages)

- **Why:** secure vs non-secure throughput/latency evidence is still missing —
  [`benchmarks.md`](benchmarks.md) has no secure rows.
- **Actions:**
  - Add benchmark targets for secure typed route/channel paths.
  - Measure secure vs non-secure baselines under comparable message sizes and
    thread topologies.
  - Capture and publish a reproducible benchmark methodology.
- **Definition of done:**
  - Bench outputs include secure/non-secure throughput and latency deltas.
  - Results are reproducible via a documented benchmark workflow.

### P1.5 — Threat model + key provisioning/rotation guidance

- **Why:** security *deployment* guidance is still only implicit in ADR-0003 /
  ADR-0004; there is no standalone security-operations doc.
- **Actions:**
  - Add a security operations doc covering: threat-model assumptions, key
    provisioning paths, key rotation procedures, recommended defaults and
    failure handling.
  - Link it from the top-level docs index.
- **Definition of done:**
  - Versioned security guidance exists and is discoverable from README/docs.

### P2.6 — Doc-link hygiene

- **Why:** docs still accumulate path/API drift as the tree evolves (this
  `context/` audit is part of the ongoing effort).
- **Actions:**
  - Keep top-level README / protocol-layer docs pointing at real locations.
  - Add a simple link-check step in CI if feasible.
- **Definition of done:**
  - No broken links in primary docs; protocol-layer docs match current headers.

### P2.7 — Align the Swift roadmap with package/workflow reality

- **Why:** `swift/thoth-ipc/ROADMAP.md` status can diverge from implemented
  products, demos, and CI jobs.
- **Actions:**
  - Reconcile roadmap entries with what actually ships; mark each item
    implemented / in progress / planned.
- **Definition of done:**
  - Roadmap status matches the repository state; gaps are intentional and tracked.

---

## Suggested execution order

1. P1.3 secure benchmarks
2. P1.5 threat model + key-ops guidance
3. P2.6 doc-link hygiene
4. P2.7 Swift roadmap alignment
