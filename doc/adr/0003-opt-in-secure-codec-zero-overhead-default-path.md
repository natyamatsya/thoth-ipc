# ADR-0003: Optional secure codec with zero-overhead default path

- Status: Proposed
- Date: 2026-03-04
- Owners: libipc maintainers

## Context

`libipc` is optimized for high-throughput, low-latency shared-memory IPC.

In enterprise deployments, teams may require confidentiality/integrity on IPC
payloads for defense-in-depth or compliance reasons, even on same-host process
boundaries.

At the same time, many performance-sensitive paths must keep current behavior and
must not pay runtime cost for security features they do not use.

ADR-0002 already introduced a codec-oriented typed protocol architecture. That
layering allows security features to be added above transport without changing
core shared-memory semantics.

## Decision

### 1) Security is opt-in, not mandatory

Payload encryption/authentication is optional and enabled only for endpoints that
explicitly choose a secure codec/profile.

Default typed wrappers and raw transport remain unchanged.

### 2) Zero-overhead requirement for the default path

When secure codec/profile is not selected:

- no runtime branch in `send`/`recv` hot paths,
- no virtual dispatch added to existing wrappers,
- no extra envelope parsing,
- no additional crypto dependency linked.

This implies compile-time selection (templates/generics/features), not runtime
boolean toggles.

### 3) Implement security as a codec decorator

Security is expressed as a codec wrapper over an existing payload codec:

- Conceptually: `secure_codec<InnerCodec, CipherPolicy>`
- `InnerCodec` remains responsible for payload serialization format
  (FlatBuffers/Protobuf/Cap'n Proto/etc.).
- `CipherPolicy` defines seal/open behavior.

This keeps transport and existing codec contracts stable.

### 4) Security profile is fail-closed

Decode must fail deterministically if open/authentication fails. Invalid secure
payloads must not be passed to inner codec decode.

### 5) Envelope compatibility policy

A versioned envelope is used for secure payloads (exact layout may evolve):

- profile/version,
- algorithm identifier,
- key identifier (or key slot id),
- nonce/IV,
- ciphertext,
- authentication tag.

Unknown/unsupported profile versions fail at decode/open.

### 6) Scope boundary

This ADR covers payload protection at typed protocol level.

It does **not** replace:

- OS ACL/permissions hardening on shared memory objects,
- process identity/authentication controls,
- key lifecycle/rotation policy at deployment level.

Those controls remain required for production hardening.

## Consequences

### Positive

- Meets enterprise requirement without regressing default latency path.
- Preserves current API/performance for existing users.
- Keeps layering clean: transport unchanged, security in codec layer.
- Enables selective rollout endpoint-by-endpoint.

### Trade-offs

- Secure path necessarily adds CPU and buffer handling overhead.
- Increases test matrix (secure/non-secure × codec × language).
- Requires explicit key management integration in applications.

## Implementation plan (phased)

1. **Phase A (architecture + baseline):**
   - Introduce secure codec decorator API in typed protocol layer.
   - Add compile-time conformance tests.
   - Verify unchanged behavior/perf for non-secure wrappers.

2. **Phase B (crypto profile):**
   - Add AEAD-based cipher policy implementation(s).
   - Define stable envelope format and compatibility checks.
   - Add negative tests (tamper, wrong key id, malformed envelope).

3. **Phase C (cross-language parity):**
   - Mirror secure codec abstraction in C++, Rust, Swift.
   - Gate dependencies with CMake options / Cargo features /
     optional Swift products.

4. **Phase D (validation + docs):**
   - Add benchmarks proving no regression in default path.
   - Add secure-path throughput/latency benchmarks.
   - Document threat model and deployment guidance.

## Alternatives considered

1. **Runtime `if (secure)` in hot path**
   - Rejected: imposes overhead and branch complexity for all users.

2. **Always-on encryption for all payloads**
   - Rejected: violates performance goals and "pay only for what you use".

3. **Transport-layer encryption in shared-memory core**
   - Rejected: couples security policy to stable transport internals and risks
     broad performance regressions.
