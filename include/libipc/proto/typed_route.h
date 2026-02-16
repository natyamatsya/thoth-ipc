#pragma once

#include "libipc/ipc.h"
#include "libipc/proto/message.h"

namespace ipc {
namespace proto {

// A typed wrapper around ipc::route for FlatBuffer messages.
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
class typed_route {
    ipc::route rt_;

public:
    typed_route() = default;

    typed_route(char const *name, unsigned mode)
        : rt_{name, mode} {}

    void connect(char const *name, unsigned mode) {
        rt_ = ipc::route{name, mode};
    }

    void disconnect() { rt_.disconnect(); }
    bool valid() const noexcept { return rt_.valid(); }

    // --- Sending ---

    bool send(const builder &b) {
        return rt_.send(b.data(), b.size());
    }

    bool send(const uint8_t *data, std::size_t size) {
        return rt_.send(data, size);
    }

    // --- Receiving ---

    message<T> recv(std::uint64_t tm = ipc::invalid_value) {
        return message<T>{rt_.recv(tm)};
    }

    message<T> try_recv() {
        return message<T>{rt_.try_recv()};
    }

    // --- Lifecycle ---

    ipc::route &raw() noexcept { return rt_; }
    const ipc::route &raw() const noexcept { return rt_; }

    static void clear_storage(char const *name) {
        ipc::route::clear_storage(name);
    }
};

} // namespace proto
} // namespace ipc
