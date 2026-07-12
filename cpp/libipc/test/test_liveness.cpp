// Dead-connection reaping tests (RFC: context/dead-connection-reaper-rfc.md),
// Phase 1. A SIGKILLed receiver leaves a phantom bit in cc_; a fresh receiver's
// reap-on-connect must reclaim it (PID-liveness), so the connection count stays
// accurate and the 32-slot space is not leaked.
//
// POSIX only (needs fork + SIGKILL); compiles to nothing on Windows.

#include <gtest/gtest.h>

#if !defined(_WIN32)

#include <cstddef>
#include <csignal>
#include <sys/wait.h>
#include <unistd.h>

#include "libipc/ipc.h"

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

#endif // !_WIN32
