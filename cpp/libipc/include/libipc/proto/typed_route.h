// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include "libipc/proto/codecs/flatbuffers_codec.h"
#include "libipc/proto/typed_route_codec.h"

namespace ipc {
namespace proto {

// A typed wrapper around ipc::route for FlatBuffer messages, implemented
// through the generic codec-based typed_route_codec.
// T is the FlatBuffers-generated root table type.
// ipc::route is single-writer, multiple-reader (broadcast).
//
// Usage:
//   // Sender
//   ipc::proto::typed_route<MyMsg> r("my_route", ipc::sender);
//   ipc::proto::builder b;
//   auto off = CreateMyMsg(b.fbb(), ...);
//   b.finish(off);
//   r.send(b);
//
//   // Receiver
//   ipc::proto::typed_route<MyMsg> r("my_route", ipc::receiver);
//   auto msg = r.recv();
//   if (msg) { auto *root = msg.root(); ... }
//
template <typename T>
using typed_route = typed_route_codec<T, flatbuffers_codec>;

} // namespace proto
} // namespace ipc
