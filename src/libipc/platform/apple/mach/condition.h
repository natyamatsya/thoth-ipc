// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

// Mach semaphore-based condition variable for macOS (App Store safe).
//
// Uses a sequence counter in shared memory (same as the ulock backend) plus
// a process-local Mach semaphore for blocking. The semaphore is signalled by
// notify/broadcast; wait sleeps on it after releasing the mutex.
//
// Because Mach semaphores are process-local, each process maintains its own
// semaphore for each named condition. Cross-process wakeup is achieved by
// incrementing the shared sequence counter and then signalling the local
// semaphore — which works because each process's waiter is sleeping on its
// own semaphore and will re-check the sequence counter on wakeup.
//
// For broadcast, we signal the semaphore N times (once per known local waiter).
// This is conservative: spurious wakeups are allowed by the condition API.

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
#include "libipc/mutex.h"
#include "libipc/def.h"

namespace ipc {
namespace detail {
namespace sync {

struct mach_cond_t {
    std::atomic<std::uint32_t> seq     {0};
    std::atomic<std::int32_t>  waiters {0};
};

namespace mach_cond_detail {

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

} // namespace mach_cond_detail

class condition {
    ipc::shm::handle  shm_;
    mach_cond_t      *cond_ = nullptr;
    semaphore_t       sem_  = MACH_PORT_NULL;
    std::string       name_;

public:
    condition() = default;
    ~condition() = default;

    void const *native() const noexcept { return cond_; }
    void       *native()       noexcept { return cond_; }

    bool valid() const noexcept {
        return cond_ != nullptr && sem_ != MACH_PORT_NULL;
    }

    bool open(char const *name) noexcept {
        LIBIPC_LOG();
        close();
        name_ = name ? name : "";
        if (!shm_.acquire(name, sizeof(mach_cond_t))) {
            log.error("[mach_cond] fail shm.acquire: ", name);
            return false;
        }
        cond_ = static_cast<mach_cond_t *>(shm_.get());
        if (shm_.ref() <= 1) {
            cond_->seq.store(0, std::memory_order_release);
            cond_->waiters.store(0, std::memory_order_release);
        }
        sem_ = mach_cond_detail::acquire(name_);
        if (sem_ == MACH_PORT_NULL) {
            log.error("[mach_cond] fail semaphore_create");
            shm_.release();
            cond_ = nullptr;
            return false;
        }
        return valid();
    }

    void close() noexcept {
        if (!name_.empty()) {
            mach_cond_detail::release(name_);
            sem_ = MACH_PORT_NULL;
        }
        if (shm_.name() != nullptr) shm_.release();
        cond_ = nullptr;
        name_.clear();
    }

    void clear() noexcept {
        if (cond_ != nullptr && sem_ != MACH_PORT_NULL) {
            cond_->seq.fetch_add(1, std::memory_order_acq_rel);
            std::int32_t w = cond_->waiters.load(std::memory_order_acquire);
            for (std::int32_t i = 0; i < w; ++i)
                semaphore_signal(sem_);
        }
        if (!name_.empty()) {
            mach_cond_detail::release(name_);
            sem_ = MACH_PORT_NULL;
        }
        shm_.clear();
        cond_ = nullptr;
        name_.clear();
    }

    static void clear_storage(char const *name) noexcept {
        ipc::shm::handle::clear_storage(name);
    }

    bool wait(ipc::sync::mutex &mtx, std::uint64_t tm) noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;

        // Snapshot the sequence counter while holding the mutex.
        std::uint32_t seq = cond_->seq.load(std::memory_order_acquire);
        cond_->waiters.fetch_add(1, std::memory_order_relaxed);

        mtx.unlock();

        bool notified = false;
        using clock = std::chrono::steady_clock;
        bool has_deadline = (tm != invalid_value);
        clock::time_point deadline{};
        if (has_deadline)
            deadline = clock::now() + std::chrono::milliseconds(tm);

        for (;;) {
            // Check if seq changed (notified).
            if (cond_->seq.load(std::memory_order_acquire) != seq) {
                notified = true;
                break;
            }

            kern_return_t kr;
            if (has_deadline) {
                auto now = clock::now();
                if (now >= deadline) break;
                auto us = std::chrono::duration_cast<std::chrono::microseconds>(
                    deadline - now).count();
                mach_timespec_t ts;
                ts.tv_sec  = static_cast<unsigned>(us / 1'000'000);
                ts.tv_nsec = static_cast<clock_res_t>((us % 1'000'000) * 1000);
                kr = semaphore_timedwait(sem_, ts);
                if (kr == KERN_OPERATION_TIMED_OUT) break;
            } else {
                kr = semaphore_wait(sem_);
            }
            // KERN_ABORTED = interrupted, loop and recheck.
        }

        cond_->waiters.fetch_sub(1, std::memory_order_relaxed);
        mtx.lock(ipc::invalid_value);
        return notified;
    }

    bool notify(ipc::sync::mutex &) noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;
        cond_->seq.fetch_add(1, std::memory_order_acq_rel);
        if (cond_->waiters.load(std::memory_order_acquire) > 0)
            semaphore_signal(sem_);
        return true;
    }

    bool broadcast(ipc::sync::mutex &) noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;
        cond_->seq.fetch_add(1, std::memory_order_acq_rel);
        if (cond_->waiters.load(std::memory_order_acquire) > 0)
            semaphore_signal_all(sem_);
        return true;
    }
};

} // namespace sync
} // namespace detail
} // namespace ipc
