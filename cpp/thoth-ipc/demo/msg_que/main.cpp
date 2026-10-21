// demo/msg_que: thoth::route throughput benchmark, plus a bounded count mode.
//
// Usage:
//   msg_que s            sender: random-sized messages (128 B - 16 KB) until a signal
//   msg_que r            receiver: prints throughput until a signal
//   msg_que s <count>    sender: wait for a receiver (5 s, else exit 2), send <count>
//                        deterministic messages (k-th: size_k bytes of k % 251, with
//                        size_k = 128 + (k * 7919) % 16257), print a summary, exit 0
//   msg_que r <count>    receiver: print "do_recv: ready", receive and verify <count>
//                        messages (10 s timeout each, exit 5; corrupt: exit 6)
//   msg_que clear        remove the route's IPC objects
//
// Exit codes (count mode): 2 no receiver, 4 send failed, 5 recv timeout, 6 corrupt.

#include <signal.h>

#include <iostream>
#include <string>
#include <atomic>
#include <thread>
#include <chrono>
#include <cstddef>
#include <cstdlib>
#include <algorithm>
#include <vector>

#include "thoth-ipc/ipc.h"
#include "capo/random.hpp"

namespace {

constexpr char const name__  [] = "ipc-msg-que";
constexpr char const mode_s__[] = "s";
constexpr char const mode_r__[] = "r";

constexpr std::size_t const min_sz = 128;
constexpr std::size_t const max_sz = 1024 * 16;

std::atomic<bool> is_quit__ {false};
std::atomic<std::size_t> size_counter__ {0};

using msg_que_t = thoth::chan<thoth::relat::single, thoth::relat::multi, thoth::trans::broadcast>;

msg_que_t que__{ name__ };
thoth::byte_t buff__[max_sz];
capo::random<> rand__{ 
    static_cast<int>(min_sz), 
    static_cast<int>(max_sz)
};

inline std::string str_of_size(std::size_t sz) noexcept {
    if (sz > 1024 * 1024) {
        return std::to_string(sz / (1024 * 1024)) + " MB";
    }
    if (sz > 1024) {
        return std::to_string(sz / 1024) + " KB";
    }
    return std::to_string(sz) + " bytes";
}

inline std::string speed_of(std::size_t sz) noexcept {
    return str_of_size(sz) + "/s";
}

void do_counting() {
    for (int i = 1; !is_quit__.load(std::memory_order_acquire); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100)); // 100 ms
        if (i % 10) continue;
        i = 0;
        std::cout
            << speed_of(size_counter__.exchange(0, std::memory_order_relaxed))
            << std::endl;
    }
}

void do_send() {
    std::cout 
        << __func__ << ": start [" 
        << str_of_size(min_sz) << " - " << str_of_size(max_sz) 
        << "]...\n";
    if (!que__.reconnect(thoth::sender)) {
        std::cerr << __func__ << ": connect failed.\n";
    }
    else {
        std::thread counting{ do_counting };
        while (!is_quit__.load(std::memory_order_acquire)) {
            std::size_t sz = static_cast<std::size_t>(rand__());
            if (!que__.send(thoth::buff_t(buff__, sz))) {
                std::cerr << __func__ << ": send failed.\n";
                std::cout << __func__ << ": waiting for receiver...\n";
                if (!que__.wait_for_recv(1)) {
                    std::cerr << __func__ << ": wait receiver failed.\n";
                    is_quit__.store(true, std::memory_order_release);
                    break;
                }
            }
            size_counter__.fetch_add(sz, std::memory_order_relaxed);
            std::this_thread::yield();
        }
        counting.join();
    }
    std::cout << __func__ << ": quit...\n";
}

void do_recv() {
    std::cout
        << __func__ << ": start ["
        << str_of_size(min_sz) << " - " << str_of_size(max_sz)
        << "]...\n";
    if (!que__.reconnect(thoth::receiver)) {
        std::cerr << __func__ << ": connect failed.\n";
    }
    else {
        std::thread counting{ do_counting };
        while (!is_quit__.load(std::memory_order_acquire)) {
            auto msg = que__.recv();
            if (msg.empty()) break;
            size_counter__.fetch_add(msg.size(), std::memory_order_relaxed);
        }
        counting.join();
    }
    std::cout << __func__ << ": quit...\n";
}

