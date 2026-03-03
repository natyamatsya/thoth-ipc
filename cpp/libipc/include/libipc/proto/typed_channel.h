// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include "libipc/proto/codecs/flatbuffers_codec.h"
#include "libipc/proto/typed_channel_codec.h"

namespace ipc {
namespace proto {

// A typed wrapper around ipc::channel for FlatBuffer messages, implemented
// through the generic codec-based typed_channel_codec.
// T is the FlatBuffers-generated root table type.
//
// Usage:
//   // Sender
//   ipc::proto::typed_channel<MyMsg> ch("my_channel", ipc::sender);
//   ipc::proto::builder b;
//   auto off = CreateMyMsg(b.fbb(), ...);
//   b.finish(off);
//   ch.send(b);
//
//   // Receiver
//   ipc::proto::typed_channel<MyMsg> ch("my_channel", ipc::receiver);
//   auto msg = ch.recv();
//   if (msg) { auto *root = msg.root(); ... }
//
template <typename T>
using typed_channel = typed_channel_codec<T, flatbuffers_codec>;

} // namespace proto
} // namespace ipc
