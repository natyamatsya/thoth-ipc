// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors

#pragma once

#include "thoth-ipc/proto/codecs/flatbuffers_codec.h"
#include "thoth-ipc/proto/typed_route_codec.h"

namespace thoth {
namespace proto {

// A typed wrapper around thoth::route for FlatBuffer messages, implemented
// through the generic codec-based typed_route_codec.
// T is the FlatBuffers-generated root table type.
// thoth::route is single-writer, multiple-reader (broadcast).
//
// Usage:
//   // Sender
//   thoth::proto::typed_route<MyMsg> r("my_route", thoth::sender);
//   thoth::proto::builder b;
//   auto off = CreateMyMsg(b.fbb(), ...);
//   b.finish(off);
//   r.send(b);
//
//   // Receiver
//   thoth::proto::typed_route<MyMsg> r("my_route", thoth::receiver);
//   auto msg = r.recv();
//   if (msg) { auto *root = msg.root(); ... }
//
template <typename T>
using typed_route = typed_route_codec<T, flatbuffers_codec>;

} // namespace proto
} // namespace thoth
