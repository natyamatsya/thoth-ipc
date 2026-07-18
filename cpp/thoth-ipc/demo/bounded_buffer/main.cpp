// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Cross-language bounded buffer — the classic producer/consumer problem solved
// with the byte-exact named IPC primitives.
//
// Usage (run the consumer first, then one or more producers):
//   bounded_buffer consume <total>
//   bounded_buffer produce <id> <count>
//
// A fixed-capacity ring lives in a shared-memory segment; access is coordinated
// by a named thoth::sync::mutex (so multiple producers can contend for `head`) and
// two counting thoth::sync::semaphores — `empty` (free slots, starts at CAP) and
// `full` (filled slots, starts at 0). Producers and the consumer can be
// *different languages*: the shm layout, the mutex and both semaphores are
// byte-exact across the C++, Rust, Swift and Zig ports.

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <map>
#include <string>

#include "thoth-ipc/shm.h"
#include "thoth-ipc/mutex.h"
#include "thoth-ipc/semaphore.h"

namespace {

constexpr char const SHM[]   = "__BBUF__";
constexpr char const MUTEX[] = "bbuf_m";
constexpr char const EMPTY[] = "bbuf_e";
constexpr char const FULL[]  = "bbuf_f";
constexpr std::uint32_t CAP  = 4;
constexpr std::size_t   SLOT = 48;
constexpr std::size_t   SHM_SIZE = 8 + CAP * SLOT;

struct Ring {
    thoth::shm::handle shm { SHM, SHM_SIZE };
    std::uint8_t *base() const { return static_cast<std::uint8_t *>(shm.get()); }
    Ring() {
        if (shm.ref() <= 1) { set_head(0); set_tail(0); } // first opener zeroes cursors
    }
    std::uint32_t head() const { return *reinterpret_cast<volatile std::uint32_t *>(base()); }
    std::uint32_t tail() const { return *reinterpret_cast<volatile std::uint32_t *>(base() + 4); }
    void set_head(std::uint32_t v) { *reinterpret_cast<volatile std::uint32_t *>(base()) = v; }
    void set_tail(std::uint32_t v) { *reinterpret_cast<volatile std::uint32_t *>(base() + 4) = v; }
    std::uint8_t *slot(std::uint32_t idx) const { return base() + 8 + idx * SLOT; }
};

int produce(std::string const &id, std::size_t count) {
    Ring ring;
    thoth::sync::mutex mtx { MUTEX };
    thoth::sync::semaphore empty { EMPTY, CAP };
    thoth::sync::semaphore full  { FULL, 0 };

    for (std::size_t k = 0; k < count; ++k) {
        if (!empty.wait(10000)) {
            std::cerr << "[producer " << id << "] no free slot within 10s" << std::endl;
            return 2;
        }
        mtx.lock();
        std::uint32_t idx = ring.head();
        ring.set_head((idx + 1) % CAP);
        std::string msg = id + " #" + std::to_string(k);
        std::size_t n = std::min(msg.size(), SLOT - 1);
        std::memcpy(ring.slot(idx), msg.data(), n);
        ring.slot(idx)[n] = 0;
        mtx.unlock();
        full.post(1);
    }
    std::cerr << "[producer " << id << "] produced " << count << " items" << std::endl;
    return 0;
}

int consume(std::size_t total) {
    Ring ring;
    thoth::sync::mutex mtx { MUTEX };
    thoth::sync::semaphore empty { EMPTY, CAP };
    thoth::sync::semaphore full  { FULL, 0 };
    std::cout << "[consumer] ready — draining " << total << " items through a " << CAP
              << "-slot ring" << std::endl;

    std::map<std::string, std::size_t> tally;
    std::size_t done = 0;
    for (std::size_t i = 0; i < total; ++i) {
        if (!full.wait(10000)) {
            std::cerr << "[consumer] no item within 10s after " << i << "/" << total << std::endl;
            break;
        }
        mtx.lock();
        std::uint32_t idx = ring.tail();
        ring.set_tail((idx + 1) % CAP);
        std::string msg(reinterpret_cast<char const *>(ring.slot(idx)));
        mtx.unlock();
        empty.post(1);
        ++tally[msg.substr(0, msg.find(" #"))];
        ++done;
        std::cout << "[consumer] " << (i + 1) << "/" << total << "  " << msg << std::endl;
    }

    std::cout << "\n[consumer] summary — " << done << " items from " << tally.size()
              << " producer(s):" << std::endl;
    for (auto const &kv : tally) std::cout << "    " << kv.first << "  " << kv.second << std::endl;
    return 0;
}

} // namespace

int main(int argc, char **argv) {
    std::string const verb = (argc > 1) ? argv[1] : "";
    if (verb == "consume" && argc >= 3) return consume(std::strtoull(argv[2], nullptr, 10));
    if (verb == "produce" && argc >= 4) return produce(argv[2], std::strtoull(argv[3], nullptr, 10));
    std::cerr << "usage:\n  bounded_buffer consume <total>\n  "
                 "bounded_buffer produce <id> <count>" << std::endl;
    return 1;
}
