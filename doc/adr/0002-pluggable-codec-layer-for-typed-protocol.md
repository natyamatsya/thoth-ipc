# ADR-0002: Pluggable codec layer for typed IPC protocol

- Status: Proposed
- Date: 2026-03-04
- Owners: libipc maintainers

## Context

Today, the typed protocol layer is FlatBuffers-specific in all language bindings:

- C++ typed message/builder wrappers include FlatBuffers headers directly.
- Rust `proto` layer depends directly on the `flatbuffers` crate.
- Swift typed protocol APIs constrain message types to `FlatBufferTable & Verifiable`.

At the same time, the underlying transport (`route`/`channel`) already operates on raw bytes in all bindings and is serialization-agnostic.

We want to offer optional support for additional schema frameworks (Protocol Buffers and Cap'n Proto) without changing shared-memory transport semantics or regressing existing FlatBuffers users.

## Decision

### 1) Keep transport unchanged, add a codec layer above it

We keep all existing transport behavior, shared-memory layout, and synchronization semantics unchanged.

A new codec abstraction is introduced in the typed protocol layer only:

- `encode(message) -> bytes`
- `decode(bytes) -> message/view`
- `verify(bytes) -> bool/result`
- codec identity metadata (`codec_id`, optional schema/type identity)

### 2) FlatBuffers remains first-class and default

FlatBuffers stays the default typed protocol backend for API and behavior parity.

Phase A must preserve source compatibility for existing FlatBuffers users (same public names and behavior).

### 3) Add optional codecs behind build features

Protocol Buffers and Cap'n Proto are optional modules, enabled only when requested:

- C++: CMake options
- Rust: Cargo features
- Swift: optional package products/targets

No new dependency is mandatory for users who only need current FlatBuffers behavior.

### 4) Keep wire format static unless explicitly negotiated

Typed channels/routes remain statically configured to one codec per endpoint by default.

A small envelope for mixed-codec negotiation is allowed as a future extension, but is out of scope for Phase A and should not be required for static codec channels.

### 5) Cross-language contract and tests

Each codec must define:

- compatibility expectations across language bindings,
- schema evolution guarantees and constraints,
- validation behavior on untrusted data.

Interop tests must be added for every supported codec/profile pair before claiming production readiness.

## Consequences

### Positive

- Wider adoption: teams can reuse existing `.proto`/Cap'n Proto schemas.
- Better product fit by workload (FlatBuffers/Cap'n Proto/Protobuf choice).
- No transport-layer risk: shared-memory IPC core remains unchanged.
- Incremental migration path: channel-by-channel codec adoption.

### Trade-offs

- More maintenance surface (codegen, feature gating, test matrix).
- Potential API complexity if generic codec types are exposed directly.
- Cap'n Proto support in Swift is likely less mature initially than Protobuf.

## Implementation plan

1. **Phase A (no behavior change):**
   - Introduce codec abstraction and FlatBuffers adapter only.
   - Keep existing typed API names via aliases/facades.

2. **Phase B (Protocol Buffers):**
   - Add optional Protobuf codec modules in C++/Rust/Swift.
   - Add cross-language control-path interop tests.

3. **Phase C (Cap'n Proto):**
   - Add C++/Rust support first.
   - Add Swift support as experimental until ecosystem maturity is validated.

4. **Phase D (optional negotiation envelope):**
   - Add codec envelope only if dynamic codec selection per channel is required.

See `doc/serialization-phase-a-plan.md` for the minimal concrete patch plan.

## Alternatives considered

1. **Keep FlatBuffers-only typed layer**
   - Rejected: limits reuse for teams standardized on Protobuf/Cap'n Proto.

2. **Add Protobuf/Cap'n Proto directly into transport**
   - Rejected: violates layering and increases risk to stable IPC core.

3. **Always use runtime codec negotiation envelope**
   - Rejected for now: unnecessary overhead/complexity for static codec channels.
