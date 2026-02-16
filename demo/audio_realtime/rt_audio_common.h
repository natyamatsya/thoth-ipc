// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <atomic>
#include <cstdint>
#include <cstring>
#include <chrono>

#include "libipc/shm.h"

// --- Audio block for the lock-free ring buffer ---

static constexpr uint32_t kMaxFrames   = 1024;
static constexpr uint32_t kMaxChannels = 2;

struct audio_block {
    uint64_t sequence;
    uint32_t sample_rate;
    uint32_t channels;
    uint32_t frames;
    uint32_t pad_;
    alignas(16) float samples[kMaxFrames * kMaxChannels];
};

// --- Shared state block (replicated to all instances) ---

struct shared_state {
    // Heartbeat: producer writes monotonic timestamp (ns since epoch)
    std::atomic<uint64_t> heartbeat_ns{0};

    // Stream config
    std::atomic<uint32_t> sample_rate{0};
    std::atomic<uint32_t> channels{0};
    std::atomic<uint32_t> frames_per_buffer{0};
    std::atomic<bool>     stream_active{false};

    // Parameters (read by all instances, written via control channel)
    std::atomic<float>    gain{1.0f};
    std::atomic<float>    pan{0.0f};

    // Stats
    std::atomic<uint64_t> blocks_produced{0};
    std::atomic<uint64_t> blocks_consumed{0};
    std::atomic<uint64_t> underruns{0};
    std::atomic<uint64_t> overruns{0};

    static uint64_t now_ns() {
        using clock = std::chrono::steady_clock;
        return static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                clock::now().time_since_epoch()).count());
    }

    void touch_heartbeat() {
        heartbeat_ns.store(now_ns(), std::memory_order_release);
    }

    uint64_t heartbeat_age_ms() const {
        auto hb = heartbeat_ns.load(std::memory_order_acquire);
        if (hb == 0) return UINT64_MAX;
        auto age = now_ns() - hb;
        return age / 1'000'000;
    }
};

// Helper to open/create a named shared state block.
class shared_state_handle {
    ipc::shm::handle shm_;
    shared_state *ptr_ = nullptr;

public:
    bool open_or_create(const char *name) {
        close();
        if (!shm_.acquire(name, sizeof(shared_state), ipc::shm::create | ipc::shm::open))
            return false;
        ptr_ = static_cast<shared_state *>(shm_.get());
        return true;
    }

    bool open_existing(const char *name) {
        close();
        if (!shm_.acquire(name, sizeof(shared_state), ipc::shm::open))
            return false;
        ptr_ = static_cast<shared_state *>(shm_.get());
        return true;
    }

    shared_state *get() noexcept { return ptr_; }
    const shared_state *get() const noexcept { return ptr_; }
    bool valid() const noexcept { return ptr_ != nullptr; }

    void close() {
        if (shm_.valid())
            shm_.release();
        ptr_ = nullptr;
    }

    ~shared_state_handle() { close(); }
};
