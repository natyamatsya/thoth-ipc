#include "libipc/execution/reactor.h"

#if defined(LIBIPC_NOTIFY_FD)

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>

#include <cerrno>
#include <fcntl.h>
#include <unistd.h>

#if defined(LIBIPC_OS_APPLE)
#  include <sys/event.h>
#  include <sys/types.h>
#else
#  include <sys/epoll.h>
#  include <sys/eventfd.h>
#endif

// A single reactor thread owns everything. add()/remove() from other threads
// only touch a control queue (under ctl_mtx_) and wake the loop; the registry
// and the poll set are mutated solely on the reactor thread. Because dispatch
// and control-application both run on that one thread, they never overlap — so
// a synchronous remove() (which blocks until the reactor applies it) guarantees
// no on_ready() for the removed waiter afterwards.
//
// Dangling-pointer safety: before invoking on_ready() for an fd, the reactor
// swaps that fd's waiter list out of the registry, then re-inserts only those
// that return `keep`. A waiter that completes (returns `remove`, and may then be
// destroyed asynchronously once its scheduler hop fires) is therefore no longer
// referenced by the reactor when on_ready() returns.

namespace ipc {
namespace detail {

namespace {

struct ctl_item {
    enum kind { add, remove } op;
    int fd;
    reactor_waiter *w;
    std::atomic<bool> *ack; // non-null for remove: set true once applied
};

} // namespace

struct reactor::impl {
    int poll_fd = -1;
#if defined(LIBIPC_OS_APPLE)
    int wake_r = -1, wake_w = -1; // self-pipe
#else
    int wake_fd = -1;             // eventfd
#endif
    std::atomic<bool> stop{false};

    std::mutex ctl_mtx;
    std::deque<ctl_item> ctl;

    std::mutex ack_mtx;
    std::condition_variable ack_cv;

    // Reactor-thread-only:
    std::unordered_map<int, std::vector<reactor_waiter *>> reg;

    std::thread th;

    impl() {
#if defined(LIBIPC_OS_APPLE)
        poll_fd = ::kqueue();
        int fds[2];
        if (::pipe(fds) == 0) {
            wake_r = fds[0];
            wake_w = fds[1];
            ::fcntl(wake_r, F_SETFD, FD_CLOEXEC);
            ::fcntl(wake_w, F_SETFD, FD_CLOEXEC);
            ::fcntl(wake_r, F_SETFL, O_NONBLOCK);
            ::fcntl(wake_w, F_SETFL, O_NONBLOCK);
            struct kevent kev;
            EV_SET(&kev, wake_r, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, nullptr);
            ::kevent(poll_fd, &kev, 1, nullptr, 0, nullptr);
        }
#else
        poll_fd = ::epoll_create1(EPOLL_CLOEXEC);
        wake_fd = ::eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
        epoll_event ev{};
        ev.events = EPOLLIN;
        ev.data.fd = wake_fd;
        ::epoll_ctl(poll_fd, EPOLL_CTL_ADD, wake_fd, &ev);
#endif
        th = std::thread([this] { run(); });
    }

    ~impl() {
        stop.store(true, std::memory_order_release);
        wake();
        if (th.joinable()) th.join();
#if defined(LIBIPC_OS_APPLE)
        if (wake_r != -1) ::close(wake_r);
        if (wake_w != -1) ::close(wake_w);
#else
        if (wake_fd != -1) ::close(wake_fd);
#endif
        if (poll_fd != -1) ::close(poll_fd);
    }

    void wake() noexcept {
#if defined(LIBIPC_OS_APPLE)
        char c = 1;
        while (::write(wake_w, &c, 1) < 0 && errno == EINTR) {}
#else
        std::uint64_t one = 1;
        while (::write(wake_fd, &one, sizeof(one)) < 0 && errno == EINTR) {}
#endif
    }

    void drain_wake() noexcept {
#if defined(LIBIPC_OS_APPLE)
        char buf[64];
        while (::read(wake_r, buf, sizeof(buf)) > 0) {}
#else
        std::uint64_t v;
        while (::read(wake_fd, &v, sizeof(v)) > 0) {}
#endif
    }

    void arm(int fd) noexcept {
#if defined(LIBIPC_OS_APPLE)
        struct kevent kev;
        EV_SET(&kev, fd, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, nullptr);
        ::kevent(poll_fd, &kev, 1, nullptr, 0, nullptr);
#else
        epoll_event ev{};
        ev.events = EPOLLIN; // level-triggered
        ev.data.fd = fd;
        ::epoll_ctl(poll_fd, EPOLL_CTL_ADD, fd, &ev);
#endif
    }

    void disarm(int fd) noexcept {
#if defined(LIBIPC_OS_APPLE)
        struct kevent kev;
        EV_SET(&kev, fd, EVFILT_READ, EV_DELETE, 0, 0, nullptr);
        ::kevent(poll_fd, &kev, 1, nullptr, 0, nullptr);
#else
        ::epoll_ctl(poll_fd, EPOLL_CTL_DEL, fd, nullptr);
#endif
    }

