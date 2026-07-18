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
#include <thread>
#include <unistd.h>

#include "thoth-ipc/ipc.h"
#include "thoth-ipc/liveness.h"

namespace {

// A live sender is the least intrusive way to read recv_count() — senders do not
// claim a receiver slot and (unlike receivers) never trigger reap-on-connect.
std::size_t observed_recv_count(char const *name) {
    ipc::route probe{name, ipc::sender};
    return probe.recv_count();
}

} // namespace

TEST(Liveness, ReapsDeadReceiverOnConnect) {
    char const *name = "st.liveness.reap";
    ipc::route::clear_storage(name);

    pid_t pid = ::fork();
    ASSERT_GE(pid, 0);
    if (pid == 0) {
        // Child: claim a receiver slot, then block until SIGKILLed — so its
        // destructor never runs and the cc_ bit is never cleared cleanly.
        ipc::route r{name, ipc::receiver};
        ::pause();
        ::_exit(0);
    }

    // Parent: wait for the child to occupy its slot.
    {
        ipc::route probe{name, ipc::sender};
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
        ipc::route fresh{name, ipc::receiver};
        EXPECT_EQ(fresh.recv_count(), 1u) << "dead receiver was not reaped on connect";

        // A second live receiver must still count normally (reaping is targeted,
        // not a blanket disconnect).
        ipc::route fresh2{name, ipc::receiver};
        EXPECT_EQ(fresh2.recv_count(), 2u);
    }

    ipc::route::clear_storage(name);
}

// Phase 2: when a dead receiver blocks ring reclamation, force_push must reap the
// dead reader and KEEP the live one that is still draining — instead of the old
// blanket disconnect that dropped live readers too.
TEST(Liveness, ForcePushReapsDeadKeepsLive) {
    char const *name = "st.liveness.forcepush";
    ipc::route::clear_storage(name);

    // Dead receiver: connects, never reads, gets SIGKILLed — it will block the
    // ring because it never consumes.
    pid_t pid = ::fork();
    ASSERT_GE(pid, 0);
    if (pid == 0) {
        ipc::route dead{name, ipc::receiver};
        ::pause();
        ::_exit(0);
    }
    {
        ipc::route probe{name, ipc::sender};
        ASSERT_TRUE(probe.wait_for_recv(1, 3000)) << "dead receiver never connected";
    }

    // Live receiver in this process, draining in a thread.
    ipc::route live{name, ipc::receiver};
    ASSERT_EQ(observed_recv_count(name), 2u); // dead (phantom-to-be) + live

    ::kill(pid, SIGKILL);
    int status = 0;
    ASSERT_EQ(::waitpid(pid, &status, 0), pid);

    std::atomic<int> received{0};
    std::atomic<bool> stop{false};
    std::thread reader([&] {
        while (!stop.load(std::memory_order_acquire)) {
            ipc::buff_t b = live.recv(200);
            if (!b.empty()) received.fetch_add(1, std::memory_order_relaxed);
        }
    });

    // Sender storm: the dead receiver blocks reclamation, so the writer hits
    // force_push, which reaps the dead slot and keeps the live (draining) reader.
    {
        ipc::route s{name, ipc::sender};
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

    ipc::route::clear_storage(name);
}

// Phase 3: a start token disambiguates PID reuse — a live PID whose recorded
// token no longer matches (the PID was recycled for a different process) must be
// treated as gone, while the same process with the same token stays alive.
TEST(Liveness, StartTokenDetectsPidReuse) {
    using namespace ipc::detail;
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

#endif // !_WIN32
