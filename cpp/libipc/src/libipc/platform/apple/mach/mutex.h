// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

// Mach semaphore-based mutex for macOS (App Store safe).
//
// Uses only public Mach APIs: semaphore_create / semaphore_wait /
// semaphore_timedwait / semaphore_signal / semaphore_destroy.
//
// Algorithm: word-lock with a per-mutex Mach semaphore stored in a
// process-local table (keyed by shm name). The shared state word lives in
// shared memory; the Mach semaphore is process-local (Mach ports are not
// sharable across processes directly).
//
// State encoding (same as ulock backend):
//   0 = unlocked
//   1 = locked, no waiters
//   2 = locked, waiters present

#include <cstdint>
#include <atomic>
#include <chrono>
#include <string>
#include <unordered_map>
#include <mutex>

#include <mach/mach.h>
#include <mach/semaphore.h>
#include <mach/task.h>
#include <sys/types.h>
#include <unistd.h>
#include <signal.h>

#include "libipc/imp/log.h"
#include "libipc/shm.h"
#include "libipc/def.h"

namespace ipc {
namespace detail {
namespace sync {

struct mach_mutex_state_t {
    std::atomic<std::uint32_t> state  {0};
    std::atomic<pid_t>         holder {0};
};

// Process-local table mapping shm name → Mach semaphore.
// Mach semaphores are process-local; we create one per named mutex per process.
namespace mach_mutex_detail {

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

} // namespace mach_mutex_detail

class mutex {
    ipc::shm::handle      shm_;
    std::atomic<int>     *ref_  = nullptr;
    mach_mutex_state_t   *data_ = nullptr;
    semaphore_t           sem_  = MACH_PORT_NULL;
    std::string           name_;

    static constexpr int kSpinCount = 40;

    static bool is_process_alive(pid_t pid) noexcept {
        if (pid <= 0) return false;
        return ::kill(pid, 0) == 0 || errno == EPERM;
    }

    bool try_lock_once() noexcept {
        std::uint32_t expected = 0;
        return data_->state.compare_exchange_strong(
            expected, 1, std::memory_order_acquire, std::memory_order_relaxed);
    }

    bool try_lock_contended() noexcept {
        std::uint32_t expected = 0;
        return data_->state.compare_exchange_strong(
            expected, 2, std::memory_order_acquire, std::memory_order_relaxed);
    }

    bool try_recover_dead_holder() noexcept {
        pid_t holder = data_->holder.load(std::memory_order_acquire);
        if (holder == 0 || is_process_alive(holder)) return false;
        std::uint32_t s = data_->state.load(std::memory_order_acquire);
        if (s == 0) return false;
        // Force-reset: dead holder, reclaim.
        data_->state.store(0, std::memory_order_release);
        data_->holder.store(0, std::memory_order_release);
        return true;
    }

public:
    mutex() = default;
    ~mutex() = default;

    static void init() {}

    mach_mutex_state_t const *native() const noexcept { return data_; }
    mach_mutex_state_t       *native()       noexcept { return data_; }

    bool valid() const noexcept {
        return data_ != nullptr && sem_ != MACH_PORT_NULL;
    }

    bool open(char const *name) noexcept {
        LIBIPC_LOG();
        close();
        name_ = name ? name : "";
        if (!shm_.acquire(name, sizeof(mach_mutex_state_t) + sizeof(std::atomic<int>))) {
            log.error("[mach_mutex] fail shm.acquire: ", name);
            return false;
        }
        auto *base = static_cast<char *>(shm_.get());
        data_ = reinterpret_cast<mach_mutex_state_t *>(base);
        ref_  = reinterpret_cast<std::atomic<int> *>(
                    base + sizeof(mach_mutex_state_t));
        if (shm_.ref() <= 1) {
            data_->state.store(0, std::memory_order_release);
            data_->holder.store(0, std::memory_order_release);
            ref_->store(0, std::memory_order_release);
        }
        ref_->fetch_add(1, std::memory_order_relaxed);
        sem_ = mach_mutex_detail::acquire(name_);
        if (sem_ == MACH_PORT_NULL) {
            log.error("[mach_mutex] fail semaphore_create");
            shm_.release();
            data_ = nullptr;
            return false;
        }
        return valid();
    }

