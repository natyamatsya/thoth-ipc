// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Cross-language round-trip harness (C++ endpoint). One binary, three verbs,
// a uniform CLI contract shared by the Rust and Swift harnesses so the
// tools/xlang_matrix.py driver can pair any writer language with any reader
// language on the same ipc::route wire ABI.
//
//   xlang_ipc write <name> <count> <size>   send <count> pattern messages
//   xlang_ipc read  <name> <count> <size>   recv+verify; exit 0 iff all match
//   xlang_ipc clear <name>                  unlink the channel's shm segments
//
// Payload pattern: byte[i] = 'A' + (i % 26). The reader checks length + bytes.

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "libipc/ipc.h"

namespace {

std::vector<char> pattern(std::size_t n) {
    std::vector<char> v(n);
    for (std::size_t i = 0; i < n; ++i) v[i] = char('A' + (i % 26));
    return v;
}

int do_write(const char* name, int count, std::size_t size) {
    ipc::route w{name, ipc::sender};
    if (!w.valid()) { std::fprintf(stderr, "[cpp] connect(sender) failed\n"); return 3; }
    if (!w.wait_for_recv(1, 5000)) { std::fprintf(stderr, "[cpp] no receiver within 5s\n"); return 2; }
    auto msg = pattern(size);
    for (int i = 0; i < count; ++i) {
        if (!w.send(msg.data(), msg.size())) { std::fprintf(stderr, "[cpp] send %d failed\n", i); return 4; }
    }
    std::fprintf(stderr, "[cpp] wrote %d x %zuB on '%s'\n", count, size, name);
    return 0;
}

int do_read(const char* name, int count, std::size_t size) {
    ipc::route r{name, ipc::receiver};
    if (!r.valid()) { std::fprintf(stderr, "[cpp] connect(receiver) failed\n"); return 3; }
    auto want = pattern(size);
    for (int i = 0; i < count; ++i) {
        ipc::buff_t b = r.recv(8000);
        if (b.empty()) { std::fprintf(stderr, "[cpp] recv %d timed out\n", i); return 5; }
        if (b.size() != size) {
            std::fprintf(stderr, "[cpp] recv %d wrong size: got %zu want %zu\n", i, b.size(), size);
            return 6;
        }
        if (std::memcmp(b.data(), want.data(), size) != 0) {
            std::fprintf(stderr, "[cpp] recv %d payload mismatch\n", i);
            return 7;
        }
    }
    std::fprintf(stderr, "[cpp] read %d x %zuB on '%s' OK\n", count, size, name);
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: %s <write|read|clear> <name> [count] [size]\n", argv[0]);
        return 1;
    }
    std::string verb = argv[1];
    const char* name = argv[2];
    if (verb == "clear") { ipc::route::clear_storage(name); return 0; }
    // Observe the receiver count WITHOUT side effects (a sender neither claims a
    // receiver slot nor reaps).
    if (verb == "probe") {
        ipc::route s{name, ipc::sender};
        std::printf("%zu\n", s.recv_count());
        return 0;
    }
    // Connect a RECEIVER (reap-on-connect runs), then report the count. Used to
    // check that a dead cross-language receiver was reaped (and a live one wasn't).
    if (verb == "count") {
        ipc::route r{name, ipc::receiver};
        std::printf("%zu\n", r.recv_count());
        return 0;
    }
    // Connect a receiver and hold it (populating the owner table), so a test can
    // SIGKILL this process and check a reaper reclaims the slot.
    if (verb == "hold") {
        int secs = (argc > 3) ? std::atoi(argv[3]) : 30;
        ipc::route r{name, ipc::receiver};
        std::printf("READY\n");
        std::fflush(stdout);
        std::this_thread::sleep_for(std::chrono::seconds(secs));
        return 0;
    }
    if (argc < 5) { std::fprintf(stderr, "write/read need <count> <size>\n"); return 1; }
    int count = std::atoi(argv[3]);
    std::size_t size = static_cast<std::size_t>(std::atoll(argv[4]));
    if (verb == "write") return do_write(name, count, size);
    if (verb == "read")  return do_read(name, count, size);
    std::fprintf(stderr, "unknown verb '%s'\n", verb.c_str());
    return 1;
}
