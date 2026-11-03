// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// thoth::detail::waiter, the condition + mutex pair a channel's writers and
// readers sleep on. Its state lives outside it (the ring), and whoever changes
// that state wakes the waiter without holding the waiter's lock.

#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <string>
#include <thread>

#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#endif

#include "thoth-ipc/waiter.h"

namespace {

int current_pid() {
#ifdef _WIN32
    return ::_getpid();
#else
    return static_cast<int>(::getpid());
#endif
}

std::string unique_waiter_name(char const *what) {
    return "thoth_test_waiter_" + std::to_string(current_pid()) + "_" + what;
}

} // namespace

// The state changes, and the wake comes, while the waiter has checked its
// predicate (and found it still blocked) but has not gone to sleep yet. The
// wake must not be lost: a waiter's condition takes its sequence number only
// once it is about to sleep, after the check, so a wake that lands in between
// is not counted unless the wake waits for the waiter's lock first.
TEST(Waiter, WakeBetweenCheckAndSleepIsNotLost) {
    std::string const name = unique_waiter_name("late_wake");
    {
        thoth::detail::waiter w {name.c_str()};
        ASSERT_TRUE(w.valid());

        std::atomic<bool> ready {false};    // the state the waiter waits for
        std::atomic<bool> checking {false}; // the waiter is in its locked check
        std::thread waker {[&] {
            thoth::detail::waiter other {name.c_str()}; // another handle, as a peer has
            while (!checking.load()) std::this_thread::yield();
            ready = true;
            other.broadcast();
        }};

        int checks = 0;
        auto const start = std::chrono::steady_clock::now();
        bool const woken = w.wait_if([&] {
            if (ready.load()) return false;
            // The first check is the lock-free fast path; the second runs under
            // the lock, right before the waiter sleeps. Hold it there while the
            // waker changes the state and wakes.
            if (++checks == 2) {
                checking = true;
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
            return true;
        }, 3000);
        auto const waited = std::chrono::steady_clock::now() - start;
        waker.join();

        EXPECT_TRUE(woken);
        EXPECT_LT(waited, std::chrono::milliseconds(1500))
            << "the wake was lost: the waiter slept until its timeout";
    }
    thoth::detail::waiter::clear_storage(name.c_str());
}