    void ack(std::atomic<bool> *a) noexcept {
        {
            std::lock_guard<std::mutex> lk(ack_mtx);
            a->store(true, std::memory_order_release);
        }
        ack_cv.notify_all();
    }

    // Apply queued add/remove requests. Reactor thread only.
    void process_ctl() {
        std::deque<ctl_item> local;
        {
            std::lock_guard<std::mutex> lk(ctl_mtx);
            local.swap(ctl);
        }
        for (auto &it : local) {
            if (it.op == ctl_item::add) {
                auto &vec = reg[it.fd];
                vec.push_back(it.w);
                if (vec.size() == 1) arm(it.fd);
            } else { // remove
                auto found = reg.find(it.fd);
                if (found != reg.end()) {
                    auto &vec = found->second;
                    for (auto p = vec.begin(); p != vec.end(); ++p) {
                        if (*p == it.w) { vec.erase(p); break; }
                    }
                    if (vec.empty()) {
                        disarm(it.fd);
                        reg.erase(found);
                    }
                }
                if (it.ack) ack(it.ack);
            }
        }
    }

    // Fire on_ready() for a readable fd. Reactor thread only.
    void dispatch(int fd) {
        auto found = reg.find(fd);
        if (found == reg.end()) return;

        // Swap the list out so no reactor reference survives an on_ready() that
        // completes (and may asynchronously destroy the waiter).
        std::vector<reactor_waiter *> waiters;
        waiters.swap(found->second);

        std::vector<reactor_waiter *> keep;
        keep.reserve(waiters.size());
        for (auto *w : waiters) {
            if (w->on_ready() == reactor_waiter::disposition::keep) {
                keep.push_back(w);
            }
        }

        // found may be stale after on_ready ran process-y code; re-find.
        found = reg.find(fd);
        if (keep.empty()) {
            if (found != reg.end() && found->second.empty()) {
                disarm(fd);
                reg.erase(found);
            } else if (found == reg.end()) {
                disarm(fd);
            }
        } else {
            // Prepend keepers ahead of anything add()ed during dispatch.
            auto &vec = reg[fd];
            vec.insert(vec.begin(), keep.begin(), keep.end());
        }
    }

    void run() {
#if defined(LIBIPC_OS_APPLE)
        for (;;) {
            struct kevent evs[64];
            int n = ::kevent(poll_fd, nullptr, 0, evs, 64, nullptr);
            if (stop.load(std::memory_order_acquire)) break;
            if (n < 0) {
                if (errno == EINTR) continue;
                break;
            }
            bool woke = false;
            for (int i = 0; i < n; ++i) {
                if (static_cast<int>(evs[i].ident) == wake_r) { woke = true; continue; }
            }
            if (woke) drain_wake();
            process_ctl();
            for (int i = 0; i < n; ++i) {
                int fd = static_cast<int>(evs[i].ident);
                if (fd == wake_r) continue;
                dispatch(fd);
            }
        }
#else
        for (;;) {
            epoll_event evs[64];
            int n = ::epoll_wait(poll_fd, evs, 64, -1);
            if (stop.load(std::memory_order_acquire)) break;
            if (n < 0) {
                if (errno == EINTR) continue;
                break;
            }
            bool woke = false;
            for (int i = 0; i < n; ++i) {
                if (evs[i].data.fd == wake_fd) { woke = true; }
            }
            if (woke) drain_wake();
            process_ctl();
            for (int i = 0; i < n; ++i) {
                int fd = evs[i].data.fd;
                if (fd == wake_fd) continue;
                dispatch(fd);
            }
        }
#endif
        // Final drain so any pending synchronous remove() unblocks at shutdown.
        process_ctl();
    }
};

reactor::reactor() : p_(new impl) {}
reactor::~reactor() { delete p_; }

reactor &reactor::instance() {
    static reactor r;
    return r;
}

void reactor::add(int fd, reactor_waiter *w) {
    {
        std::lock_guard<std::mutex> lk(p_->ctl_mtx);
        p_->ctl.push_back(ctl_item{ctl_item::add, fd, w, nullptr});
    }
    p_->wake();
}

void reactor::remove(int fd, reactor_waiter *w) {
    std::atomic<bool> done{false};
    {
        std::lock_guard<std::mutex> lk(p_->ctl_mtx);
        p_->ctl.push_back(ctl_item{ctl_item::remove, fd, w, &done});
    }
    p_->wake();
    std::unique_lock<std::mutex> lk(p_->ack_mtx);
    p_->ack_cv.wait(lk, [&] { return done.load(std::memory_order_acquire); });
}

} // namespace detail
} // namespace ipc

#endif // LIBIPC_NOTIFY_FD
