# ADR-0004: Secure envelope v1 + optional OpenSSL EVP backend via C ABI

- Status: Proposed
- Date: 2026-03-04
- Owners: libipc maintainers

## Context

ADR-0003 introduced opt-in `secure_codec<InnerCodec, CipherPolicy>` with a
zero-overhead default path. Initial implementation used a minimal secure
header (`magic + version`) and test-only ciphers.

Next step is production hardening:

- define a stable envelope v1 format carrying security metadata,
- use a vetted AEAD backend,
- keep crypto dependencies optional and off by default,
- provide a cross-language bridge (C++, Rust, Swift) through a common C ABI.

## Decision

### 1) Envelope v1 layout is explicit and fail-closed

All secure payloads use envelope v1:

1. magic (`"SIPC"`, 4 bytes)
2. version (`u8`, value `1`)
3. algorithm id (`u16`, little-endian)
4. key id (`u32`, little-endian)
5. nonce size (`u16`, little-endian)
6. tag size (`u16`, little-endian)
7. ciphertext size (`u32`, little-endian)
8. payload bytes (`nonce || ciphertext || tag`)

Decode fails closed on:

- invalid magic/version,
- malformed/truncated size fields,
- size mismatches,
- unsupported algorithm or key mismatch,
- AEAD open/tag verification failure.

### 2) Production AEAD backend is exposed through a stable C ABI

A C API (`secure_crypto_c.h`) is the cross-language contract:

- `libipc_secure_aead_encrypt(...)`
- `libipc_secure_aead_decrypt(...)`
- `libipc_secure_blob_free(...)`

Status/error codes and algorithm ids are represented as C enums for stable FFI
across C++, Rust, and Swift.

### 3) OpenSSL EVP backend is optional

OpenSSL implementation is compiled and linked only when explicitly enabled.
Default builds stay dependency-free and preserve non-secure path performance.

### 4) Language integration strategy

- C++: direct use via secure codec cipher policy adapter.
- Rust: feature-gated FFI module (`secure-crypto-c`, `secure-crypto-openssl`).
- Swift: optional product/target binding to the same C ABI (via shim/bridging
  header strategy).

## Consequences

### Positive

- Security metadata is explicit and interoperable.
- Crypto implementation is based on vetted primitives (OpenSSL EVP).
- Cross-language bindings share one low-level wire + C ABI contract.
- Default users incur zero crypto dependency and no runtime branches.

### Trade-offs

- Envelope parsing complexity increases.
- FFI boundary requires careful memory ownership handling.
- OpenSSL packaging differs across platforms and CI environments.

## Build wiring (draft)

### C++ (CMake)

- `LIBIPC_SECURE_OPENSSL` option (default OFF)
- `find_package(OpenSSL REQUIRED COMPONENTS Crypto)` only when ON
- `target_link_libraries(ipc PUBLIC OpenSSL::Crypto)` only when ON

### Rust (Cargo)

- `secure-crypto-c`
- `secure-crypto-openssl = ["secure-crypto-c"]`

### Swift (SwiftPM)

- Add optional secure crypto product/target that binds to C ABI headers and is
  excluded from the core target unless explicitly selected.

## Follow-up

1. Add end-to-end tests using the OpenSSL-backed cipher policy.
2. Add tamper/algorithm/key/truncation negative tests across languages.
3. Add secure-path benchmark suite and compare with non-secure baseline.
4. Define deployment guidance for key provisioning and rotation.
