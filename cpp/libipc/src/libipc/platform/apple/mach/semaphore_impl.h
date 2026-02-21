// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

// Mach semaphore-based counting semaphore for macOS (App Store safe).
//
// The count lives in shared memory (std::atomic<uint32_t>). A process-local
// Mach semaphore is used for blocking. post() increments the count then
// signals the Mach semaphore. wait() decrements the count if > 0, otherwise
// sleeps on the Mach semaphore and retries.

#include <cstdint>
#include <atomic>
#include <chrono>
#include <string>
#include <unordered_map>
#include <mutex>

#include <mach/mach.h>
#include <mach/semaphore.h>
#include <mach/task.h>

#include "libipc/imp/log.h"
#include "libipc/shm.h"
#include "libipc/def.h"

namespace ipc {
namespace detail {
namespace sync {

struct mach_sem_state_t {
    std::atomic<std::uint32_t> count {0};
};

namespace mach_sem_detail {

struct Entry {
    semaphore_t sem  = MACH_PORT_NULL;
    int         refs = 0;
};

inline std::mutex& table_lock() {
    static std::mutex m;
    return m;
}

inline std::unordered_map<std::string, Entry>& table() {
    static std::unordered_map<std::string, Entry> t;
    return t;
}

inline semaphore_t acquire(const std::string& name) {
    std::lock_guard<std::mutex> g(table_lock());
    auto& e = table()[name];
    if (e.refs == 0) {
        kern_return_t kr = semaphore_create(mach_task_self(), &e.sem,
                                            SYNC_POLICY_FIFO, 0);
        if (kr != KERN_SUCCESS) return MACH_PORT_NULL;
    }
    ++e.refs;
    return e.sem;
}

inline void release(const std::string& name) {
    std::lock_guard<std::mutex> g(table_lock());
    auto it = table().find(name);
    if (it == table().end()) return;
    if (--it->second.refs == 0) {
        semaphore_destroy(mach_task_self(), it->second.sem);
        table().erase(it);
    }
}

} // namespace mach_sem_detail

class semaphore {
    ipc::shm::handle   shm_;
    mach_sem_state_t  *data_ = nullptr;
    semaphore_t        sem_  = MACH_PORT_NULL;
    std::string        name_;

public:
    semaphore() = default;
    ~semaphore() = default;

    void const *native() const noexcept { return data_; }
    void       *native()       noexcept { return data_; }

    bool valid() const noexcept {
        return data_ != nullptr && sem_ != MACH_PORT_NULL;
    }

    bool open(char const *name, std::uint32_t count) noexcept {
        LIBIPC_LOG();
        close();
        name_ = name ? name : "";
        if (!shm_.acquire(name, sizeof(mach_sem_state_t))) {
            log.error("[mach_sem] fail shm.acquire: ", name);
            return false;
        }
        data_ = static_cast<mach_sem_state_t *>(shm_.get());
        if (shm_.ref() <= 1)
            data_->count.store(count, std::memory_order_release);
        sem_ = mach_sem_detail::acquire(name_);
        if (sem_ == MACH_PORT_NULL) {
            log.error("[mach_sem] fail semaphore_create");
            shm_.release();
            data_ = nullptr;
            return false;
        }
        return valid();
    }

    void close() noexcept {
        if (!name_.empty()) {
            mach_sem_detail::release(name_);
            sem_ = MACH_PORT_NULL;
        }
        if (shm_.name() != nullptr) shm_.release();
        data_ = nullptr;
        name_.clear();
    }

    void clear() noexcept {
        if (data_ != nullptr && sem_ != MACH_PORT_NULL) {
            data_->count.store(UINT32_MAX, std::memory_order_release);
            semaphore_signal_all(sem_);
        }
        if (!name_.empty()) {
            mach_sem_detail::release(name_);
            sem_ = MACH_PORT_NULL;
        }
        shm_.clear();
        data_ = nullptr;
        name_.clear();
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
            // Try to decrement count.
            std::uint32_t cur = data_->count.load(std::memory_order_acquire);
            while (cur > 0) {
                if (data_->count.compare_exchange_weak(
                        cur, cur - 1,
                        std::memory_order_acquire,
                        std::memory_order_relaxed))
                    return true;
            }

            // count == 0: sleep.
            kern_return_t kr;
            if (has_deadline) {
                auto now = clock::now();
                if (now >= deadline) return false;
                auto us = std::chrono::duration_cast<std::chrono::microseconds>(
                    deadline - now).count();
                mach_timespec_t ts;
                ts.tv_sec  = static_cast<unsigned>(us / 1'000'000);
                ts.tv_nsec = static_cast<clock_res_t>((us % 1'000'000) * 1000);
                kr = semaphore_timedwait(sem_, ts);
                if (kr == KERN_OPERATION_TIMED_OUT) return false;
            } else {
                kr = semaphore_wait(sem_);
            }
            // KERN_ABORTED = interrupted — retry.
        }
    }

    bool post(std::uint32_t count) noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;
        for (std::uint32_t i = 0; i < count; ++i) {
            data_->count.fetch_add(1, std::memory_order_release);
            semaphore_signal(sem_);
        }
        return true;
    }
};

} // namespace sync
} // namespace detail
} // namespace ipc
