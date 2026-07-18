// Layer 1 (THOTH_IPC_NOTIFY_FD) readiness-handle tests: prove that a channel's
// native_wait_handle() is a real waitable fd — pollable, cross-connection,
// and multiplexable — so a consumer can react to messages without a dedicated
// blocking recv thread. See context/stdexec-async-recv-rfc.md.
//
// The whole file compiles to nothing unless the library was built with
// THOTH_IPC_NOTIFY_FD (a PUBLIC compile definition, so this TU sees it).

#include <gtest/gtest.h>

#if defined(THOTH_IPC_NOTIFY_FD) && !defined(_WIN32)

#include <poll.h>
#include <unistd.h>

#include <string>
#include <thread>

#include "thoth-ipc/ipc.h"

namespace {

// Unique channel name per test run to avoid stale shm/FIFO collisions.
std::string unique_name(char const *tag) {
    return std::string{"st.notify.test."} + tag + "." +
           std::to_string(::getpid());
}

// poll a single fd for readability; returns true if POLLIN within `ms`.
bool readable(int fd, int ms) {
    pollfd p{fd, POLLIN, 0};
    int r = ::poll(&p, 1, ms);
    return r > 0 && (p.revents & POLLIN);
}

// Consume the readiness bytes (edge-triggered contract: drain the fd, then the
// consumer would drain the channel via try_recv until empty).
void drain_fd(int fd) {
    char buf[256];
    while (::read(fd, buf, sizeof(buf)) > 0) { /* discard */ }
}

} // namespace

TEST(NotifyFd, HandleValidForReceiver) {
    auto name = unique_name("recv");
    thoth::route reader{name.c_str(), thoth::receiver};
    ASSERT_TRUE(reader.valid());
    EXPECT_NE(reader.native_wait_handle(), thoth::invalid_wait_handle);
    reader.clear();
}

TEST(NotifyFd, SenderHasNoHandle) {
    auto name = unique_name("send");
    thoth::route writer{name.c_str(), thoth::sender};
    // A pure sender owns no reader slot, hence no readiness fd.
    EXPECT_EQ(writer.native_wait_handle(), thoth::invalid_wait_handle);
    writer.clear();
}

TEST(NotifyFd, EnqueueSignalsHandleAndRecvSucceeds) {
    auto name = unique_name("signal");

    thoth::route reader{name.c_str(), thoth::receiver};
    ASSERT_TRUE(reader.valid());
    int fd = reader.native_wait_handle();
    ASSERT_NE(fd, thoth::invalid_wait_handle);

    // Nothing enqueued yet: the handle must not be spuriously readable.
    EXPECT_FALSE(readable(fd, 0));

    thoth::route writer{name.c_str(), thoth::sender};
    ASSERT_TRUE(writer.valid());
    // Wait until the sender sees the reader connected (mirrors real usage).
    ASSERT_TRUE(writer.wait_for_recv(1, 2000));

    std::string const payload = "hello-notify";
    ASSERT_TRUE(writer.send(payload));

    // The enqueue must make the handle readable, no blocking recv thread needed.
    EXPECT_TRUE(readable(fd, 2000));

    thoth::buff_t got = reader.recv(0);
    ASSERT_FALSE(got.empty());
    EXPECT_STREQ(static_cast<char const *>(got.data()), payload.c_str());

    // After draining the fd (and the channel), readiness clears.
    drain_fd(fd);
    EXPECT_FALSE(readable(fd, 0));

    reader.clear();
}

TEST(NotifyFd, TwoChannelsMultiplexOnOnePoll) {
    auto name_a = unique_name("mux.a");
    auto name_b = unique_name("mux.b");

    thoth::route reader_a{name_a.c_str(), thoth::receiver};
    thoth::route reader_b{name_b.c_str(), thoth::receiver};
    ASSERT_TRUE(reader_a.valid());
    ASSERT_TRUE(reader_b.valid());

    int fd_a = reader_a.native_wait_handle();
    int fd_b = reader_b.native_wait_handle();
    ASSERT_NE(fd_a, thoth::invalid_wait_handle);
    ASSERT_NE(fd_b, thoth::invalid_wait_handle);

    thoth::route writer_b{name_b.c_str(), thoth::sender};
    ASSERT_TRUE(writer_b.wait_for_recv(1, 2000));
    ASSERT_TRUE(writer_b.send(std::string{"only-b"}));

    // One poll set, two channels: only B fires — the essence of "multiplex many
    // channels on one thread instead of one blocking thread each".
    pollfd fds[2] = {{fd_a, POLLIN, 0}, {fd_b, POLLIN, 0}};
    int r = ::poll(fds, 2, 2000);
    ASSERT_GT(r, 0);
    EXPECT_FALSE(fds[0].revents & POLLIN);
    EXPECT_TRUE(fds[1].revents & POLLIN);

    thoth::buff_t got = reader_b.recv(0);
    ASSERT_FALSE(got.empty());
    EXPECT_STREQ(static_cast<char const *>(got.data()), "only-b");

    reader_a.clear();
    reader_b.clear();
}

#endif // THOTH_IPC_NOTIFY_FD && !_WIN32
