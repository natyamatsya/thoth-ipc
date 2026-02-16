// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <chrono>
#include <random>

#include "libipc/ipc.h"

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static std::atomic<bool> g_ready{false};
static std::atomic<bool> g_done{false};

static void wait_ready() {
    while (!g_ready.load(std::memory_order_acquire))
        std::this_thread::yield();
}

struct Stats {
    double total_ms;
    std::size_t count;
    double us_per_datum() const { return (total_ms * 1000.0) / count; }
};

// ---------------------------------------------------------------------------
// ipc::route  —  1 sender, N receivers  (random msg_lo–msg_hi bytes × count)
// ---------------------------------------------------------------------------

static Stats bench_route(int n_receivers, std::size_t count,
                         std::size_t msg_lo, std::size_t msg_hi) {
    const char* name = "bench_route";

    std::vector<std::thread> threads;

    // prepare random payloads
    std::mt19937 rng(42);
    std::uniform_int_distribution<std::size_t> dist(msg_lo, msg_hi);
    std::vector<std::size_t> sizes(count);
    for (auto& s : sizes) s = dist(rng);
    std::vector<char> payload(msg_hi, 'X');

    // sender (created first so shm exists for receivers)
    ipc::route sender(name, ipc::sender);

    // receivers
    for (int i = 0; i < n_receivers; ++i) {
        threads.emplace_back([&, name] {
            ipc::route r(name, ipc::receiver);
            wait_ready();
            while (!g_done.load(std::memory_order_acquire)) {
                auto buf = r.recv(100);
            }
        });
    }

    // let receivers connect
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    g_ready.store(true, std::memory_order_release);

    auto t0 = std::chrono::steady_clock::now();

    for (std::size_t i = 0; i < count; ++i)
        sender.send(payload.data(), sizes[i]);

    auto t1 = std::chrono::steady_clock::now();
    double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    // signal done, disconnect sender to unblock receivers, then join
    g_done.store(true, std::memory_order_release);
    sender.disconnect();
    for (auto& t : threads) t.join();

    g_ready.store(false);
    g_done.store(false);

    return {ms, count};
}

// ---------------------------------------------------------------------------
// ipc::channel  —  pattern  (random msg_lo–msg_hi bytes × count)
//   pattern: "1-N"  = 1 sender,  N receivers
//            "N-1"  = N senders, 1 receiver
//            "N-N"  = N senders, N receivers
// ---------------------------------------------------------------------------

static Stats bench_channel(const std::string& pattern, int n,
                           std::size_t count, std::size_t msg_lo,
                           std::size_t msg_hi) {
    const char* name = "bench_chan";

    int n_senders   = (pattern == "N-1" || pattern == "N-N") ? n : 1;
    int n_receivers = (pattern == "1-N" || pattern == "N-N") ? n : 1;

    std::size_t per_sender = count / static_cast<std::size_t>(n_senders);

    // prepare random payloads
    std::mt19937 rng(42);
    std::uniform_int_distribution<std::size_t> dist(msg_lo, msg_hi);
    std::vector<std::size_t> sizes(count);
    for (auto& s : sizes) s = dist(rng);
    std::vector<char> payload(msg_hi, 'X');

    // a "control" channel to keep shm alive; also used to disconnect receivers
    ipc::channel ctrl(name, ipc::sender);

    std::vector<std::thread> recv_threads;

    // receivers
    for (int i = 0; i < n_receivers; ++i) {
        recv_threads.emplace_back([&, name] {
            ipc::channel ch(name, ipc::receiver);
            wait_ready();
            while (!g_done.load(std::memory_order_acquire)) {
                auto buf = ch.recv(100);
            }
        });
    }

    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    g_ready.store(true, std::memory_order_release);

    auto t0 = std::chrono::steady_clock::now();

    // senders
    std::vector<std::thread> sender_threads;
    for (int s = 0; s < n_senders; ++s) {
        sender_threads.emplace_back([&, s, per_sender, name] {
            ipc::channel ch(name, ipc::sender);
            std::size_t base = static_cast<std::size_t>(s) * per_sender;
            for (std::size_t i = 0; i < per_sender; ++i)
                ch.send(payload.data(), sizes[base + i]);
        });
    }
    for (auto& t : sender_threads) t.join();

    auto t1 = std::chrono::steady_clock::now();
    double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    g_done.store(true, std::memory_order_release);
    ctrl.disconnect();
    for (auto& t : recv_threads) t.join();

    g_ready.store(false);
    g_done.store(false);

    return {ms, count};
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

static void print_header(const char* title) {
    printf("\n=== %s ===\n", title);
}

int main(int argc, char** argv) {
    int max_threads = 8;
    if (argc > 1) max_threads = std::atoi(argv[1]);

    // -----------------------------------------------------------------------
    printf("cpp-ipc benchmark\n");
    printf("Platform: ");
#if defined(__APPLE__)
    printf("macOS");
#elif defined(__linux__)
    printf("Linux");
#elif defined(_WIN32)
    printf("Windows");
#else
    printf("Unknown");
#endif
    printf(", %u hardware threads\n", std::thread::hardware_concurrency());

    // -----------------------------------------------------------------------
    print_header("ipc::route — 1 sender, N receivers (random 2-256 bytes x 100000)");
    printf("%10s  %12s  %12s\n", "Receivers", "RTT (ms)", "us/datum");
    printf("%10s  %12s  %12s\n", "----------", "----------", "----------");

    for (int n = 1; n <= max_threads; n *= 2) {
        auto s = bench_route(n, 100000, 2, 256);
        printf("%10d  %12.2f  %12.3f\n", n, s.total_ms, s.us_per_datum());
    }

    // -----------------------------------------------------------------------
    print_header("ipc::channel — 1-N (random 2-256 bytes x 100000)");
    printf("%10s  %12s  %12s\n", "Receivers", "RTT (ms)", "us/datum");
    printf("%10s  %12s  %12s\n", "----------", "----------", "----------");

    for (int n = 1; n <= max_threads; n *= 2) {
        auto s = bench_channel("1-N", n, 100000, 2, 256);
        printf("%10d  %12.2f  %12.3f\n", n, s.total_ms, s.us_per_datum());
    }

    // -----------------------------------------------------------------------
    print_header("ipc::channel — N-1 (random 2-256 bytes x 100000)");
    printf("%10s  %12s  %12s\n", "Senders", "RTT (ms)", "us/datum");
    printf("%10s  %12s  %12s\n", "----------", "----------", "----------");

    for (int n = 1; n <= max_threads; n *= 2) {
        auto s = bench_channel("N-1", n, 100000, 2, 256);
        printf("%10d  %12.2f  %12.3f\n", n, s.total_ms, s.us_per_datum());
    }

    // -----------------------------------------------------------------------
    print_header("ipc::channel — N-N (random 2-256 bytes x 100000)");
    printf("%10s  %12s  %12s\n", "Threads", "RTT (ms)", "us/datum");
    printf("%10s  %12s  %12s\n", "----------", "----------", "----------");

    for (int n = 1; n <= max_threads; n *= 2) {
        auto s = bench_channel("N-N", n, 100000, 2, 256);
        printf("%10d  %12.2f  %12.3f\n", n, s.total_ms, s.us_per_datum());
    }

    printf("\nDone.\n");
    return 0;
}
