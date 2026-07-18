// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors

#pragma once

#include "thoth-ipc/proto/codecs/flatbuffers_codec.h"
#include "thoth-ipc/proto/typed_channel_codec.h"

namespace thoth {
namespace proto {

// A typed wrapper around thoth::channel for FlatBuffer messages, implemented
// through the generic codec-based typed_channel_codec.
// T is the FlatBuffers-generated root table type.
//
// Usage:
//   // Sender
//   thoth::proto::typed_channel<MyMsg> ch("my_channel", thoth::sender);
//   thoth::proto::builder b;
//   auto off = CreateMyMsg(b.fbb(), ...);
//   b.finish(off);
//   ch.send(b);
//
//   // Receiver
//   thoth::proto::typed_channel<MyMsg> ch("my_channel", thoth::receiver);
//   auto msg = ch.recv();
//   if (msg) { auto *root = msg.root(); ... }
//
template <typename T>
using typed_channel = typed_channel_codec<T, flatbuffers_codec>;

} // namespace proto
} // namespace thoth
