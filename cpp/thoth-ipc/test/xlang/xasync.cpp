// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Cross-language ASYNC round-trip harness (C++ endpoint, Layer 2). Same uniform
// CLI as xlang_ipc, but the reader uses thoth::async_recv() — the stdexec sender +
// process-global reactor woken by the Layer-1 notify fd — instead of a blocking
// recv(). Built only when THOTH_IPC_STDEXEC (which implies THOTH_IPC_NOTIFY_FD) is on.
//
//   xasync write <name> <count> <size>   send <count> pattern messages (posts notify)
//   xasync aread <name> <count> <size>   async_recv+verify; exit 0 iff all match
//
// Purpose: prove the notify+reactor readiness path wakes cross-process on Darwin,
// and (paired against the Rust/Swift notify source) that a port send() wakes a
// C++ async receiver. Payload pattern: byte[i] = 'A' + (i % 26).

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <exec/static_thread_pool.hpp>
#include <stdexec/execution.hpp>

#include "thoth-ipc/async_recv.h"
#include "thoth-ipc/ipc.h"

namespace {

std::vector<char> pattern(std::size_t n) {
    std::vector<char> v(n);
    for (std::size_t i = 0; i < n; ++i) v[i] = char('A' + (i % 26));
    return v;
}

int do_write(const char* name, int count, std::size_t size) {
    thoth::route w{name, thoth::sender};
    if (!w.valid()) { std::fprintf(stderr, "[cpp-async] connect(sender) failed\n"); return 3; }
    if (!w.wait_for_recv(1, 5000)) { std::fprintf(stderr, "[cpp-async] no receiver within 5s\n"); return 2; }
    auto msg = pattern(size);
    for (int i = 0; i < count; ++i) {
        if (!w.send(msg.data(), msg.size())) { std::fprintf(stderr, "[cpp-async] send %d failed\n", i); return 4; }
    }
    std::fprintf(stderr, "[cpp-async] wrote %d x %zuB on '%s'\n", count, size, name);
    return 0;
}

int do_recv(const char* name, int count, std::size_t size) {
    thoth::route r{name, thoth::receiver};
    if (!r.valid()) { std::fprintf(stderr, "[cpp-async] connect(receiver) failed\n"); return 3; }
    if (r.native_wait_handle() == thoth::invalid_wait_handle) {
        std::fprintf(stderr, "[cpp-async] no readiness handle (build without THOTH_IPC_NOTIFY_FD?)\n");
        return 8;
    }
    exec::static_thread_pool pool{1};
    auto sched = pool.get_scheduler();
    auto want = pattern(size);
    for (int i = 0; i < count; ++i) {
        auto outcome = stdexec::sync_wait(thoth::async_recv(r, sched));
        if (!outcome) { std::fprintf(stderr, "[cpp-async] recv %d cancelled\n", i); return 5; }
        thoth::recv_result const& rr = std::get<0>(*outcome);
        if (!rr.has_value()) {
            std::fprintf(stderr, "[cpp-async] recv %d errc=%d\n", i, int(rr.error()));
            return 6;
        }
        thoth::buff_t const& b = rr.value();
        if (b.size() != size) {
            std::fprintf(stderr, "[cpp-async] recv %d wrong size: got %zu want %zu\n", i, b.size(), size);
            return 6;
        }
        if (std::memcmp(b.data(), want.data(), size) != 0) {
            std::fprintf(stderr, "[cpp-async] recv %d payload mismatch\n", i);
            return 7;
        }
    }
    std::fprintf(stderr, "[cpp-async] async-read %d x %zuB on '%s' OK\n", count, size, name);
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: %s <write|recv|clear> <name> [count] [size]\n", argv[0]);
        return 1;
    }
    std::string verb = argv[1];
    const char* name = argv[2];
    if (verb == "clear") { thoth::route::clear_storage(name); return 0; }
    // Built with THOTH_IPC_STDEXEC (⇒ THOTH_IPC_NOTIFY_FD): posts notify + async_recv.
    if (verb == "caps") { std::printf("notify async\n"); return 0; }
    if (argc < 5) { std::fprintf(stderr, "write/aread need <count> <size>\n"); return 1; }
    int count = std::atoi(argv[3]);
    std::size_t size = static_cast<std::size_t>(std::atoll(argv[4]));
    if (verb == "write") return do_write(name, count, size);
    if (verb == "aread") return do_recv(name, count, size);
    std::fprintf(stderr, "unknown verb '%s'\n", verb.c_str());
    return 1;
}
