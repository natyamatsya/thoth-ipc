// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include "libipc/ipc.h"
#include "libipc/proto/message.h"

namespace ipc {
namespace proto {

// A typed wrapper around ipc::channel for FlatBuffer messages.
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
class typed_channel {
    ipc::channel ch_;

public:
    typed_channel() = default;

    typed_channel(char const *name, unsigned mode)
        : ch_{name, mode} {}

    void connect(char const *name, unsigned mode) {
        ch_ = ipc::channel{name, mode};
    }

    void disconnect() { ch_.disconnect(); }
    bool valid() const noexcept { return ch_.valid(); }

    // --- Sending ---

    bool send(const builder &b) {
        return ch_.send(b.data(), b.size());
    }

    bool send(const uint8_t *data, std::size_t size) {
        return ch_.send(data, size);
    }

    // --- Receiving ---

    message<T> recv(std::uint64_t tm = ipc::invalid_value) {
        return message<T>{ch_.recv(tm)};
    }

    message<T> try_recv() {
        return message<T>{ch_.try_recv()};
    }

    // --- Lifecycle ---

    ipc::channel &raw() noexcept { return ch_; }
    const ipc::channel &raw() const noexcept { return ch_; }

    static void clear_storage(char const *name) {
        ipc::channel::clear_storage(name);
    }
};

} // namespace proto
} // namespace ipc
