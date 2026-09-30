// Dead-connection reaping tests (RFC: context/dead-connection-reaper-rfc.md),
// Phase 1. A SIGKILLed receiver leaves a phantom bit in cc_; a fresh receiver's
// reap-on-connect must reclaim it (PID-liveness), so the connection count stays
// accurate and the 32-slot space is not leaked.
//
// POSIX only (needs fork + SIGKILL); compiles to nothing on Windows.

#include <gtest/gtest.h>

#if !defined(_WIN32)

#include <atomic>
#include <cstddef>
#include <csignal>
#include <sys/wait.h>
#include <string>
#include <thread>
#include <unistd.h>

#include "thoth-ipc/ipc.h"
#include "thoth-ipc/liveness.h"

namespace {

// A live sender is the least intrusive way to read recv_count() — senders do not
// claim a receiver slot and (unlike receivers) never trigger reap-on-connect.
std::size_t observed_recv_count(char const *name) {
    thoth::route probe{name, thoth::sender};
    return probe.recv_count();
}

} // namespace

TEST(Liveness, ReapsDeadReceiverOnConnect) {
    char const *name = "st.liveness.reap";
    thoth::route::clear_storage(name);

    pid_t pid = ::fork();
    ASSERT_GE(pid, 0);
    if (pid == 0) {
        // Child: claim a receiver slot, then block until SIGKILLed — so its
        // destructor never runs and the cc_ bit is never cleared cleanly.
        thoth::route r{name, thoth::receiver};
        ::pause();
        ::_exit(0);
    }

    // Parent: wait for the child to occupy its slot.
    {
        thoth::route probe{name, thoth::sender};
        ASSERT_TRUE(probe.wait_for_recv(1, 3000)) << "child never connected";
    }
    EXPECT_EQ(observed_recv_count(name), 1u);

    // Kill the child hard — no clean disconnect. Its bit becomes a phantom.
    ASSERT_EQ(::kill(pid, SIGKILL), 0);
    int status = 0;
    ASSERT_EQ(::waitpid(pid, &status, 0), pid);

    // The phantom is still counted until something reaps it.
    EXPECT_EQ(observed_recv_count(name), 1u) << "expected the phantom bit to linger";

    // A fresh receiver reaps the dead slot before claiming its own, so the count
    // is 1 (just us) — NOT 2 (phantom + us), which is what happens without the reaper.
    {
        thoth::route fresh{name, thoth::receiver};
        EXPECT_EQ(fresh.recv_count(), 1u) << "dead receiver was not reaped on connect";

        // A second live receiver must still count normally (reaping is targeted,
        // not a blanket disconnect).
        thoth::route fresh2{name, thoth::receiver};
        EXPECT_EQ(fresh2.recv_count(), 2u);
    }

    thoth::route::clear_storage(name);
}

