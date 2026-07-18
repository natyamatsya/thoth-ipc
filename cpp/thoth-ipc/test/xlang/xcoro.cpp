// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Cross-language async harness, C++ COROUTINE endpoint (path b): async receive
// via `co_await ipc::coro::async_recv_co(route)` — the stdexec-FREE coroutine
// front end, built with only THOTH_IPC_NOTIFY_FD (+ C++20/23). Same uniform CLI as
// the other harnesses so tools/xlang_matrix.py can pair it as an async receiver.
//
//   xcoro write <name> <count> <size>   send <count> pattern messages (posts notify)
//   xcoro aread <name> <count> <size>   coroutine async_recv + verify; exit 0 iff all match

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "thoth-ipc/ipc.h"
#include "thoth-ipc/execution/coro_recv.h"

namespace {

std::vector<char> pattern(std::size_t n) {
    std::vector<char> v(n);
    for (std::size_t i = 0; i < n; ++i) v[i] = char('A' + (i % 26));
    return v;
}

int do_write(const char *name, int count, std::size_t size) {
    ipc::route w{name, ipc::sender};
    if (!w.valid()) { std::fprintf(stderr, "[cpp-coro] connect(sender) failed\n"); return 3; }
    if (!w.wait_for_recv(1, 5000)) { std::fprintf(stderr, "[cpp-coro] no receiver within 5s\n"); return 2; }
    auto msg = pattern(size);
    for (int i = 0; i < count; ++i) {
        if (!w.send(msg.data(), msg.size())) { std::fprintf(stderr, "[cpp-coro] send %d failed\n", i); return 4; }
    }
    std::fprintf(stderr, "[cpp-coro] wrote %d x %zuB on '%s'\n", count, size, name);
    return 0;
}

// The coroutine: awaits `count` messages and verifies each. Returns an exit code.
ipc::coro::task<int> recv_loop(ipc::route &r, int count, std::size_t size) {
    auto want = pattern(size);
    for (int i = 0; i < count; ++i) {
        ipc::recv_result res = co_await ipc::coro::async_recv_co(r);
        if (!res.has_value()) { std::fprintf(stderr, "[cpp-coro] recv %d errc=%d\n", i, int(res.error())); co_return 5; }
        ipc::buff_t const &b = res.value();
        if (b.size() != size) { std::fprintf(stderr, "[cpp-coro] recv %d wrong size %zu\n", i, b.size()); co_return 6; }
        if (std::memcmp(b.data(), want.data(), size) != 0) { std::fprintf(stderr, "[cpp-coro] recv %d mismatch\n", i); co_return 7; }
    }
    std::fprintf(stderr, "[cpp-coro] async-read %d x %zuB OK\n", count, size);
    co_return 0;
}

int do_aread(const char *name, int count, std::size_t size) {
    ipc::route r{name, ipc::receiver};
    if (!r.valid()) { std::fprintf(stderr, "[cpp-coro] connect(receiver) failed\n"); return 3; }
    if (r.native_wait_handle() == ipc::invalid_wait_handle) {
        std::fprintf(stderr, "[cpp-coro] no readiness handle\n");
        return 8;
    }
    return recv_loop(r, count, size).sync_wait();
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: %s <write|aread|clear> <name> [count] [size]\n", argv[0]); return 1; }
    std::string verb = argv[1];
    const char *name = argv[2];
    if (verb == "clear") { ipc::route::clear_storage(name); return 0; }
    // Built with THOTH_IPC_NOTIFY_FD: posts notify + coroutine async_recv (no stdexec).
    if (verb == "caps") { std::printf("notify async\n"); return 0; }
    if (argc < 5) { std::fprintf(stderr, "write/aread need <count> <size>\n"); return 1; }
    int count = std::atoi(argv[3]);
    std::size_t size = static_cast<std::size_t>(std::atoll(argv[4]));
    if (verb == "write") return do_write(name, count, size);
    if (verb == "aread") return do_aread(name, count, size);
    std::fprintf(stderr, "unknown verb '%s'\n", verb.c_str());
    return 1;
}
