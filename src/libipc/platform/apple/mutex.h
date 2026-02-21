// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <cstring>
#include <cassert>
#include <cstdint>
#include <system_error>
#include <atomic>
#include <chrono>
#include <thread>

#include <unistd.h>
#include <signal.h>
#include <errno.h>

#include "libipc/platform/detail.h"
#include "libipc/imp/log.h"
#include "libipc/utility/scope_guard.h"
#include "libipc/mem/resource.h"
#include "libipc/shm.h"

#include "libipc/platform/apple/spin_lock.h"
#include "libipc/platform/apple/ulock.h"

namespace ipc {
namespace detail {
namespace sync {

// Shared memory layout for the macOS ulock-based mutex.
//
// State encoding (32-bit word, used as the ulock address):
//   0  — UNLOCKED
//   1  — LOCKED, no waiters
//   2  — LOCKED, one or more waiters sleeping in __ulock_wait
//
// holder stores the PID of the current lock owner so that other processes
// can detect a dead holder and reset the mutex.
struct ulock_mutex_t {
    std::atomic<std::uint32_t> state;  // 0=unlocked, 1=locked, 2=locked+waiters
    std::atomic<pid_t>         holder; // 0 = no holder
};

// Spin budget before falling back to __ulock_wait.
static constexpr int kMutexSpinCount = 40;

class mutex {
    ipc::shm::handle *shm_ = nullptr;
    std::atomic<std::int32_t> *ref_ = nullptr;
    ulock_mutex_t *data_ = nullptr;

    struct curr_prog {
        struct shm_data {
            ipc::shm::handle shm;
            std::atomic<std::int32_t> ref;

            struct init {
                char const *name;
                std::size_t size;
            };
            shm_data(init arg)
                : shm{arg.name, arg.size}, ref{0} {}
        };
        ipc::map<std::string, shm_data> mutex_handles;
        spin_lock lock;

        static curr_prog &get() {
            static curr_prog info;
            return info;
        }
    };

    ulock_mutex_t *acquire_mutex(char const *name) {
        if (name == nullptr) return nullptr;
        auto &info = curr_prog::get();
        LIBIPC_UNUSED std::lock_guard<spin_lock> guard {info.lock};
        auto it = info.mutex_handles.find(name);
        if (it == info.mutex_handles.end()) {
            it = info.mutex_handles
                     .emplace(std::piecewise_construct,
                              std::forward_as_tuple(name),
                              std::forward_as_tuple(curr_prog::shm_data::init{
                                  name, sizeof(ulock_mutex_t)}))
                     .first;
        }
        shm_ = &it->second.shm;
        ref_ = &it->second.ref;
        if (shm_ == nullptr) return nullptr;
        return static_cast<ulock_mutex_t *>(shm_->get());
    }

    template <typename F>
    static void release_mutex(std::string const &name, F &&clear) {
        if (name.empty()) return;
        auto &info = curr_prog::get();
        LIBIPC_UNUSED std::lock_guard<spin_lock> guard {info.lock};
        auto it = info.mutex_handles.find(name);
        if (it == info.mutex_handles.end()) return;
        if (clear())
            info.mutex_handles.erase(it);
    }

    // Check if a PID is alive. Returns false if the process does not exist.
    static bool is_process_alive(pid_t pid) noexcept {
        if (pid <= 0) return false;
        return (::kill(pid, 0) == 0) || (errno != ESRCH);
    }

    // Attempt to recover a mutex whose holder has died.
    // Returns true if recovery succeeded (state was reset to UNLOCKED).
    bool try_recover_dead_holder() noexcept {
        LIBIPC_LOG();
        if (data_ == nullptr) return false;
        pid_t holder = data_->holder.load(std::memory_order_acquire);
        if (holder == 0) return false; // not held
        if (is_process_alive(holder)) return false; // holder is still alive

        log.debug("dead holder detected (pid=", holder, "), recovering mutex");

        // Reset state to UNLOCKED. If there were waiters, wake them all so
        // they can re-compete for the lock.
        std::uint32_t old = data_->state.exchange(0, std::memory_order_acq_rel);
        data_->holder.store(0, std::memory_order_release);
        if (old == 2) {
            // Wake all waiters so they can observe the unlocked state.
            ::__ulock_wake(UL_COMPARE_AND_WAIT_SHARED | ULF_WAKE_ALL,
                           &data_->state, 0);
        }
        return true;
    }

