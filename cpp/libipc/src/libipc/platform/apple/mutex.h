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
#include <vector>

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
        // Nodes are heap-allocated and referenced by pointer so that a live
        // node can be *moved* out of the by-name map into `orphans` (see
        // clear_storage) without being destroyed while open handles still hold
        // raw pointers into it. std::map is node-based, but the value here is a
        // shm_data*, so orphaning is a pointer move + erase, not a copy.
        ipc::map<std::string, shm_data *> mutex_handles;
        // Nodes cleared via clear_storage() while still in use in-process.
        // Each keeps its intact mapping + ref counter until its last local
        // handle closes; drained in destroy_node().
        std::vector<shm_data *> orphans;
        spin_lock lock;

        static curr_prog &get() {
            static curr_prog info;
            return info;
        }

        ~curr_prog() {
            // Restore the exit-time cleanup that ~map<string, shm_data> used to
            // provide (munmap + shm_unlink of the last owner). Safe now that the
            // central allocator is immortalized: ~shm_data -> shm::release ->
            // mem::$delete never touches a destroyed allocator. See
            // central_cache_allocator() for that teardown rationale.
            for (auto &kv : mutex_handles) delete kv.second;
            for (auto *p : orphans) delete p;
        }
    };

    // The node this handle acquired. Used to release by identity (not by name):
    // after clear_storage() orphans a node, a fresh open(name) creates a *new*
    // node under the same name, so a name-keyed release would corrupt the wrong
    // node's ref count. See RFC: refcount-aware-clear-storage.
    curr_prog::shm_data *node_ = nullptr;

    ulock_mutex_t *acquire_mutex(char const *name) {
        if (name == nullptr) return nullptr;
        auto &info = curr_prog::get();
        LIBIPC_UNUSED std::lock_guard<spin_lock> guard {info.lock};
        auto it = info.mutex_handles.find(name);
        curr_prog::shm_data *node = nullptr;
        if (it == info.mutex_handles.end()) {
            node = new curr_prog::shm_data(
                curr_prog::shm_data::init{name, sizeof(ulock_mutex_t)});
            info.mutex_handles.emplace(name, node);
        } else {
            node = it->second;
        }
        node_ = node;
        shm_  = &node->shm;
        ref_  = &node->ref;
        return static_cast<ulock_mutex_t *>(shm_->get());
    }

    // Remove `node` from whichever container currently owns it (the by-name map
    // or the orphan list), by address, and destroy it. Must hold info.lock.
    static void destroy_node(curr_prog &info, curr_prog::shm_data *node) noexcept {
        for (auto it = info.mutex_handles.begin(); it != info.mutex_handles.end(); ++it) {
            if (it->second == node) {
                info.mutex_handles.erase(it);
                delete node;
                return;
            }
        }
        for (auto it = info.orphans.begin(); it != info.orphans.end(); ++it) {
            if (*it == node) {
                info.orphans.erase(it);
                delete node;
                return;
            }
        }
        // Not found: already removed by a concurrent path. Do not double-free.
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
        if ((ref_ != nullptr) && (shm_ != nullptr) && (data_ != nullptr) && (node_ != nullptr)) {
            if (shm_->name() != nullptr) {
                auto &info = curr_prog::get();
                LIBIPC_UNUSED std::lock_guard<spin_lock> guard {info.lock};
                auto self_ref = ref_->fetch_sub(1, std::memory_order_relaxed);
                if ((shm_->ref() <= 1) && (self_ref <= 1)) {
                    // Last user: reset state and wake any stuck waiters, then
                    // free the node (works whether it lives in the by-name map
                    // or the orphan list).
                    data_->state.store(0, std::memory_order_release);
                    data_->holder.store(0, std::memory_order_release);
                    ::__ulock_wake(UL_COMPARE_AND_WAIT_SHARED | ULF_WAKE_ALL,
                                   &data_->state, 0);
                    destroy_node(info, node_);
                }
            } else shm_->release();
        }
        shm_  = nullptr;
        ref_  = nullptr;
        data_ = nullptr;
        node_ = nullptr;
    }

    void clear() noexcept {
        LIBIPC_LOG();
        if ((shm_ != nullptr) && (data_ != nullptr) && (node_ != nullptr)) {
            if (shm_->name() != nullptr) {
                auto &info = curr_prog::get();
                LIBIPC_UNUSED std::lock_guard<spin_lock> guard {info.lock};
                data_->state.store(0, std::memory_order_release);
                data_->holder.store(0, std::memory_order_release);
                ::__ulock_wake(UL_COMPARE_AND_WAIT_SHARED | ULF_WAKE_ALL,
                               &data_->state, 0);
                shm_->clear();
                destroy_node(info, node_);
            } else shm_->clear();
        }
        shm_  = nullptr;
        ref_  = nullptr;
        data_ = nullptr;
        node_ = nullptr;
    }

    // Ref-count-aware: if any handle in this process still holds `name` open,
    // orphan the node (keep its intact mapping + ref counter alive for those
    // handles) instead of destroying it; a subsequent open(name) then creates a
    // fresh node, exactly as a new opener in another process would. The global
    // name is always unlinked. See RFC: refcount-aware-clear-storage.
    static void clear_storage(char const *name) noexcept {
        LIBIPC_LOG();
        if (name == nullptr) return;
        {
            auto &info = curr_prog::get();
            LIBIPC_UNUSED std::lock_guard<spin_lock> guard {info.lock};
            auto it = info.mutex_handles.find(name);
            if (it != info.mutex_handles.end()) {
                auto *node = it->second;
                auto live = node->ref.load(std::memory_order_acquire);
                if (live > 0) {
                    log.warning("clear_storage('", name, "') with ", live,
                                " handle(s) still open in-process; orphaning the "
                                "segment (live handles keep a private stale mapping).");
                    info.orphans.push_back(node);
                    info.mutex_handles.erase(it);
                } else {
                    info.mutex_handles.erase(it);
                    delete node;
                }
            }
        }
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