    void close() noexcept {
        if (!name_.empty()) {
            mach_mutex_detail::release(name_);
            sem_ = MACH_PORT_NULL;
        }
        if (shm_.name() != nullptr) shm_.release();
        data_ = nullptr;
        ref_  = nullptr;
        name_.clear();
    }

    void clear() noexcept {
        if (data_ != nullptr) {
            data_->state.store(0, std::memory_order_release);
            data_->holder.store(0, std::memory_order_release);
            if (sem_ != MACH_PORT_NULL)
                semaphore_signal_all(sem_);
        }
        if (!name_.empty()) {
            mach_mutex_detail::release(name_);
            sem_ = MACH_PORT_NULL;
        }
        shm_.clear();
        data_ = nullptr;
        ref_  = nullptr;
        name_.clear();
    }

    static void clear_storage(char const *name) noexcept {
        ipc::shm::handle::clear_storage(name);
    }

    bool lock(std::uint64_t tm) noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;

        using clock = std::chrono::steady_clock;
        bool has_deadline = (tm != invalid_value);
        clock::time_point deadline{};
        if (has_deadline)
            deadline = clock::now() + std::chrono::milliseconds(tm);

        bool tried_recovery = false;
        bool contended = false;

        for (;;) {
            for (int i = 0; i < kSpinCount; ++i) {
                bool got = contended ? try_lock_contended() : try_lock_once();
                if (got) {
                    data_->holder.store(::getpid(), std::memory_order_release);
                    return true;
                }
            }

            // Transition to "waiters present".
            std::uint32_t s = data_->state.load(std::memory_order_relaxed);
            if (s == 0) continue;
            if (s == 1) {
                if (!data_->state.compare_exchange_strong(
                        s, 2, std::memory_order_relaxed, std::memory_order_relaxed))
                    continue;
            }

            // Sleep on the Mach semaphore.
            kern_return_t kr;
            if (has_deadline) {
                auto now = clock::now();
                if (now >= deadline) {
                    if (!tried_recovery) {
                        tried_recovery = true;
                        if (try_recover_dead_holder()) continue;
                    }
                    return false;
                }
                auto us = std::chrono::duration_cast<std::chrono::microseconds>(
                    deadline - now).count();
                mach_timespec_t ts;
                ts.tv_sec  = static_cast<unsigned>(us / 1'000'000);
                ts.tv_nsec = static_cast<clock_res_t>((us % 1'000'000) * 1000);
                kr = semaphore_timedwait(sem_, ts);
            } else {
                kr = semaphore_wait(sem_);
            }

            contended = true;

            if (kr == KERN_OPERATION_TIMED_OUT) {
                if (!tried_recovery) {
                    tried_recovery = true;
                    if (try_recover_dead_holder()) continue;
                }
                return false;
            }
            // KERN_SUCCESS or KERN_ABORTED (interrupted) — retry.
        }
    }

    bool try_lock() noexcept(false) {
        if (!valid()) return false;
        if (try_lock_once()) {
            data_->holder.store(::getpid(), std::memory_order_release);
            return true;
        }
        if (try_recover_dead_holder()) {
            if (try_lock_once()) {
                data_->holder.store(::getpid(), std::memory_order_release);
                return true;
            }
        }
        return false;
    }

    bool unlock() noexcept {
        if (!valid()) return false;
        data_->holder.store(0, std::memory_order_release);
        std::uint32_t prev = data_->state.exchange(0, std::memory_order_release);
        if (prev == 2)
            semaphore_signal(sem_);
        return true;
    }
};

} // namespace sync
} // namespace detail
} // namespace ipc
