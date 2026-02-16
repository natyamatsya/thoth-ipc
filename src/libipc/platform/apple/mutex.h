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

#include <pthread.h>
#include <unistd.h>
#include <signal.h>

#include "libipc/platform/detail.h"
#include "libipc/imp/log.h"
#include "libipc/utility/scope_guard.h"
#include "libipc/mem/resource.h"
#include "libipc/shm.h"

#include "libipc/platform/posix/get_wait_time.h"
#include "libipc/platform/apple/spin_lock.h"

namespace ipc {
namespace detail {
namespace sync {

// Shared memory layout for the macOS robust mutex emulation.
// The holder PID is stored alongside the mutex so that other processes
// can detect a dead holder and reinitialize the mutex.
struct robust_mutex_t {
    pthread_mutex_t     mtx;
    std::atomic<pid_t>  holder; // 0 = unlocked
};

class mutex {
    ipc::shm::handle *shm_ = nullptr;
    std::atomic<std::int32_t> *ref_ = nullptr;
    robust_mutex_t *data_ = nullptr;

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

    robust_mutex_t *acquire_mutex(char const *name) {
        if (name == nullptr) return nullptr;
        auto &info = curr_prog::get();
        LIBIPC_UNUSED std::lock_guard<spin_lock> guard {info.lock};
        auto it = info.mutex_handles.find(name);
        if (it == info.mutex_handles.end()) {
          it = info.mutex_handles
                   .emplace(std::piecewise_construct,
                            std::forward_as_tuple(name),
                            std::forward_as_tuple(curr_prog::shm_data::init{
                                name, sizeof(robust_mutex_t)}))
                   .first;
        }
        shm_ = &it->second.shm;
        ref_ = &it->second.ref;
        if (shm_ == nullptr) return nullptr;
        return static_cast<robust_mutex_t *>(shm_->get());
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

    static pthread_mutex_t const &zero_mem() {
        static const pthread_mutex_t tmp{};
        return tmp;
    }

    // Check if a PID is alive. Returns false if the process does not exist.
    static bool is_process_alive(pid_t pid) noexcept {
        if (pid <= 0) return false;
        return (::kill(pid, 0) == 0) || (errno != ESRCH);
    }

    // Attempt to recover a mutex whose holder has died.
    // Returns true if recovery succeeded (mutex was reinitialized).
    bool try_recover_dead_holder() noexcept {
        LIBIPC_LOG();
        if (data_ == nullptr) return false;
        pid_t holder = data_->holder.load(std::memory_order_acquire);
        if (holder == 0) return false; // not held
        if (is_process_alive(holder)) return false; // holder is still alive

        log.debug("dead holder detected (pid=", holder, "), recovering mutex");

        // Reinitialize: destroy + init. This is safe because the holder is dead
        // and cannot be inside a critical section.
        ::pthread_mutex_destroy(&data_->mtx);
        data_->holder.store(0, std::memory_order_release);

        pthread_mutexattr_t attr;
        if (::pthread_mutexattr_init(&attr) != 0) return false;
        LIBIPC_UNUSED auto g = ipc::guard([&attr] { ::pthread_mutexattr_destroy(&attr); });
        if (::pthread_mutexattr_setpshared(&attr, PTHREAD_PROCESS_SHARED) != 0) return false;
        data_->mtx = PTHREAD_MUTEX_INITIALIZER;
        if (::pthread_mutex_init(&data_->mtx, &attr) != 0) return false;
        return true;
    }

public:
    mutex() = default;
    ~mutex() = default;

    static void init() {
        zero_mem();
        curr_prog::get();
    }

    pthread_mutex_t const *native() const noexcept {
        return data_ ? &data_->mtx : nullptr;
    }

    pthread_mutex_t *native() noexcept {
        return data_ ? &data_->mtx : nullptr;
    }

    bool valid() const noexcept {
        return (shm_ != nullptr) && (ref_ != nullptr) && (data_ != nullptr)
            && (std::memcmp(&zero_mem(), &data_->mtx, sizeof(pthread_mutex_t)) != 0);
    }

    bool open(char const *name) noexcept {
        LIBIPC_LOG();
        close();
        if ((data_ = acquire_mutex(name)) == nullptr) return false;
        auto self_ref = ref_->fetch_add(1, std::memory_order_relaxed);
        if (shm_->ref() > 1 || self_ref > 0) return valid();
        ::pthread_mutex_destroy(&data_->mtx);
        auto finally = ipc::guard([this] { close(); });
        int eno;
        pthread_mutexattr_t mutex_attr;
        if ((eno = ::pthread_mutexattr_init(&mutex_attr)) != 0) {
            log.error("fail pthread_mutexattr_init[", eno, "]");
            return false;
        }
        LIBIPC_UNUSED auto guard_mutex_attr = guard([&mutex_attr] { ::pthread_mutexattr_destroy(&mutex_attr); });
        if ((eno = ::pthread_mutexattr_setpshared(&mutex_attr, PTHREAD_PROCESS_SHARED)) != 0) {
            log.error("fail pthread_mutexattr_setpshared[", eno, "]");
            return false;
        }
        // macOS lacks pthread_mutexattr_setrobust — emulate via PID liveness check
        data_->mtx = PTHREAD_MUTEX_INITIALIZER;
        data_->holder.store(0, std::memory_order_release);
        if ((eno = ::pthread_mutex_init(&data_->mtx, &mutex_attr)) != 0) {
            log.error("fail pthread_mutex_init[", eno, "]");
            return false;
        }
        finally.dismiss();
        return valid();
    }

    void close() noexcept {
        LIBIPC_LOG();
        if ((ref_ != nullptr) && (shm_ != nullptr) && (data_ != nullptr)) {
            if (shm_->name() != nullptr) {
                release_mutex(shm_->name(), [this, &log] {
                    auto self_ref = ref_->fetch_sub(1, std::memory_order_relaxed);
                    if ((shm_->ref() <= 1) && (self_ref <= 1)) {
                        ::pthread_mutex_unlock(&data_->mtx);
                        data_->holder.store(0, std::memory_order_release);
                        int eno;
                        if ((eno = ::pthread_mutex_destroy(&data_->mtx)) != 0)
                            log.error("fail pthread_mutex_destroy[", eno, "]");
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
                release_mutex(shm_->name(), [this, &log] {
                    ::pthread_mutex_unlock(&data_->mtx);
                    data_->holder.store(0, std::memory_order_release);
                    int eno;
                    if ((eno = ::pthread_mutex_destroy(&data_->mtx)) != 0)
                        log.error("fail pthread_mutex_destroy[", eno, "]");
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

    // macOS lacks pthread_mutex_timedlock — emulate with adaptive polling.
    // Also emulates robust mutex behavior via PID liveness checking.
    bool lock(std::uint64_t tm) noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;
        if (tm == invalid_value) {
            int eno = ::pthread_mutex_lock(&data_->mtx);
            if (eno != 0) {
                log.error("fail pthread_mutex_lock[", eno, "]");
                return false;
            }
            data_->holder.store(::getpid(), std::memory_order_release);
            return true;
        }
        // Adaptive timed lock: spin → escalating sleep
        using clock = std::chrono::steady_clock;
        auto deadline = clock::now() + std::chrono::milliseconds(tm);
        // Phase 1: spin (no sleep) — ~1000 iterations for low-latency acquire
        for (int i = 0; i < 1000; ++i) {
            int eno = ::pthread_mutex_trylock(&data_->mtx);
            if (eno == 0) {
                data_->holder.store(::getpid(), std::memory_order_release);
                return true;
            }
            if (eno != EBUSY) {
                log.error("fail pthread_mutex_trylock[", eno, "]");
                return false;
            }
        }
        // Phase 2: escalating sleep — 1µs → 10µs → 100µs → 1ms
        static constexpr std::chrono::microseconds sleep_steps[] = {
            std::chrono::microseconds(1),
            std::chrono::microseconds(10),
            std::chrono::microseconds(100),
            std::chrono::microseconds(1000),
        };
        constexpr int n_steps = sizeof(sleep_steps) / sizeof(sleep_steps[0]);
        int step = 0;
        int iters_at_step = 0;
        bool tried_recovery = false;
        for (;;) {
            int eno = ::pthread_mutex_trylock(&data_->mtx);
            if (eno == 0) {
                data_->holder.store(::getpid(), std::memory_order_release);
                return true;
            }
            if (eno != EBUSY) {
                log.error("fail pthread_mutex_trylock[", eno, "]");
                return false;
            }
            if (clock::now() >= deadline) {
                // Before giving up, try to recover from a dead holder (once).
                if (!tried_recovery) {
                    tried_recovery = true;
                    if (try_recover_dead_holder()) continue; // retry after recovery
                }
                return false;
            }
            std::this_thread::sleep_for(sleep_steps[step]);
            if (++iters_at_step >= 100 && step < n_steps - 1) {
                ++step;
                iters_at_step = 0;
            }
        }
    }

    bool try_lock() noexcept(false) {
        LIBIPC_LOG();
        if (!valid()) return false;
        int eno = ::pthread_mutex_trylock(&data_->mtx);
        if (eno == 0) {
            data_->holder.store(::getpid(), std::memory_order_release);
            return true;
        }
        if (eno == EBUSY) {
            // Check for dead holder on contention
            if (try_recover_dead_holder()) {
                eno = ::pthread_mutex_trylock(&data_->mtx);
                if (eno == 0) {
                    data_->holder.store(::getpid(), std::memory_order_release);
                    return true;
                }
            }
            return false;
        }
        log.error("fail pthread_mutex_trylock[", eno, "]");
        throw std::system_error{eno, std::system_category()};
    }

    bool unlock() noexcept {
        LIBIPC_LOG();
        if (!valid()) return false;
        data_->holder.store(0, std::memory_order_release);
        int eno;
        if ((eno = ::pthread_mutex_unlock(&data_->mtx)) != 0) {
            log.error("fail pthread_mutex_unlock[", eno, "]");
            return false;
        }
        return true;
    }
};

} // namespace sync
} // namespace detail
} // namespace ipc
