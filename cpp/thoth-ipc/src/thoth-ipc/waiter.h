#pragma once

#include <utility>
#include <string>
#include <mutex>
#include <atomic>

#include "thoth-ipc/def.h"
#include "thoth-ipc/mutex.h"
#include "thoth-ipc/condition.h"
#include "thoth-ipc/platform/detail.h"

namespace thoth {
namespace detail {

class waiter {
    thoth::sync::condition  cond_;
    thoth::sync::mutex      lock_;
    std::atomic<bool>     quit_ {false};

public:
    static void init();

    waiter() = default;
    waiter(char const *name) {
        open(name);
    }

    ~waiter() {
        close();
    }

    bool valid() const noexcept {
        return cond_.valid() && lock_.valid();
    }

    bool open(char const *name) noexcept {
        quit_.store(false, std::memory_order_relaxed);
        if (!cond_.open((std::string{name} + "_WAITER_COND_").c_str())) {
            return false;
        }
        if (!lock_.open((std::string{name} + "_WAITER_LOCK_").c_str())) {
            cond_.close();
            return false;
        }
        return valid();
    }

    void close() noexcept {
        cond_.close();
        lock_.close();
    }

    void clear() noexcept {
        cond_.clear();
        lock_.clear();
    }

    static void clear_storage(char const *name) noexcept {
        thoth::sync::condition::clear_storage((std::string{name} + "_WAITER_COND_").c_str());
        thoth::sync::mutex::clear_storage((std::string{name} + "_WAITER_LOCK_").c_str());
    }

    template <typename F>
    bool wait_if(F &&pred, std::uint64_t tm = thoth::invalid_value) noexcept {
        // Fast path: if the predicate is already false, there is nothing to wait
        // for, so skip the lock.
        if (quit_.load(std::memory_order_relaxed) || !pred()) return true;
        THOTH_IPC_UNUSED std::lock_guard<thoth::sync::mutex> guard {lock_};
        while ([this, &pred] {
                    return !quit_.load(std::memory_order_relaxed)
                        && std::forward<F>(pred)();
                }()) {
            if (!cond_.wait(lock_, tm)) return false;
        }
        return true;
    }

    // A closed or cleared waiter has no one to wake: route teardown runs
    // disconnect (and so quit_waiting) again after clear().
    //
    // A wake first takes the lock once (a barrier). Whoever wakes changed the
    // state the predicate reads without holding the lock, and a waiter holds it
    // from its predicate check until its condition has taken the sequence number
    // it sleeps on. Without the barrier a wake landing in between bumps the
    // sequence before the waiter reads it, and the waiter sleeps out its whole
    // timeout on a state that already let it go: the condition's sequence
    // number only catches wakes that come after it was read.
    bool notify() noexcept {
        if (!valid()) return false;
        barrier();
        return cond_.notify(lock_);
    }

    bool broadcast() noexcept {
        if (!valid()) return false;
        barrier();
        return cond_.broadcast(lock_);
    }

    bool quit_waiting() {
        quit_.store(true, std::memory_order_release);
        return broadcast();
    }

private:
    void barrier() noexcept {
        THOTH_IPC_UNUSED std::lock_guard<thoth::sync::mutex> guard {lock_};
    }
};

} // namespace detail
} // namespace thoth
