// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Private, header-only definitions of the ABI-impacting message/chunk wire
// layout types. These used to live inside ipc.cpp's anonymous namespace, which
// made them unreachable to abi/dump_abi.cpp (the semantic-gate probe) — so their
// sizes could only be matrix-verified. Extracting them here lets the dumper
// measure them as ground truth, and keeps the ABI static_asserts next to the
// definitions. Not part of the public API (lives under src/, not include/).

#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "thoth-ipc/def.h"                // byte_t, storage_id_t, large_msg_align, make_align
#include "thoth-ipc/circ/elem_def.h"      // circ::cc_t
#include "thoth-ipc/rw_lock.h"            // spin_lock
#include "thoth-ipc/platform/detail.h"    // THOTH_IPC_CONSTEXPR_
#include "thoth-ipc/utility/id_pool.h"    // id_pool
#include "thoth-ipc/abi_generated.hpp"    // generated thoth::abi (abi/abi.json)

namespace thoth {
namespace detail {

using msg_id_t = std::uint32_t;

template <std::size_t DataSize, std::size_t AlignSize>
struct msg_t;

template <std::size_t AlignSize>
struct msg_t<0, AlignSize> {
    msg_id_t     cc_id_;
    msg_id_t     id_;
    std::int32_t remain_;
    bool         storage_;
};

template <std::size_t DataSize, std::size_t AlignSize>
struct msg_t : msg_t<0, AlignSize> {
    alignas(AlignSize) thoth::byte_t data_[DataSize] {};

    msg_t() = default;
    msg_t(msg_id_t cc_id, msg_id_t id, std::int32_t remain, void const * data, std::size_t size)
        : msg_t<0, AlignSize> {cc_id, id, remain, (data == nullptr) || (size == 0)} {
        if (this->storage_) {
            if (data != nullptr) {
                // copy storage-id
                *reinterpret_cast<thoth::storage_id_t*>(data_) =
                     *static_cast<thoth::storage_id_t const *>(data);
            }
        }
        else std::memcpy(data_, data, size);
    }
};

THOTH_IPC_CONSTEXPR_ std::size_t align_chunk_size(std::size_t size) noexcept {
    return (((size - 1) / thoth::large_msg_align) + 1) * thoth::large_msg_align;
}

// Per-chunk header: the max_align-padded connection-bitmask word that precedes
// the payload (the offset chunk_t::data() returns). Platform-dependent via
// alignof(max_align_t) — 8 on Apple, 16 on Linux/Win x86-64.
inline constexpr std::size_t chunk_header_size =
    thoth::make_align(alignof(std::max_align_t), sizeof(std::atomic<thoth::circ::cc_t>));

THOTH_IPC_CONSTEXPR_ std::size_t calc_chunk_size(std::size_t size) noexcept {
    return thoth::make_align(alignof(std::max_align_t),
                             align_chunk_size(chunk_header_size + size));
}

struct chunk_t {
    std::atomic<thoth::circ::cc_t> &conns() noexcept {
        return *reinterpret_cast<std::atomic<thoth::circ::cc_t> *>(this);
    }

    void *data() noexcept {
        return reinterpret_cast<thoth::byte_t *>(this) + chunk_header_size;
    }
};

struct chunk_info_t {
    thoth::id_pool<> pool_;
    thoth::spin_lock lock_;

    THOTH_IPC_CONSTEXPR_ static std::size_t chunks_mem_size(std::size_t chunk_size) noexcept {
        return thoth::id_pool<>::max_count * chunk_size;
    }

    thoth::byte_t *chunks_mem() noexcept {
        return reinterpret_cast<thoth::byte_t *>(this + 1);
    }

    chunk_t *at(std::size_t chunk_size, thoth::storage_id_t id) noexcept {
        if (id < 0) return nullptr;
        return reinterpret_cast<chunk_t *>(chunks_mem() + (chunk_size * id));
    }
};

// -----------------------------------------------------------------------------
// ABI conformance — these layout values must match the generated thoth::abi
// (abi/abi.json). Kept next to the definitions so both ipc.cpp and dump_abi.cpp
// (which now include this header) enforce them. msg_t is non-standard-layout
// (base + alignas member) so only sizeof is checkable; offsets stay matrix-only.
//
// chunk_* depend on alignof(std::max_align_t) (8 Apple / 16 Linux-Win x86-64);
// the generated values are apple_arm64, so those two asserts are Apple-guarded.
// -----------------------------------------------------------------------------
static_assert(sizeof(msg_t<64, 8>) == thoth::abi::msg_t_size, "abi drift: msg_t.size");
#if defined(__APPLE__)
static_assert(sizeof(chunk_info_t) == thoth::abi::chunk_info_size, "abi drift: chunk_info.size");
static_assert(chunk_header_size    == thoth::abi::chunk_header_size, "abi drift: chunk_header_size");
#endif

} // namespace detail
} // namespace thoth
