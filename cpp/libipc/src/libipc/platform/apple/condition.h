// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <cstdint>
#include <atomic>
#include <chrono>

#include <errno.h>

#include "libipc/imp/log.h"
#include "libipc/mutex.h"
#include "libipc/shm.h"

#include "libipc/platform/apple/ulock.h"
#include "libipc/platform/apple/mutex.h"

namespace ipc {
namespace detail {
namespace sync {

// ulock-based condition variable for macOS.
//
// Design (sequence-counter condvar, analogous to Linux futex condvar):
//
//   Shared state: a 32-bit atomic sequence counter `seq`.
//
//   wait(mtx, tm):
//     1. Load seq (the "expected" value).
//     2. Unlock mtx.
//     3. __ulock_wait(seq, expected_seq, timeout) — sleeps if seq == expected_seq.
//     4. Relock mtx.
//
//   notify():
//     Increment seq, then __ulock_wake(1).
//
//   broadcast():
//     Increment seq, then __ulock_wake(ALL).
//
// The seq increment in notify/broadcast ensures that any waiter that has
// already read `seq` but not yet called __ulock_wait will see the new value
// and not sleep (the kernel compares atomically).
//
// Cross-process safety: seq lives in shared memory, so all processes see the
// same counter. __ulock_wait with UL_COMPARE_AND_WAIT_SHARED operates on the
// physical page, so it works across processes sharing the same mapping.

struct ulock_cond_t {
    std::atomic<std::uint32_t> seq;     // monotonically incremented on notify/broadcast
    std::atomic<std::int32_t>  waiters; // count of threads blocked in __ulock_wait
};

class condition {
    ipc::shm::handle shm_;
    ulock_cond_t *cond_ = nullptr;

    ulock_cond_t *acquire_cond(char const *name) {
        LIBIPC_LOG();
        if (!shm_.acquire(name, sizeof(ulock_cond_t))) {
            log.error("[acquire_cond] fail shm.acquire: ", name);
            return nullptr;
        }
        return static_cast<ulock_cond_t *>(shm_.get());
    }

public:
    condition() = default;
    ~condition() = default;

    void const *native() const noexcept {
        return cond_;
    }

    void *native() noexcept {
        return cond_;
    }

    bool valid() const noexcept {
        return cond_ != nullptr;
    }

    bool open(char const *name) noexcept {
        LIBIPC_LOG();
        close();
        cond_ = acquire_cond(name);
        if (cond_ == nullptr) return false;
        if (shm_.ref() <= 1) {
            // First opener: initialize.
            cond_->seq.store(0, std::memory_order_release);
            cond_->waiters.store(0, std::memory_order_release);
        }
        return valid();
    }

    void close() noexcept {
        LIBIPC_LOG();
        shm_.release();
        cond_ = nullptr;
    }

    void clear() noexcept {
        LIBIPC_LOG();
        if (cond_ != nullptr) {
            // Wake all waiters so they don't sleep forever.
            cond_->seq.fetch_add(1, std::memory_order_acq_rel);
            ::__ulock_wake(UL_COMPARE_AND_WAIT_SHARED | ULF_WAKE_ALL,
                           &cond_->seq, 0);
        }
        shm_.clear();
        cond_ = nullptr;
    }

    static void clear_storage(char const *name) noexcept {
        ipc::shm::handle::clear_storage(name);
    }

    // Wait for a notification, with optional timeout (ms).
    // The caller must hold mtx. mtx is released for the duration of the wait
    // and reacquired before returning.
    bool wait(ipc::sync::mutex &mtx, std::uint64_t tm) noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;

        // Snapshot the sequence counter while holding the mutex.
        // This prevents a lost-wakeup: if notify() fires between unlock and
        // __ulock_wait, the seq will have changed and the kernel won't sleep.
        std::uint32_t seq = cond_->seq.load(std::memory_order_acquire);

        // Release the mutex before sleeping.
        mtx.unlock();

        cond_->waiters.fetch_add(1, std::memory_order_relaxed);
        bool notified = false;
        if (tm == invalid_value) {
            // Infinite wait: loop on EINTR.
            for (;;) {
                int ret = ::__ulock_wait(UL_COMPARE_AND_WAIT_SHARED,
                                         &cond_->seq,
                                         static_cast<std::uint64_t>(seq),
                                         0 /* infinite */);
                if (ret >= 0) {
                    notified = true;
                    break;
                }
                int err = errno;
                if (err == EINTR) continue; // spurious wakeup — retry
                // Any other error: treat as wakeup (conservative).
                notified = true;
                break;
            }
        } else {
            using clock = std::chrono::steady_clock;
            auto deadline = clock::now() + std::chrono::milliseconds(tm);
            for (;;) {
                auto now = clock::now();
                if (now >= deadline) break;
                auto remaining = std::chrono::duration_cast<std::chrono::microseconds>(
                    deadline - now).count();
                std::uint32_t timeout_us = (remaining > 0 && remaining < UINT32_MAX)
                    ? static_cast<std::uint32_t>(remaining) : UINT32_MAX;
                int ret = ::__ulock_wait(UL_COMPARE_AND_WAIT_SHARED,
                                         &cond_->seq,
                                         static_cast<std::uint64_t>(seq),
                                         timeout_us);
                if (ret >= 0) {
                    notified = true;
                    break;
                }
                int err = errno;
                if (err == EINTR) continue; // spurious — retry with updated timeout
                // ETIMEDOUT or other: timed out
                break;
            }
        }
        cond_->waiters.fetch_sub(1, std::memory_order_relaxed);

        // Reacquire the mutex before returning.
        // Always use infinite wait here: the caller (e.g. lock_guard) will
        // unconditionally call unlock(), so we must hold the lock on return.
        mtx.lock(ipc::invalid_value);
        return notified;
    }

    bool notify(ipc::sync::mutex &) noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;
        cond_->seq.fetch_add(1, std::memory_order_acq_rel);
        if (cond_->waiters.load(std::memory_order_acquire) > 0)
            ::__ulock_wake(UL_COMPARE_AND_WAIT_SHARED, &cond_->seq, 0);
        return true;
    }

    bool broadcast(ipc::sync::mutex &) noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;
        cond_->seq.fetch_add(1, std::memory_order_acq_rel);
        if (cond_->waiters.load(std::memory_order_acquire) > 0)
            ::__ulock_wake(UL_COMPARE_AND_WAIT_SHARED | ULF_WAKE_ALL, &cond_->seq, 0);
        return true;
    }
};

} // namespace sync
} // namespace detail
} // namespace ipc
