// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <atomic>
#include <cstdint>
#include <cstring>
#include <new>
#include <type_traits>

#include "libipc/shm.h"

namespace ipc {
namespace proto {

// Lock-free single-producer single-consumer ring buffer over shared memory.
//
// T must be trivially copyable (audio blocks, POD structs, etc.).
// Capacity is fixed at construction time. No allocations after init.
//
// Usage:
//   shm_ring<audio_block, 4> ring("my_ring");
//   ring.open_or_create();
//
//   // Producer (one thread/process):
//   if (auto *slot = ring.write_slot())  { *slot = block; ring.write_commit(); }
//
//   // Consumer (one thread/process):
//   if (auto *slot = ring.read_slot())   { use(*slot); ring.read_commit(); }
//
template <typename T, std::size_t N>
class shm_ring {
    static_assert(std::is_trivially_copyable_v<T>,
                  "shm_ring element must be trivially copyable");
    static_assert((N & (N - 1)) == 0, "shm_ring capacity must be a power of 2");

    struct alignas(64) header {
        std::atomic<uint64_t> write_idx{0};
        char pad0[64 - sizeof(std::atomic<uint64_t>)];
        std::atomic<uint64_t> read_idx{0};
        char pad1[64 - sizeof(std::atomic<uint64_t>)];
        std::atomic<bool> constructed{false};
        char pad2[64 - sizeof(std::atomic<bool>)];
    };

    struct layout {
        header hdr;
        T      slots[N];
    };

    ipc::shm::handle shm_;
    layout *data_ = nullptr;
    std::string name_;

    static constexpr uint64_t mask = N - 1;

public:
    static constexpr std::size_t capacity = N;

    explicit shm_ring(const char *name) : name_{name ? name : ""} {}

    ~shm_ring() { close(); }

    shm_ring(const shm_ring &) = delete;
    shm_ring &operator=(const shm_ring &) = delete;

    bool open_or_create() {
        if (!shm_.acquire(name_.c_str(), sizeof(layout), ipc::shm::create | ipc::shm::open))
            return false;
        data_ = static_cast<layout *>(shm_.get());
        if (!data_->hdr.constructed.load(std::memory_order_acquire)) {
            data_->hdr.write_idx.store(0, std::memory_order_relaxed);
            data_->hdr.read_idx.store(0, std::memory_order_relaxed);
            std::memset(data_->slots, 0, sizeof(data_->slots));
            data_->hdr.constructed.store(true, std::memory_order_release);
        }
        return true;
    }

    bool open_existing() {
        if (!shm_.acquire(name_.c_str(), sizeof(layout), ipc::shm::open))
            return false;
        data_ = static_cast<layout *>(shm_.get());
        return data_->hdr.constructed.load(std::memory_order_acquire);
    }

    void close() {
        if (shm_.valid())
            shm_.release();
        data_ = nullptr;
    }

    void destroy() {
        close();
        ipc::shm::handle::clear_storage(name_.c_str());
    }

    bool valid() const noexcept { return data_ != nullptr; }

    // --- Producer API (single writer) ---

    // Get a pointer to the next writable slot, or nullptr if the ring is full.
    // Does NOT advance the write index — call write_commit() after filling.
    T *write_slot() noexcept {
        if (!data_) return nullptr;
        auto w = data_->hdr.write_idx.load(std::memory_order_relaxed);
        auto r = data_->hdr.read_idx.load(std::memory_order_acquire);
        if (w - r >= N) return nullptr; // full
        return &data_->slots[w & mask];
    }

    void write_commit() noexcept {
        data_->hdr.write_idx.fetch_add(1, std::memory_order_release);
    }

    // Convenience: write a block, dropping the oldest if full.
    bool write(const T &item) noexcept {
        auto *slot = write_slot();
        if (!slot) return false;
        std::memcpy(slot, &item, sizeof(T));
        write_commit();
        return true;
    }

    // Overwrite mode: always write, advancing read_idx if full (drops oldest).
    void write_overwrite(const T &item) noexcept {
        if (!data_) return;
        auto w = data_->hdr.write_idx.load(std::memory_order_relaxed);
        auto r = data_->hdr.read_idx.load(std::memory_order_acquire);
        if (w - r >= N)
            data_->hdr.read_idx.store(r + 1, std::memory_order_release);
        std::memcpy(&data_->slots[w & mask], &item, sizeof(T));
        data_->hdr.write_idx.fetch_add(1, std::memory_order_release);
    }

    // --- Consumer API (single reader) ---

    // Get a pointer to the next readable slot, or nullptr if empty.
    const T *read_slot() const noexcept {
        if (!data_) return nullptr;
        auto r = data_->hdr.read_idx.load(std::memory_order_relaxed);
        auto w = data_->hdr.write_idx.load(std::memory_order_acquire);
        if (r >= w) return nullptr; // empty
        return &data_->slots[r & mask];
    }

    void read_commit() noexcept {
        data_->hdr.read_idx.fetch_add(1, std::memory_order_release);
    }

    // Convenience: read a block, returns false if empty.
    bool read(T &out) noexcept {
        auto *slot = read_slot();
        if (!slot) return false;
        std::memcpy(&out, slot, sizeof(T));
        read_commit();
        return true;
    }

    // --- Status ---

    std::size_t available() const noexcept {
        if (!data_) return 0;
        auto w = data_->hdr.write_idx.load(std::memory_order_acquire);
        auto r = data_->hdr.read_idx.load(std::memory_order_acquire);
        return static_cast<std::size_t>(w - r);
    }

    bool empty() const noexcept { return available() == 0; }
    bool full() const noexcept { return available() >= N; }
};

} // namespace proto
} // namespace ipc