    // Uncontended try-lock: CAS 0→1. Returns true on success.
    bool try_lock_once() noexcept {
        std::uint32_t expected = 0;
        return data_->state.compare_exchange_strong(
            expected, 1,
            std::memory_order_acquire,
            std::memory_order_relaxed);
    }

    // Contended try-lock (used after waking from __ulock_wait): CAS 0→2.
    // Using 2 instead of 1 preserves the "waiters may be present" signal so
    // that unlock() will always call __ulock_wake when there are other sleepers.
    bool try_lock_contended() noexcept {
        std::uint32_t expected = 0;
        return data_->state.compare_exchange_strong(
            expected, 2,
            std::memory_order_acquire,
            std::memory_order_relaxed);
    }

    // Block until state != current_val, with optional timeout (µs, 0 = infinite).
    // Returns false on timeout.
    bool ulock_wait(std::uint32_t current_val, std::uint32_t timeout_us) noexcept {
        int ret = ::__ulock_wait(UL_COMPARE_AND_WAIT_SHARED,
                                 &data_->state,
                                 static_cast<std::uint64_t>(current_val),
                                 timeout_us);
        if (ret >= 0) return true;
        int err = errno;
        // ETIMEDOUT → timed out, EINTR → spurious wakeup (treat as success to retry)
        return (err == EINTR);
    }

    // Wake one waiter.
    void ulock_wake_one() noexcept {
        ::__ulock_wake(UL_COMPARE_AND_WAIT_SHARED, &data_->state, 0);
    }

public:
    mutex() = default;
    ~mutex() = default;

    static void init() {
        curr_prog::get();
    }

    ulock_mutex_t const *native() const noexcept {
        return data_;
    }

    ulock_mutex_t *native() noexcept {
        return data_;
    }

    bool valid() const noexcept {
        return (shm_ != nullptr) && (ref_ != nullptr) && (data_ != nullptr);
    }

    bool open(char const *name) noexcept {
        LIBIPC_LOG();
        close();
        if ((data_ = acquire_mutex(name)) == nullptr) return false;
        auto self_ref = ref_->fetch_add(1, std::memory_order_relaxed);
        if (shm_->ref() > 1 || self_ref > 0) return valid();
        // First opener: initialize state.
        data_->state.store(0, std::memory_order_release);
        data_->holder.store(0, std::memory_order_release);
        return valid();
    }

    void close() noexcept {
        LIBIPC_LOG();
        if ((ref_ != nullptr) && (shm_ != nullptr) && (data_ != nullptr)) {
            if (shm_->name() != nullptr) {
                release_mutex(shm_->name(), [this] {
                    auto self_ref = ref_->fetch_sub(1, std::memory_order_relaxed);
                    if ((shm_->ref() <= 1) && (self_ref <= 1)) {
                        // Last user: reset state and wake any stuck waiters.
                        data_->state.store(0, std::memory_order_release);
                        data_->holder.store(0, std::memory_order_release);
                        ::__ulock_wake(UL_COMPARE_AND_WAIT_SHARED | ULF_WAKE_ALL,
                                       &data_->state, 0);
                        return true;
                    }
                    return false;
                });
            } else shm_->release();
        }
        shm_  = nullptr;
        ref_  = nullptr;
        data_ = nullptr;
    }

    void clear() noexcept {
        LIBIPC_LOG();
        if ((shm_ != nullptr) && (data_ != nullptr)) {
            if (shm_->name() != nullptr) {
                release_mutex(shm_->name(), [this] {
                    data_->state.store(0, std::memory_order_release);
                    data_->holder.store(0, std::memory_order_release);
                    ::__ulock_wake(UL_COMPARE_AND_WAIT_SHARED | ULF_WAKE_ALL,
                                   &data_->state, 0);
                    shm_->clear();
                    return true;
                });
            } else shm_->clear();
        }
        shm_  = nullptr;
        ref_  = nullptr;
        data_ = nullptr;
    }

