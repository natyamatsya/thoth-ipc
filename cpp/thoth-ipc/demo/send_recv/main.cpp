// Two processes share a multi-writer thoth::channel named "ipc".
//
// Usage:
//   send_recv send <size> <interval_ms> [count]
//   send_recv recv <interval_ms> [count]
//   send_recv clear
//
// The sender sends <size> raw bytes of 'A' (no trailing NUL) every
// <interval_ms> milliseconds; the receiver prints the size of every message.
// Without <count> both run until a signal (the receiver polls with an
// <interval_ms> timeout). With <count> the run is bounded: the receiver prints
// "recv ready" and exits 0 after <count> messages (exit 5 if one does not
// arrive within 10 s); the sender waits up to 5 s for a receiver (else exit 2),
// sends <count> messages with a 2 s send timeout (exit 4 on failure) and exits
// 0. `clear` removes the channel's storage.

#include <signal.h>

#include <iostream>
#include <string>
#include <thread>
#include <chrono>
#include <atomic>

#include "thoth-ipc/ipc.h"

namespace {

std::atomic<bool> is_quit__ {false};
thoth::channel *ipc__ = nullptr;

void do_send(int size, int interval) {
    thoth::channel ipc {"ipc", thoth::sender};
    ipc__ = &ipc;
    // Raw bytes, no trailing NUL: exactly <size> bytes, like the other ports.
    std::string buffer(size, 'A');
    while (!is_quit__.load(std::memory_order_acquire)) {
        std::cout << "send size: " << buffer.size() << std::endl;
        ipc.send(buffer.data(), buffer.size(), 0/*tm*/);
        std::this_thread::sleep_for(std::chrono::milliseconds(interval));
    }
}

void do_recv(int interval) {
    thoth::channel ipc {"ipc", thoth::receiver};
    ipc__ = &ipc;
    while (!is_quit__.load(std::memory_order_acquire)) {
        thoth::buff_t recv;
        for (int k = 1; recv.empty(); ++k) {
            std::cout << "recv waiting... " << k << std::endl;
            recv = ipc.recv(interval);
            if (is_quit__.load(std::memory_order_acquire)) return;
        }
        std::cout << "recv size: " << recv.size() << std::endl;
    }
}

// Bounded: wait for a receiver, then send <count> messages of <size> bytes.
int do_send_count(int size, int interval, int count) {
    thoth::channel ipc {"ipc", thoth::sender};
    ipc__ = &ipc;
    if (!ipc.wait_for_recv(1, 5000)) {
        std::cerr << "send: no receiver within 5s -- start the receiver first" << std::endl;
        return 2;
    }
    std::string buffer(size, 'A');
    for (int k = 0; k < count; ++k) {
        std::cout << "send size: " << buffer.size() << std::endl;
        if (!ipc.send(buffer.data(), buffer.size(), 2000)) {
            std::cerr << "send: failed to send message " << k << std::endl;
            return 4;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(interval));
    }
    return 0;
}

// Bounded: receive <count> messages, each within 10 s.
int do_recv_count(int count) {
    thoth::channel ipc {"ipc", thoth::receiver};
    ipc__ = &ipc;
    std::cout << "recv ready" << std::endl;
    for (int k = 0; k < count; ++k) {
        auto recv = ipc.recv(10000);
        if (recv.empty()) {
            std::cerr << "recv: timed out waiting for message " << k << std::endl;
            return 5;
        }
        std::cout << "recv size: " << recv.size() << std::endl;
    }
    return 0;
}

} // namespace

int main(int argc, char ** argv) {
    if (argc >= 2 && std::string{argv[1]} == "clear") {
        thoth::channel::clear_storage("ipc");
        return 0;
    }
    if (argc < 3) {
        std::cerr << "usage: send_recv send <size> <interval_ms> [count]\n"
                     "       send_recv recv <interval_ms> [count]\n"
                     "       send_recv clear" << std::endl;
        return -1;
    }

    auto exit = [](int) {
        is_quit__.store(true, std::memory_order_release);
        if (ipc__ != nullptr) ipc__->disconnect();
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
    if (mode == "send") {
        if (argc < 4) return -1;
        if (argc >= 5) {
            return do_send_count(std::stoi(argv[2]) /*size*/,
                                 std::stoi(argv[3]) /*interval*/,
                                 std::stoi(argv[4]) /*count*/);
        }
        do_send(std::stoi(argv[2]) /*size*/,
                std::stoi(argv[3]) /*interval*/);
    } else if (mode == "recv") {
        if (argc >= 4) return do_recv_count(std::stoi(argv[3]) /*count*/);
        do_recv(std::stoi(argv[2]) /*interval*/);
    }
    return 0;
}
