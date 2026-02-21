// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <cstdint>
#include <atomic>
#include <chrono>

#include <errno.h>

#include "libipc/imp/log.h"
#include "libipc/shm.h"

#include "libipc/platform/apple/ulock.h"

namespace ipc {
namespace detail {
namespace sync {

// ulock-based counting semaphore for macOS.
//
// Shared state: a 32-bit atomic count stored in shared memory.
//
// post(n): count += n, then wake up to n waiters via __ulock_wake.
//
// wait(tm):
//   Spin attempting count-- (CAS loop). If count == 0, sleep via
//   __ulock_wait until count changes, then retry.
//
// This eliminates the 100µs polling loop from the previous sem_trywait
// emulation, replacing it with true kernel-assisted blocking.

struct ulock_sem_t {
    std::atomic<std::uint32_t> count;
};

class semaphore {
    ipc::shm::handle shm_;
    ulock_sem_t *data_ = nullptr;

public:
    semaphore() = default;
    ~semaphore() noexcept = default;

    void const *native() const noexcept {
        return data_;
    }

    void *native() noexcept {
        return data_;
    }

    bool valid() const noexcept {
        return data_ != nullptr;
    }

    bool open(char const *name, std::uint32_t count) noexcept {
        LIBIPC_LOG();
        close();
        if (!shm_.acquire(name, sizeof(ulock_sem_t))) {
            log.error("[open_semaphore] fail shm.acquire: ", name);
            return false;
        }
        data_ = static_cast<ulock_sem_t *>(shm_.get());
        if (shm_.ref() <= 1) {
            // First opener: initialize count.
            data_->count.store(count, std::memory_order_release);
        }
        return valid();
    }

    void close() noexcept {
        LIBIPC_LOG();
        if (shm_.name() != nullptr)
            shm_.release();
        data_ = nullptr;
    }

    void clear() noexcept {
        LIBIPC_LOG();
        if (data_ != nullptr) {
            // Wake all waiters so they don't sleep forever.
            data_->count.store(UINT32_MAX, std::memory_order_release);
            ::__ulock_wake(UL_COMPARE_AND_WAIT_SHARED | ULF_WAKE_ALL,
                           &data_->count, 0);
        }
        shm_.clear();
        data_ = nullptr;
    }

    static void clear_storage(char const *name) noexcept {
        ipc::shm::handle::clear_storage(name);
    }

    bool wait(std::uint64_t tm) noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;

        using clock = std::chrono::steady_clock;
        bool has_deadline = (tm != invalid_value);
        clock::time_point deadline{};
        if (has_deadline)
            deadline = clock::now() + std::chrono::milliseconds(tm);

        for (;;) {
            // Try to decrement count atomically.
            std::uint32_t cur = data_->count.load(std::memory_order_acquire);
            while (cur > 0) {
                if (data_->count.compare_exchange_weak(
                        cur, cur - 1,
                        std::memory_order_acquire,
                        std::memory_order_relaxed)) {
                    return true; // successfully decremented
                }
                // cur was updated by CAS failure — retry inner loop
            }

            // count == 0: need to sleep.
            if (has_deadline) {
                auto now = clock::now();
                if (now >= deadline) return false;
                auto remaining = std::chrono::duration_cast<std::chrono::microseconds>(
                    deadline - now).count();
                std::uint32_t timeout_us = (remaining > 0 && remaining < UINT32_MAX)
                    ? static_cast<std::uint32_t>(remaining) : UINT32_MAX;
                int ret = ::__ulock_wait(UL_COMPARE_AND_WAIT_SHARED,
                                         &data_->count, 0, timeout_us);
                if (ret < 0 && errno != EINTR) {
                    // ETIMEDOUT or other error
                    return false;
                }
            } else {
                // Infinite wait — loop on EINTR.
                int ret = ::__ulock_wait(UL_COMPARE_AND_WAIT_SHARED,
                                         &data_->count, 0, 0);
                if (ret < 0 && errno != EINTR) {
                    // Unexpected error; treat conservatively as wakeup and retry.
                }
            }
            // Woken or spurious: loop back and retry the CAS.
        }
    }

    bool post(std::uint32_t count) noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;
        for (std::uint32_t i = 0; i < count; ++i) {
            data_->count.fetch_add(1, std::memory_order_release);
            // Wake one waiter per post.
            ::__ulock_wake(UL_COMPARE_AND_WAIT_SHARED, &data_->count, 0);
        }
        return true;
    }
};

} // namespace sync
} // namespace detail
} // namespace ipc
