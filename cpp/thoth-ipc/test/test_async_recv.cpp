// Layer 2 (THOTH_IPC_STDEXEC) tests for ipc::async_recv(): prove the senders/
// receivers receive API delivers a message on the caller's scheduler without a
// dedicated blocking thread, honours structured cancellation (set_stopped), and
// multiplexes multiple channels on the one process-global reactor.
//
// Compiles to nothing unless libipc was built with THOTH_IPC_STDEXEC.

#include <gtest/gtest.h>

#if defined(THOTH_IPC_STDEXEC)

#include <atomic>
#include <chrono>
#include <string>
#include <thread>

#include <stdexec/execution.hpp>
#include <exec/static_thread_pool.hpp>

#include "thoth-ipc/async_recv.h"
#include "thoth-ipc/ipc.h"

namespace {

std::string unique_name(char const *tag) {
    return std::string{"st.arecv.test."} + tag + "." + std::to_string(::getpid());
}

std::string as_string(ipc::buff_t const &b) {
    return b.empty() ? std::string{} : std::string{static_cast<char const *>(b.data())};
}

// Receiver that records which completion fired, with an injectable env so we can
// supply a stop token (as the RFC consumer does with inplace_stop_source). The
// value channel carries ipc::recv_result (message or recv_errc). set_error is
// kept only to satisfy connect should a scheduler introduce an error channel.
template <class Env>
struct capture_receiver {
    using receiver_concept = stdexec::receiver_t;
    std::atomic<int> *code; // 0 none, 1 value, 2 stopped, 3 error
    ipc::recv_result *out;
    Env env;
    void set_value(ipc::recv_result r) noexcept { *out = std::move(r); code->store(1); }
    void set_stopped() noexcept { code->store(2); }
    void set_error(std::exception_ptr) noexcept { code->store(3); }
    Env get_env() const noexcept { return env; }
};
template <class Env>
capture_receiver(std::atomic<int> *, ipc::recv_result *, Env) -> capture_receiver<Env>;

// A fake reactor modelling ipc::detail::reactor_like (no inheritance): captures
// the registered waiter so a test can drive on_ready() itself, and records
// add/remove calls. Demonstrates ipc::async_recv's dependency injection — no
// real kqueue/epoll thread involved.
struct fake_reactor {
    std::atomic<ipc::detail::reactor_waiter *> waiter{nullptr};
    std::atomic<int> adds{0};
    std::atomic<int> removes{0};
    // wait_handle_t (int fd on POSIX, HANDLE/void* on Windows) — behaviour is
    // identical here; only the type must match the reactor_like concept.
    void add(ipc::wait_handle_t, ipc::detail::reactor_waiter *w) {
        waiter.store(w);
        adds.fetch_add(1);
    }
    void remove(ipc::wait_handle_t, ipc::detail::reactor_waiter *w) {
        if (waiter.load() == w) waiter.store(nullptr);
        removes.fetch_add(1);
    }
};
static_assert(ipc::detail::reactor_like<fake_reactor>);

} // namespace

TEST(AsyncRecv, DeliversAlreadyQueuedMessage) {
    auto name = unique_name("eager");
    ipc::route reader{name.c_str(), ipc::receiver};
    ipc::route writer{name.c_str(), ipc::sender};
    ASSERT_TRUE(reader.valid());
    ASSERT_TRUE(writer.wait_for_recv(1, 2000));

    ASSERT_TRUE(writer.send(std::string{"already-here"}));

    exec::static_thread_pool pool{2};
    auto result = stdexec::sync_wait(ipc::async_recv(reader, pool.get_scheduler()));
    ASSERT_TRUE(result.has_value());                     // completed on value channel
    ipc::recv_result r = std::get<0>(std::move(*result));
    ASSERT_TRUE(r.has_value());                          // a message, not a recv_errc
    EXPECT_EQ(as_string(*r), "already-here");
}

TEST(AsyncRecv, DeliversMessageThatArrivesLater) {
    auto name = unique_name("armed");
    ipc::route reader{name.c_str(), ipc::receiver};
    ipc::route writer{name.c_str(), ipc::sender};
    ASSERT_TRUE(reader.valid());
    ASSERT_TRUE(writer.wait_for_recv(1, 2000));

    // Send only after async_recv has surely armed the reactor.
    std::thread sender{[&] {
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
        writer.send(std::string{"arrived-later"});
    }};

    exec::static_thread_pool pool{2};
    auto result = stdexec::sync_wait(ipc::async_recv(reader, pool.get_scheduler()));
    sender.join();
    ASSERT_TRUE(result.has_value());
    ipc::recv_result r = std::get<0>(std::move(*result));
    ASSERT_TRUE(r.has_value());
    EXPECT_EQ(as_string(*r), "arrived-later");
}

