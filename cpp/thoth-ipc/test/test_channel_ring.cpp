// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// The multi-producer broadcast ring (thoth::channel's prod_cons_impl) at the
// queue level, where a test can hold a writer between claiming an element and
// committing it: queue::push runs its `prep` callback in exactly that window.

#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <memory>
#include <thread>

#include "thoth-ipc/prod_cons.h"
#include "thoth-ipc/policy.h"
#include "thoth-ipc/circ/elem_array.h"
#include "thoth-ipc/queue.h"

namespace {

struct msg_t {
    int pid_;
    int dat_;

    msg_t() = default;
    msg_t(int p, int d) : pid_(p), dat_(d) {}
};

using queue_t = thoth::queue<msg_t, thoth::policy::choose<thoth::circ::elem_array,
    thoth::wr<thoth::relat::multi, thoth::relat::multi, thoth::trans::broadcast>>>;

} // namespace

// A receiver disconnects while a writer is part-way through an element stamped
// with the receiver's id, and a new receiver claims the same id before the
// writer commits. That element lies before where the new receiver starts, so
// nobody would ever read it: the new receiver must drop the leftover mark once
// the writer commits, or the writers stall when they lap back to it.
TEST(ChannelRing, StaleMarkOnUncommittedClaimIsReleased) {
    auto elems = std::make_unique<queue_t::elems_t>();
    queue_t old_rx {elems.get()};
    ASSERT_TRUE(old_rx.connect());
    auto const id = old_rx.connected_id();

    std::atomic<bool> claimed {false}, go {false};
    std::thread writer {[&] {
        queue_t tx {elems.get()};
        EXPECT_TRUE(tx.push([&](void*) {
            claimed = true; // stamped with the old receiver's id, not committed
            while (!go) std::this_thread::yield();
            return true;
        }, 0, 0));
    }};
    while (!claimed) std::this_thread::yield();

    ASSERT_TRUE(old_rx.disconnect());
    // The writer commits while the new receiver is connecting.
    std::thread release {[&] {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        go = true;
    }};
    queue_t rx {elems.get()};
    ASSERT_TRUE(rx.connect());
    ASSERT_EQ(rx.connected_id(), id); // the same id, so its mark is ambiguous
    release.join();
    writer.join();

    // Lap the ring once: every element but the leftover one gets read.
    queue_t tx {elems.get()};
    for (int i = 1; i < 256; ++i) {
        ASSERT_TRUE(tx.push([](void*) { return true; }, 0, i)) << "push " << i;
        msg_t m;
        ASSERT_TRUE(rx.pop(m)) << "pop " << i;
        ASSERT_EQ(m.dat_, i);
    }
    // Back at the leftover element: free unless its stale mark is still there.
    EXPECT_TRUE(tx.push([](void*) { return true; }, 0, 256));
}
