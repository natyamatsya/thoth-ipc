# Serialization Phase A patch plan (minimal, no behavior change)

This plan introduces a codec abstraction while keeping FlatBuffers behavior and APIs intact.

## Scope

### Goals

- Preserve existing FlatBuffers typed API behavior in C++, Rust, Swift.
- Introduce internal codec seams for future Protobuf/Cap'n Proto modules.
- Avoid transport changes (`ipc::channel` / `ipc::route` and shared-memory layout remain untouched).

### Non-goals

- No wire-format negotiation envelope.
- No Protobuf/Cap'n Proto runtime support yet.
- No breaking API changes.

---

## C++ patch plan

### C++ new files

1. `cpp/thoth-ipc/include/thoth-ipc/proto/codec.h`
   - Add `enum class codec_id : uint8_t` with at least `flatbuffers`.
   - Add codec concept/traits interface:
     - `template <typename TCodec, typename T> class typed_message;`
     - `TCodec::verify(const void*, size_t)`
     - `TCodec::decode_root<T>(const void*)`
     - `TCodec::encode(...)` (builder glue)

2. `cpp/thoth-ipc/include/thoth-ipc/proto/codecs/flatbuffers_codec.h`
   - Implement FlatBuffers adapter using existing APIs:
     - `flatbuffers::GetRoot<T>()`
     - `flatbuffers::Verifier`
     - `flatbuffers::FlatBufferBuilder`

3. `cpp/thoth-ipc/include/thoth-ipc/proto/typed_channel_codec.h`
   - Add generic typed channel wrapper:
     - `template <typename T, typename Codec> class typed_channel_codec`

4. `cpp/thoth-ipc/include/thoth-ipc/proto/typed_route_codec.h`
   - Add generic typed route wrapper:
     - `template <typename T, typename Codec> class typed_route_codec`

### C++ existing file updates

1. `cpp/thoth-ipc/include/thoth-ipc/proto/message.h`
   - Keep public `message<T>` and `builder` names.
   - Re-implement as aliases/wrappers over flatbuffers codec specialization.

2. `cpp/thoth-ipc/include/thoth-ipc/proto/typed_channel.h`
   - Keep `typed_channel<T>` public API.
   - Re-implement as adapter/alias over `typed_channel_codec<T, flatbuffers_codec>`.

3. `cpp/thoth-ipc/include/thoth-ipc/proto/typed_route.h`
   - Keep `typed_route<T>` public API.
   - Re-implement as adapter/alias over `typed_route_codec<T, flatbuffers_codec>`.

### C++ CMake changes

1. `cpp/thoth-ipc/CMakeLists.txt`
   - Keep `THOTH_IPC_BUILD_PROTO` behavior unchanged for Phase A.
   - Add placeholder options (default OFF, no functional impact yet):
     - `THOTH_IPC_CODEC_PROTOBUF`
     - `THOTH_IPC_CODEC_CAPNP`
   - Do not fetch/link extra dependencies in Phase A.

---

## Rust patch plan

### Rust new files

1. `rust/thoth-ipc/src/proto/codec.rs`
   - Add `CodecId` enum (`FlatBuffers` for Phase A).
   - Add trait:
     - `trait Codec<T> { encode, decode, verify, CODEC_ID }`

2. `rust/thoth-ipc/src/proto/codecs/flatbuffers.rs`
   - Add FlatBuffers codec impl reusing existing logic from `message.rs`.

3. `rust/thoth-ipc/src/proto/typed_channel_codec.rs`
   - Add generic typed wrapper:
     - `TypedChannelCodec<T, C: Codec<T>>`

4. `rust/thoth-ipc/src/proto/typed_route_codec.rs`
   - Add generic typed wrapper:
     - `TypedRouteCodec<T, C: Codec<T>>`

5. `rust/thoth-ipc/src/proto/codecs/mod.rs`
   - Export `flatbuffers` module.

### Rust existing file updates

1. `rust/thoth-ipc/src/proto/message.rs`
   - Keep `Message<T>` and `Builder` public names for compatibility.
   - Internally route validation/root access through flatbuffers codec helper.

2. `rust/thoth-ipc/src/proto/typed_channel.rs`
   - Keep current public `TypedChannel<T>` API.
   - Implement as alias/newtype over `TypedChannelCodec<T, FlatBuffersCodec>`.

3. `rust/thoth-ipc/src/proto/typed_route.rs`
   - Keep current public `TypedRoute<T>` API.
   - Implement as alias/newtype over `TypedRouteCodec<T, FlatBuffersCodec>`.

4. `rust/thoth-ipc/src/proto/mod.rs`
   - Export new codec modules.
   - Keep existing exports unchanged.

### Rust Cargo changes

1. `rust/thoth-ipc/Cargo.toml`
   - Keep `flatbuffers` dependency and behavior unchanged.
   - Add placeholder features only (no new deps yet):
     - `codec-protobuf = []`
     - `codec-capnp = []`

---

## Swift patch plan

### Swift new files

1. `swift/thoth-ipc/Sources/LibIPC/Proto/Codec.swift`
   - Define codec protocol:
     - `associatedtype Message`
     - `static var codecId: UInt8`
     - `encode/decode/verify`

2. `swift/thoth-ipc/Sources/LibIPC/Proto/Codecs/FlatBuffersCodec.swift`
   - Implement codec adapter around existing `FlatBuffers` APIs.

3. `swift/thoth-ipc/Sources/LibIPC/Proto/TypedChannelCodec.swift`
   - Generic typed wrapper over raw `Channel`.

4. `swift/thoth-ipc/Sources/LibIPC/Proto/TypedRouteCodec.swift`
   - Generic typed wrapper over raw `Route`.

### Swift existing file updates

1. `swift/thoth-ipc/Sources/LibIPC/Proto/Message.swift`
   - Keep current public API as FlatBuffers compatibility facade.
   - Move reusable verification/decode helpers to codec adapter where possible.

2. `swift/thoth-ipc/Sources/LibIPC/Proto/TypedChannel.swift`
   - Keep `TypedChannel<T>` public name/behavior.
   - Implement as facade over generic codec wrapper with FlatBuffers codec.

3. `swift/thoth-ipc/Sources/LibIPC/Proto/TypedRoute.swift`
   - Keep `TypedRoute<T>` public name/behavior.
   - Implement as facade over generic codec wrapper with FlatBuffers codec.

### Swift package manifest changes

1. `swift/thoth-ipc/Package.swift`
   - Keep FlatBuffers dependency unchanged.
   - No new package dependencies in Phase A.

---

## Compatibility criteria (must pass before merge)

1. Existing FlatBuffers demos compile and run without source changes.
2. Existing typed protocol tests pass in each language.
3. No API removals in public FlatBuffers-facing symbols.
4. No transport performance regressions from extra allocations on send/recv hot path.

---

## Suggested execution order

1. Rust abstraction (smallest blast radius for trait-based refactor).
2. C++ abstraction (header-only facade pattern).
3. Swift abstraction (protocol + generic wrappers).
4. Documentation updates (`proto-layer.md`, language READMEs) after parity validation.