TEST(AsyncRecv, CancellationCompletesStopped) {
    auto name = unique_name("cancel");
    ipc::route reader{name.c_str(), ipc::receiver};
    ASSERT_TRUE(reader.valid());

    exec::static_thread_pool pool{2};
    stdexec::inplace_stop_source stop;
    auto env = stdexec::prop{stdexec::get_stop_token, stop.get_token()};

    std::atomic<int> code{0};
    ipc::recv_result out;
    auto op = stdexec::connect(ipc::async_recv(reader, pool.get_scheduler()),
                               capture_receiver{&code, &out, env});
    stdexec::start(op);

    // No message: the op parks on the reactor, nothing completes.
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    EXPECT_EQ(code.load(), 0);

    // Structured cancellation unwinds it with set_stopped, no thread to join.
    stop.request_stop();
    for (int i = 0; i < 200 && code.load() == 0; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    EXPECT_EQ(code.load(), 2); // set_stopped
}

TEST(AsyncRecv, ManyChannelsOneReactor) {
    constexpr int N = 6;
    exec::static_thread_pool pool{2};

    std::vector<std::unique_ptr<ipc::route>> readers, writers;
    for (int i = 0; i < N; ++i) {
        auto name = unique_name(("mux." + std::to_string(i)).c_str());
        readers.push_back(std::make_unique<ipc::route>(name.c_str(), ipc::receiver));
        writers.push_back(std::make_unique<ipc::route>(name.c_str(), ipc::sender));
        ASSERT_TRUE(writers[i]->wait_for_recv(1, 2000));
    }

    // Each channel gets its own message; all receives ride the single reactor.
    std::thread producer{[&] {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        for (int i = 0; i < N; ++i) writers[i]->send("msg-" + std::to_string(i));
    }};

    for (int i = 0; i < N; ++i) {
        auto result = stdexec::sync_wait(ipc::async_recv(*readers[i], pool.get_scheduler()));
        ASSERT_TRUE(result.has_value());
        ipc::recv_result r = std::get<0>(std::move(*result));
        ASSERT_TRUE(r.has_value());
        EXPECT_EQ(as_string(*r), "msg-" + std::to_string(i));
    }
    producer.join();
}

TEST(AsyncRecv, InjectedReactorDrivesCompletion) {
    auto name = unique_name("inject");
    ipc::route reader{name.c_str(), ipc::receiver};
    ipc::route writer{name.c_str(), ipc::sender};
    ASSERT_TRUE(reader.valid());
    ASSERT_TRUE(writer.wait_for_recv(1, 2000));

    fake_reactor fake;
    exec::static_thread_pool pool{1};
    stdexec::inplace_stop_source stop; // unused; just supplies a token
    auto env = stdexec::prop{stdexec::get_stop_token, stop.get_token()};

    std::atomic<int> code{0};
    ipc::recv_result out;
    auto op = stdexec::connect(ipc::async_recv(reader, pool.get_scheduler(), fake),
                               capture_receiver{&code, &out, env});
    stdexec::start(op);

    // With no message queued, the op must have armed on OUR reactor, not the
    // global one — proving the injection took effect.
    EXPECT_EQ(fake.adds.load(), 1);
    ASSERT_NE(fake.waiter.load(), nullptr);
    EXPECT_EQ(code.load(), 0);

    // Enqueue, then simulate the reactor observing readiness ourselves.
    ASSERT_TRUE(writer.send(std::string{"injected"}));
    auto disposition = fake.waiter.load()->on_ready();
    EXPECT_EQ(disposition, ipc::detail::reactor_waiter::disposition::remove);

    // Completion hops onto the pool scheduler.
    for (int i = 0; i < 200 && code.load() == 0; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    EXPECT_EQ(code.load(), 1);
    ASSERT_TRUE(out.has_value());
    EXPECT_EQ(as_string(*out), "injected");
}

TEST(AsyncRecv, NoReadinessHandleYieldsErrc) {
    // A sender-mode channel owns no reader slot, hence no readiness handle. The
    // pruned error channel means this surfaces as a recv_errc on the value
    // channel — not set_error — so the pipeline stays exception-free.
    auto name = unique_name("noh");
    ipc::route sender_only{name.c_str(), ipc::sender};
    ASSERT_EQ(sender_only.native_wait_handle(), ipc::invalid_wait_handle);

    exec::static_thread_pool pool{1};
    auto result = stdexec::sync_wait(ipc::async_recv(sender_only, pool.get_scheduler()));
    ASSERT_TRUE(result.has_value());                     // completed on value channel
    ipc::recv_result r = std::get<0>(std::move(*result));
    ASSERT_FALSE(r.has_value());                         // carries an error code
    EXPECT_EQ(r.error(), ipc::recv_errc::no_readiness_handle);
}

#endif // THOTH_IPC_STDEXEC