    static void clear_storage(char const *name) noexcept {
        if (name == nullptr) return;
        release_mutex(name, [] { return true; });
        ipc::shm::handle::clear_storage(name);
    }

    // Lock with optional timeout (ms). Pass invalid_value for infinite wait.
    //
    // Algorithm (word-lock / "futex mutex"):
    //   1. Spin up to kMutexSpinCount times attempting CAS 0→1.
    //   2. If still not acquired, transition state to 2 (locked+waiters) and
    //      call __ulock_wait. The kernel wakes us when state != 2.
    //   3. On wakeup, retry from step 1.
    bool lock(std::uint64_t tm) noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;

        // Compute deadline for timed waits.
        using clock = std::chrono::steady_clock;
        clock::time_point deadline{};
        bool has_deadline = (tm != invalid_value);
        if (has_deadline)
            deadline = clock::now() + std::chrono::milliseconds(tm);

        bool tried_recovery = false;

        bool contended = false; // true after first sleep — use CAS 0→2 on acquire

        for (;;) {
            // Phase 1: optimistic spin.
            // After sleeping (contended=true) use CAS 0→2 to preserve the
            // "waiters present" signal so unlock() keeps waking sleepers.
            for (int i = 0; i < kMutexSpinCount; ++i) {
                bool got = contended ? try_lock_contended() : try_lock_once();
                if (got) {
                    data_->holder.store(::getpid(), std::memory_order_release);
                    return true;
                }
#if defined(__arm64__) || defined(__aarch64__)
                __asm__ __volatile__("isb sy" ::: "memory");
#else
                __asm__ __volatile__("pause" ::: "memory");
#endif
            }

            // Phase 2: transition to "locked with waiters" and sleep.
            // We must set state to 2 before sleeping so the unlocker knows
            // to call __ulock_wake.
            std::uint32_t s = data_->state.load(std::memory_order_relaxed);
            if (s == 0) {
                // State changed to unlocked between spin and here — retry spin.
                continue;
            }
            if (s == 1) {
                // Announce that we are about to wait.
                if (!data_->state.compare_exchange_strong(
                        s, 2,
                        std::memory_order_relaxed,
                        std::memory_order_relaxed)) {
                    // CAS failed: state changed (either unlocked or already 2).
                    continue;
                }
            }
            // state is now 2 (either we set it or it was already 2).

            // Check deadline before sleeping.
            std::uint32_t timeout_us = 0; // 0 = infinite for __ulock_wait
            if (has_deadline) {
                auto now = clock::now();
                if (now >= deadline) {
                    if (!tried_recovery) {
                        tried_recovery = true;
                        if (try_recover_dead_holder()) continue;
                    }
                    return false;
                }
                auto remaining = std::chrono::duration_cast<std::chrono::microseconds>(
                    deadline - now).count();
                timeout_us = (remaining > 0 && remaining < UINT32_MAX)
                    ? static_cast<std::uint32_t>(remaining) : UINT32_MAX;
            }

            // Sleep until state != 2 (or timeout).
            bool woken = ulock_wait(2, timeout_us);
            contended = true; // from now on, acquire with CAS 0→2
            if (!woken && has_deadline) {
                // Timed out. Try dead-holder recovery once before giving up.
                if (!tried_recovery) {
                    tried_recovery = true;
                    if (try_recover_dead_holder()) continue;
                }
                return false;
            }
            // Woken (or spurious): loop back to spin phase.
        }
    }

    bool try_lock() noexcept(false) {
        LIBIPC_LOG();
        if (!valid()) return false;
        if (try_lock_once()) {
            data_->holder.store(::getpid(), std::memory_order_release);
            return true;
        }
        // Check for dead holder on contention.
        if (try_recover_dead_holder()) {
            if (try_lock_once()) {
                data_->holder.store(::getpid(), std::memory_order_release);
                return true;
            }
        }
        return false;
    }

    bool unlock() noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;
        data_->holder.store(0, std::memory_order_release);
        // Atomically set state to 0. If it was 2 (waiters present), wake one.
        std::uint32_t prev = data_->state.exchange(0, std::memory_order_release);
        if (prev == 2)
            ulock_wake_one();
        return true;
    }
};

} // namespace sync
} // namespace detail
} // namespace ipc
