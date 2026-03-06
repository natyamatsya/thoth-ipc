<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors -->

# Prioritized Remediation Plan

## Scope

This plan prioritizes implementation gaps across C++, Rust, and Swift for:

- Cross-language sync ABI/profile parity
- CI coverage for cross-language interop
- Secure codec validation, benchmarks, and deployment guidance
- Documentation/roadmap correctness

---

## P0 — Blockers (do first)

### 1) Add cross-language interop CI matrix

- **Why:** ADR requires pairwise validation across languages, but CI is currently C++-centric.
- **Actions:**
  - Add CI jobs for:
    - C++ ↔ Rust interop
    - C++ ↔ Swift interop
    - Rust ↔ Swift interop
  - Include sync primitive scenarios: lock/unlock, wait/notify, timeout, dead-owner/robustness behavior.
  - Gate merges on matrix success.
- **Definition of done:**
  - Pairwise interop jobs run on every PR.
  - ABI/profile mismatches fail fast with actionable error output.

---

### 2) Resolve backend contract/profile mismatch policy

- **Why:** Current platform backend IDs/profiles are not consistently aligned across languages.
- **Actions:**
  - Decide and document platform policy explicitly:
    - Linux: whether C++ `linux_a0` and Rust/Swift pthread profiles are expected to interoperate.
    - macOS: whether Apple Mach profile is required outside C++ and how App Store-safe mode maps across languages.
  - Implement policy in all language bindings (or hard-fail unsupported combinations at runtime).
  - Ensure sync ABI stamps/backends are consistent with that policy.
- **Definition of done:**
  - A single documented backend/profile contract exists.
  - Runtime guardrails reject unsupported cross-profile combinations deterministically.

---

## P1 — Security validation and performance proof

### 3) Add secure-path benchmark suite (all languages)

- **Why:** ADR Phase D/follow-up calls for secure vs non-secure throughput/latency evidence.
- **Actions:**
  - Add benchmark targets for secure typed route/channel paths.
  - Measure secure vs non-secure baselines under comparable message sizes and thread topologies.
  - Capture and publish reproducible benchmark methodology.
- **Definition of done:**
  - Bench outputs include secure/non-secure throughput and latency deltas.
  - Results are reproducible in CI/nightly (or documented benchmark workflow).

---

### 4) Close secure test matrix gaps (OpenSSL-backed + negative interop)

- **Why:** Follow-up work requests end-to-end OpenSSL-backed policy tests and negative scenarios across languages.
- **Actions:**
  - Add cross-language e2e tests using OpenSSL-backed cipher policy.
  - Add negative tests across C++/Rust/Swift for:
    - tamper detection
    - algorithm mismatch
    - key mismatch
    - truncated envelope
  - Ensure fail-closed behavior is verified consistently.
- **Definition of done:**
  - Secure e2e tests run in CI for all supported language pairings.
  - Negative cases consistently fail-closed across all implementations.

---

### 5) Publish threat model + key provisioning/rotation guidance

- **Why:** Security deployment guidance is explicitly pending in ADRs.
- **Actions:**
  - Add a security operations doc covering:
    - threat model assumptions
    - key provisioning paths
    - key rotation procedures
    - recommended defaults and failure handling
  - Link it from top-level docs.
- **Definition of done:**
  - Versioned security guidance exists and is discoverable from README/docs index.

---

## P2 — Documentation and roadmap consistency

### 6) Fix README links and stale protocol docs

- **Why:** Current docs contain path drift and API drift.
- **Actions:**
  - Fix top-level README links to actual doc locations.
  - Update protocol-layer docs to match current secure codec API and build wiring.
  - Add a simple link-check step in CI if feasible.
- **Definition of done:**
  - No broken links in primary docs.
  - Protocol-layer docs reflect current header/build behavior.

---

### 7) Align Swift roadmap with package/workflow reality

- **Why:** Roadmap expectations and current package/workflow state diverge.
- **Actions:**
  - Reconcile roadmap entries with implemented products, demos, and CI jobs.
  - Mark each roadmap item clearly as: implemented, in progress, planned.
- **Definition of done:**
  - Roadmap status matches current repository state.
  - Gaps are intentional and explicitly tracked.

---

## Recommended execution sequence

1. P0.1 CI matrix
2. P0.2 backend/profile contract alignment
3. P1.3 secure benchmarks
4. P1.4 secure e2e + negative matrix
5. P1.5 threat model + deployment guidance
6. P2.6 docs/link fixes
7. P2.7 Swift roadmap alignment

---

## Suggested PR breakdown

### PR A (P0): Interop CI + contract guardrails

- CI matrix jobs
- Backend/profile policy doc
- Runtime validation updates

### PR B (P1): Secure validation + benchmarks

- Secure benchmark harnesses
- OpenSSL-backed e2e tests
- Cross-language negative tests

### PR C (P1/P2): Security docs + doc consistency

- Threat model and key operations guidance
- README/proto-layer fixes
- Swift roadmap status normalization
