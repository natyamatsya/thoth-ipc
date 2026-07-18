// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Multi-writer ipc::channel fan-in aggregator.
//
// Usage (run the collector first, then one or more producers):
//   channel_aggregator collect <total>
//   channel_aggregator produce <id> <count>
//
// N producer processes each send() into ONE shared ipc::channel; a single
// collector recv()s the merged, correctly-reassembled stream and tallies it by
// producer. This is the pattern a single-writer ipc::route cannot express — a
// channel has multiple committing writers. The wire format is byte-exact across
// the C++, Rust, Swift and Zig ports, so producers and the collector can be any
// mix of languages (see the repo README).

#include <cstdlib>
#include <iostream>
#include <map>
#include <string>

#include "libipc/ipc.h"

namespace {

constexpr char const channel__[] = "ipc-aggregator";

int collect(std::size_t total) {
    ipc::channel ch { channel__, ipc::receiver };
    std::cout << "[collector] ready on '" << channel__ << "', expecting " << total
              << " messages from any number of producers" << std::endl;

    std::map<std::string, std::size_t> tally;
    std::size_t got = 0;
    while (got < total) {
        ipc::buff_t buf = ch.recv(10000); // 10s per-message timeout
        if (buf.empty()) {
            std::cerr << "[collector] timed out with " << got << "/" << total
                      << " received" << std::endl;
            break;
        }
        std::string msg(buf.get<char const *>(), buf.size());
        if (!msg.empty() && msg.back() == '\0') msg.pop_back();
        std::string producer = msg.substr(0, msg.find(" #"));
        ++tally[producer];
        ++got;
        std::cout << "[collector] " << got << "/" << total << "  " << msg << std::endl;
    }

    std::cout << "\n[collector] summary — " << got << " messages from " << tally.size()
              << " producer(s):" << std::endl;
    for (auto const &kv : tally) {
        std::cout << "    " << kv.first << "  " << kv.second << std::endl;
    }
    return 0;
}

int produce(std::string const &id, std::size_t count) {
    ipc::channel ch { channel__, ipc::sender };
    // A channel send reaches no one without a receiver — wait for the collector.
    if (!ch.wait_for_recv(1, 5000)) {
        std::cerr << "[producer " << id << "] no collector within 5s — start the collector first"
                  << std::endl;
        return 2;
    }
    for (std::size_t k = 0; k < count; ++k) {
        std::string msg = id + " #" + std::to_string(k);
        while (!ch.send(msg, 2000)) {} // retry while the ring is momentarily full
    }
    std::cout << "[producer " << id << "] sent " << count << " messages into '"
              << channel__ << "'" << std::endl;
    ch.disconnect();
    return 0;
}

} // namespace

int main(int argc, char **argv) {
    std::string const verb = (argc > 1) ? argv[1] : "";
    if (verb == "collect" && argc > 2) {
        return collect(std::strtoull(argv[2], nullptr, 10));
    }
    if (verb == "produce" && argc > 3) {
        return produce(argv[2], std::strtoull(argv[3], nullptr, 10));
    }
    std::cerr << "usage:\n  channel_aggregator collect <total>\n  "
                 "channel_aggregator produce <id> <count>" << std::endl;
    return 1;
}
