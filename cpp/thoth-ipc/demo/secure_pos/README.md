# secure_pos — encrypted IPC as a *requirement*, not a feature

A minimal point-of-sale card pipeline showing where the secure codec (AEAD
envelope v1) is not just nice to have but **mandated**:

- **PCI-DSS / P2PE**: cardholder data must be encrypted at the point of
  capture, and intermediary software (the merchant's POS app) must be
  *cryptographically unable* to read it — that is precisely what keeps the
  POS out of PCI audit scope.
- **Broadcast privilege separation**: `ipc::route` is 1→N broadcast — every
  subscriber sees every message's bytes. Transport-level permissions cannot
  restrict who can *read* on a shared bus; application-layer AEAD is the only
  mechanism. The same pattern applies to any mixed-privilege bus: audit
  events sealed for the audit daemon, tokens sealed for the secrets broker,
  PHI sealed for the clinical viewer (HIPAA).

## Cast

| role      | key material           | behaviour                                            |
|-----------|------------------------|------------------------------------------------------|
| `pinpad`  | processor key          | seals every card event at capture, broadcasts        |
| `gateway` | processor key          | the only reader that can open events — authorises    |
| `pos`     | none (zeroed key)      | sees opaque envelopes; every open fails closed       |

Each event is sealed individually (fresh nonce, AEAD tag, `SIPC` envelope
framing) through the composed public API — `typed_route_codec` +
`secure_codec<protobuf_codec, secure_openssl_evp_cipher>` — i.e. the typed
protocol layer and the secure codec stacked the way a real application would.

> **Demo key only.** Real deployments provision the key into the pinpad's
> secure element and the gateway's HSM/KMS; it never appears in source, and
> key rotation bumps the envelope's `key_id`.

## Build & run

C++ (needs the OpenSSL backend):

```sh
cmake -B build -DLIBIPC_BUILD_DEMOS=ON -DLIBIPC_SECURE_OPENSSL=ON \
      -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"   # macOS
cmake --build build --target secure_pos
```

Rust counterpart (wire-identical, mix roles across languages freely):

```sh
cargo build --features secure-crypto-openssl,codec-protobuf --bin demo_secure_pos
```

Three terminals — receivers first, any language for any role:

```sh
./build/bin/secure_pos gateway            # or: demo_secure_pos gateway
./build/bin/secure_pos pos                # or: demo_secure_pos pos
./build/bin/secure_pos pinpad             # or: demo_secure_pos pinpad
```

Expected: the gateway prints `authorised ****-****-****-1111 for 1250c …`
for every event while the POS prints `sealed envelope observed — cannot
decrypt (as required)` — and exits non-zero if it ever *can* decrypt.

The cross-language pairing itself (any language seals → every other opens,
tampered/wrong-key/wrong-key-id envelopes rejected) is proven exhaustively by
the test matrix — see `tools/xlang-runner` scenarios `secure`,
`secure-badkey`, `secure-negative`.