// --- Count mode (deterministic, verifiable; used by the cross-language runner) ---

std::size_t size_of_k(std::size_t k) noexcept {
    return min_sz + (k * 7919) % (max_sz - min_sz + 1);
}

thoth::byte_t byte_of_k(std::size_t k) noexcept {
    return static_cast<thoth::byte_t>(k % 251);
}

int do_send_count(std::size_t count) {
    if (!que__.reconnect(thoth::sender)) {
        std::cerr << "do_send: connect failed." << std::endl;
        return 3;
    }
    if (!que__.wait_for_recv(1, 5000)) {
        std::cerr << "do_send: no receiver within 5 s." << std::endl;
        return 2;
    }
    std::vector<thoth::byte_t> buf(max_sz);
    std::size_t total = 0;
    for (std::size_t k = 0; k < count; ++k) {
        std::size_t sz = size_of_k(k);
        std::fill(buf.begin(), buf.begin() + static_cast<std::ptrdiff_t>(sz), byte_of_k(k));
        if (!que__.send(buf.data(), sz, 2000)) {
            std::cerr << "do_send: send of message " << k << " failed." << std::endl;
            return 4;
        }
        total += sz;
    }
    std::cout << "do_send: sent " << count << " messages, " << total << " bytes" << std::endl;
    return 0;
}

int do_recv_count(std::size_t count) {
    if (!que__.reconnect(thoth::receiver)) {
        std::cerr << "do_recv: connect failed." << std::endl;
        return 3;
    }
    std::cout << "do_recv: ready" << std::endl;
    std::size_t total = 0;
    for (std::size_t k = 0; k < count; ++k) {
        auto msg = que__.recv(10000);
        if (msg.empty()) {
            std::cerr << "do_recv: timed out after " << k << "/" << count << " messages." << std::endl;
            return 5;
        }
        auto const * p = static_cast<thoth::byte_t const *>(msg.data());
        std::size_t sz = msg.size();
        bool ok = sz >= min_sz && sz <= max_sz
               && sz == size_of_k(k) && p[0] == byte_of_k(k);
        for (std::size_t i = 1; ok && i < sz; ++i) ok = (p[i] == p[0]);
        if (!ok) {
            std::cerr << "do_recv: message " << k << " is corrupt (" << sz
                      << " bytes, expected " << size_of_k(k) << " bytes of "
                      << static_cast<unsigned>(byte_of_k(k)) << ")." << std::endl;
            return 6;
        }
        total += sz;
    }
    std::cout << "do_recv: received " << count << " messages, " << total << " bytes" << std::endl;
    return 0;
}

} // namespace

int main(int argc, char ** argv) {
    if (argc < 2) return 0;

    auto exit = [](int) {
        is_quit__.store(true, std::memory_order_release);
        que__.disconnect();
    };
    ::signal(SIGINT  , exit);
    ::signal(SIGABRT , exit);
    ::signal(SIGSEGV , exit);
    ::signal(SIGTERM , exit);
#if defined(WIN64) || defined(_WIN64) || defined(__WIN64__) || \
    defined(WIN32) || defined(_WIN32) || defined(__WIN32__) || defined(__NT__) || \
    defined(WINCE) || defined(_WIN32_WCE)
    ::signal(SIGBREAK, exit);
#else
    ::signal(SIGHUP  , exit);
#endif

    std::string mode {argv[1]};
    if (mode == "clear") {
        que__.clear(); // the global route is already open: clear under its handle
        return 0;
    }
    if (argc >= 3 && (mode == mode_s__ || mode == mode_r__)) {
        auto count = static_cast<std::size_t>(std::strtoull(argv[2], nullptr, 10));
        return (mode == mode_s__) ? do_send_count(count) : do_recv_count(count);
    }
    if (mode == mode_s__) {
        do_send();
    } else if (mode == mode_r__) {
        do_recv();
    }
    return 0;
}
