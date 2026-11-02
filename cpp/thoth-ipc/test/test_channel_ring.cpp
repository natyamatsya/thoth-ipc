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
#include "thoth-ipc/liveness.h"

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
// nobody would ever read it: the leftover mark must be dropped, or the writers
// stall when they lap back to it. The receiver cannot place an uncommitted
// element, so the writer drops it when it commits and sees that the id's
// receiver started after it (thoth::channel's liveness table holds where).
// It used to be the receiver, waiting up to 50 ms for the commit: a writer
// descheduled for longer (or, in the second test, committing after the connect)
// left the mark behind.
void expect_stale_mark_on_uncommitted_claim_released(bool commit_after_connect) {
    auto elems = std::make_unique<queue_t::elems_t>();
    thoth::detail::conn_liveness lv {};
    queue_t old_rx {elems.get()};
    old_rx.set_liveness(&lv);
    ASSERT_TRUE(old_rx.connect());
    auto const id = old_rx.connected_id();

    std::atomic<bool> claimed {false}, go {false};
    std::thread writer {[&] {
        queue_t tx {elems.get()};
        tx.set_liveness(&lv);
        EXPECT_TRUE(tx.push([&](void*) {
            claimed = true; // stamped with the old receiver's id, not committed
            while (!go) std::this_thread::yield();
            return true;
        }, 0, 0));
    }};
    while (!claimed) std::this_thread::yield();

    ASSERT_TRUE(old_rx.disconnect());
    // The writer commits while the new receiver is connecting, or after.
    std::thread release {[&] {
        if (!commit_after_connect) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            go = true;
        }
    }};
    queue_t rx {elems.get()};
    rx.set_liveness(&lv);
    ASSERT_TRUE(rx.connect());
    ASSERT_EQ(rx.connected_id(), id); // the same id, so its mark is ambiguous
    go = true;
    release.join();
    writer.join();

    // Lap the ring once: every element but the leftover one gets read.
    queue_t tx {elems.get()};
    tx.set_liveness(&lv);
    for (int i = 1; i < 256; ++i) {
        ASSERT_TRUE(tx.push([](void*) { return true; }, 0, i)) << "push " << i;
        msg_t m;
        ASSERT_TRUE(rx.pop(m)) << "pop " << i;
        ASSERT_EQ(m.dat_, i);
    }
    // Back at the leftover element: free unless its stale mark is still there.
    EXPECT_TRUE(tx.push([](void*) { return true; }, 0, 256));
}

TEST(ChannelRing, StaleMarkOnUncommittedClaimIsReleased) {
    expect_stale_mark_on_uncommitted_claim_released(false);
}

TEST(ChannelRing, StaleMarkOnClaimCommittedAfterConnectIsReleased) {
    expect_stale_mark_on_uncommitted_claim_released(true);
}

// A writer that commits an element and then drops the stale marks on it may run
// late: by then a receiver can have released the element, the ring lapped, and
// another writer stamped it for the next lap, with the receiver's bit as a live
// mark. The late drop must leave that mark (and the new commit) alone: it only
// acts while the element still holds the position it committed.
TEST(ChannelRing, LateStaleMarkDropSparesTheNextLap) {
    using elems_t  = queue_t::elems_t;
    using policy_t = elems_t::policy_t;
    using elem_t   = elems_t::elem_t;
    auto elems = std::make_unique<elems_t>();
    thoth::detail::conn_liveness lv {};
    queue_t tx {elems.get()};
    tx.set_liveness(&lv);

    // Position 0 is committed with the bit of a receiver that then leaves.
    queue_t old_rx {elems.get()};
    old_rx.set_liveness(&lv);
    ASSERT_TRUE(old_rx.connect());
    auto const id = old_rx.connected_id();
    ASSERT_TRUE(tx.push([](void*) { return true; }, 0, 0));
    ASSERT_TRUE(old_rx.disconnect());

    // A new receiver takes the bit (since 1) and releases position 0.
    queue_t rx {elems.get()};
    rx.set_liveness(&lv);
    ASSERT_TRUE(rx.connect());
    ASSERT_EQ(rx.connected_id(), id);
    auto *el0 = reinterpret_cast<elem_t *>(reinterpret_cast<char *>(elems.get()) + elems_t::head_size);

    // The ring laps; position 256 reuses element 0, marked for rx.
    for (int i = 1; i <= 256; ++i) {
        ASSERT_TRUE(tx.push([](void*) { return true; }, 0, i)) << "push " << i;
        if (i == 256) break;
        msg_t m;
        ASSERT_TRUE(rx.pop(m)) << "pop " << i;
    }
    ASSERT_TRUE(el0->rc_.load() & rx.connected_id());

    // The writer of position 0 resumes after its commit and drops the marks it
    // takes for stale: rx started after position 0.
    policy_t::drop_stale_marks(&tx, el0, 0);

    EXPECT_TRUE(el0->rc_.load() & rx.connected_id()) << "the next lap's live mark was dropped";
    msg_t m;
    ASSERT_TRUE(rx.pop(m)) << "position 256 is no longer readable";
    EXPECT_EQ(m.dat_, 256);
}
