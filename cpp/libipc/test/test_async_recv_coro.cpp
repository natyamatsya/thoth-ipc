// Path (a): prove the stdexec `ipc::async_recv` sender is directly awaitable in a
// C++20 coroutine — `co_await ipc::async_recv(route, sched)` inside an exec::task
// — so consumers already using stdexec get `.await`-style ergonomics for free,
// over the same Layer-1 fd + reactor. Compiles to nothing without LIBIPC_STDEXEC.

#include <gtest/gtest.h>

#if defined(LIBIPC_STDEXEC)

#include <string>

#include <exec/task.hpp>
#include <stdexec/execution.hpp>

#include "libipc/async_recv.h"
#include "libipc/ipc.h"

namespace {

// A coroutine that awaits one message. It reads its own scheduler from the task
// environment (sync_wait supplies a run_loop scheduler) and hands it to async_recv.
exec::task<int> co_recv_one(ipc::route &r) {
    auto sched = co_await stdexec::read_env(stdexec::get_scheduler);
    ipc::recv_result res = co_await ipc::async_recv(r, sched);
    co_return res.has_value() ? static_cast<int>(res->size()) : -1;
}

} // namespace

TEST(AsyncRecvCoro, CoAwaitAsyncRecvDelivers) {
    char const *name = "st.coro.a.queued";
    ipc::route::clear_storage(name);

    ipc::route reader{name, ipc::receiver};
    ipc::route writer{name, ipc::sender};
    ASSERT_TRUE(writer.wait_for_recv(1, 2000));
    std::string msg(50, 'Z');
    ASSERT_TRUE(writer.send(msg.data(), msg.size()));

    // co_await the async_recv sender inside the coroutine; drive it with sync_wait.
    auto result = stdexec::sync_wait(co_recv_one(reader));
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(std::get<0>(*result), 50);

    ipc::route::clear_storage(name);
}

#endif // LIBIPC_STDEXEC
