// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <cstdint>
#include <cassert>

#include "flatbuffers/flatbuffers.h"
#include "flatbuffers/verifier.h"

#include "libipc/buffer.h"

namespace ipc {
namespace proto {

// A received FlatBuffer message with typed access.
// T must be a FlatBuffers-generated table type (e.g. MyProtocol::ControlMsg).
template <typename T>
class message {
    ipc::buff_t buf_;

public:
    message() = default;
    explicit message(ipc::buff_t buf) : buf_{std::move(buf)} {}

    explicit operator bool() const noexcept { return !buf_.empty(); }
    bool empty() const noexcept { return buf_.empty(); }

    // Access the deserialized root. Zero-copy — just a pointer cast.
    const T *root() const noexcept {
        if (buf_.empty()) return nullptr;
        return flatbuffers::GetRoot<T>(buf_.data());
    }

    const T *operator->() const noexcept { return root(); }
    const T &operator*() const { return *root(); }

    // Verify the buffer integrity. Call this on untrusted data.
    bool verify() const noexcept {
        if (buf_.empty()) return false;
        flatbuffers::Verifier v(
            reinterpret_cast<const uint8_t *>(buf_.data()), buf_.size());
        return v.VerifyBuffer<T>(nullptr);
    }

    // Access the raw buffer.
    const void *data() const noexcept { return buf_.data(); }
    std::size_t size() const noexcept { return buf_.size(); }
};

// Helper: build a FlatBuffer message and return the raw bytes for sending.
// Usage:
//   auto [buf, size] = ipc::proto::build([](auto &fbb) {
//       auto name = fbb.CreateString("hello");
//       return MyTable::Pack(fbb, name);
//   });
class builder {
    flatbuffers::FlatBufferBuilder fbb_;

public:
    explicit builder(std::size_t initial_size = 1024)
        : fbb_{initial_size} {}

    flatbuffers::FlatBufferBuilder &fbb() noexcept { return fbb_; }

    // Finish the buffer with the given root offset.
    template <typename T>
    void finish(flatbuffers::Offset<T> root) {
        fbb_.Finish(root);
    }

    // Finish with a file identifier (4-char string from the schema).
    template <typename T>
    void finish(flatbuffers::Offset<T> root, const char *file_id) {
        fbb_.Finish(root, file_id);
    }

    const uint8_t *data() const noexcept { return fbb_.GetBufferPointer(); }
    std::size_t size() const noexcept { return fbb_.GetSize(); }

    void clear() { fbb_.Clear(); }
};

} // namespace proto
} // namespace ipc