// Phase 2: when a dead receiver blocks ring reclamation, force_push must reap the
// dead reader and KEEP the live one that is still draining — instead of the old
// blanket disconnect that dropped live readers too.
TEST(Liveness, ForcePushReapsDeadKeepsLive) {
    char const *name = "st.liveness.forcepush";
    thoth::route::clear_storage(name);

    // Dead receiver: connects, never reads, gets SIGKILLed — it will block the
    // ring because it never consumes.
    pid_t pid = ::fork();
    ASSERT_GE(pid, 0);
    if (pid == 0) {
        thoth::route dead{name, thoth::receiver};
        ::pause();
        ::_exit(0);
    }
    {
        thoth::route probe{name, thoth::sender};
        ASSERT_TRUE(probe.wait_for_recv(1, 3000)) << "dead receiver never connected";
    }

    // Live receiver in this process, draining in a thread.
    thoth::route live{name, thoth::receiver};
    ASSERT_EQ(observed_recv_count(name), 2u); // dead (phantom-to-be) + live

    ::kill(pid, SIGKILL);
    int status = 0;
    ASSERT_EQ(::waitpid(pid, &status, 0), pid);

    std::atomic<int> received{0};
    std::atomic<bool> stop{false};
    std::thread reader([&] {
        while (!stop.load(std::memory_order_acquire)) {
            thoth::buff_t b = live.recv(200);
            if (!b.empty()) received.fetch_add(1, std::memory_order_relaxed);
        }
    });

    // Sender storm: the dead receiver blocks reclamation, so the writer hits
    // force_push, which reaps the dead slot and keeps the live (draining) reader.
    {
        thoth::route s{name, thoth::sender};
        ASSERT_TRUE(s.wait_for_recv(1, 3000));
        char msg[8] = "phase2";
        for (int i = 0; i < 1000; ++i) {
            s.send(msg, sizeof(msg), 200);
        }
    }

    // Give the reader a moment to drain the tail, then stop it.
    for (int i = 0; i < 50 && received.load() == 0; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    stop.store(true, std::memory_order_release);
    reader.join();

    // The dead receiver was reaped; the live one survived (not blanket-disconnected).
    EXPECT_EQ(live.recv_count(), 1u) << "live reader was dropped by force_push";
    EXPECT_GT(received.load(), 0) << "live reader received nothing";

    thoth::route::clear_storage(name);
}

// Phase 3: a start token disambiguates PID reuse — a live PID whose recorded
// token no longer matches (the PID was recycled for a different process) must be
// treated as gone, while the same process with the same token stays alive.
TEST(Liveness, StartTokenDetectsPidReuse) {
    using namespace thoth::detail;
    std::int32_t me = self_pid();
    std::uint64_t tok = start_token(me);

    // Our own process, with the token we recorded, is alive (token real or the
    // token-less 0 fallback — both must report alive).
    EXPECT_TRUE(is_process_alive(me, tok));

    if (tok != 0) {
        // Same live PID but a DIFFERENT token ⇒ this must look like a recycled PID
        // (our recorded owner is gone), so reaping is allowed.
        EXPECT_FALSE(is_process_alive(me, tok ^ 0x5eedULL))
            << "PID reuse (token mismatch) was not detected";
    }

    // A clearly invalid PID is never alive.
    EXPECT_FALSE(is_process_alive(-1, tok));
}

// A single-producer route admits one sender, guarded by a flag in the ring. A
// SIGKILLed sender never clears it, so without reaping every later sender is
// refused ("que->ready_sending() == false") until clear_storage() - e.g. an app
// restarted after a kill can no longer publish on its own channels.
TEST(Liveness, ReclaimsDeadSender) {
    char const *name = "st.liveness.sender";
    thoth::route::clear_storage(name);
    thoth::route r{name, thoth::receiver};

    pid_t pid = ::fork();
    ASSERT_GE(pid, 0);
    if (pid == 0) {
        // Child: hold the single-producer flag (opening a sender claims it), and
        // say so with one delivered message.
        for (;;) {
            thoth::route s{name, thoth::sender};
            if (s.send("held", 4, 0)) ::pause();
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    }

    // Whatever happens below, the child does not outlive the test.
    struct reap_child {
        pid_t pid;
        ~reap_child() {
            if (pid > 0 && ::kill(pid, SIGKILL) == 0) ::waitpid(pid, nullptr, 0);
        }
    } child{pid};

    thoth::buff_t held = r.recv(3000);
    ASSERT_FALSE(held.empty()) << "the child never held the sender flag";
    {
        thoth::route other{name, thoth::sender};
        EXPECT_FALSE(other.send("x", 1, 0)) << "a second sender got in while the first lives";
    }

    // Kill the child hard - no clean shut_sending().
    ASSERT_EQ(::kill(pid, SIGKILL), 0);
    int status = 0;
    ASSERT_EQ(::waitpid(pid, &status, 0), pid);
    child.pid = 0;

    // A fresh sender must take over the dead one's flag and deliver.
    {
        thoth::route s{name, thoth::sender};
        EXPECT_TRUE(s.send("after", 5, 1000)) << "the dead sender's flag was not reclaimed";
        thoth::buff_t b = r.recv(1000);
        ASSERT_FALSE(b.empty());
        EXPECT_EQ(std::string(static_cast<char const *>(b.data()), b.size()), "after");
    }

    // A live sender keeps the flag: a second one is still refused.
    {
        thoth::route s1{name, thoth::sender};
        ASSERT_TRUE(s1.send("one", 3, 1000));
        thoth::route s2{name, thoth::sender};
        EXPECT_FALSE(s2.send("two", 3, 0)) << "a live sender's flag was taken over";
    }

    thoth::route::clear_storage(name);
}

// A zombie - a peer that has exited but whose parent has not reaped it yet, e.g.
// a parent that cannot wait() for a child a debugger traces - holds nothing,
// though kill(pid, 0) still succeeds for it. Its sender slot must be taken over
// and its receiver slot reaped while it is still a zombie.
namespace {

// Fork a child that runs `hold` and then exits without cleanup; wait until it is
// a zombie, and leave it unreaped (the caller reaps it at the end).
template <typename Hold>
pid_t fork_zombie(Hold hold) {
    pid_t pid = ::fork();
    if (pid == 0) {
        hold();
        ::_exit(0); // no destructors: the slot stays claimed
    }
    for (int i = 0; i < 300 && !thoth::detail::is_zombie(pid); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return pid;
}

} // namespace

TEST(Liveness, ZombieSenderIsTakenOver) {
    char const *name = "st.liveness.zombie-sender";
    thoth::route::clear_storage(name);
    thoth::route r{name, thoth::receiver};
    pid_t pid = fork_zombie([name] {
        // Leaked on purpose: a destructor would release the slot before _exit.
        auto *s = new thoth::route{name, thoth::sender};
        s->send("held", 4, 1000);
    });
    ASSERT_GT(pid, 0);
    ASSERT_TRUE(thoth::detail::is_zombie(pid)) << "the child did not become a zombie";
    ASSERT_FALSE(r.recv(1000).empty()) << "the child never held the sender slot";
    {
        thoth::route s{name, thoth::sender};
        EXPECT_TRUE(s.send("after", 5, 1000)) << "a zombie's sender slot was not taken over";
    }
    ::waitpid(pid, nullptr, 0);
    thoth::route::clear_storage(name);
}

TEST(Liveness, ZombieReceiverIsReaped) {
    char const *name = "st.liveness.zombie-receiver";
    thoth::route::clear_storage(name);
    // Leaked on purpose: a destructor would disconnect cleanly before _exit.
    pid_t pid = fork_zombie([name] { new thoth::route{name, thoth::receiver}; });
    ASSERT_GT(pid, 0);
    ASSERT_TRUE(thoth::detail::is_zombie(pid)) << "the child did not become a zombie";
    EXPECT_EQ(observed_recv_count(name), 1u) << "expected the zombie's bit to linger";
    {
        thoth::route fresh{name, thoth::receiver};
        EXPECT_EQ(fresh.recv_count(), 1u) << "a zombie receiver was not reaped on connect";
    }
    ::waitpid(pid, nullptr, 0);
    thoth::route::clear_storage(name);
}

#endif // !_WIN32
