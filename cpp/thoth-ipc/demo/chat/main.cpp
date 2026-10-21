// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Multi-party chat over one multi-writer thoth::channel ("ipc-chat").
//
// Usage:
//   chat                      interactive: type words, "q" quits
//   chat bot <lines> <peers>  scripted: wait for <peers> chatters (itself
//                             included), send "cN> line-<i>" <lines> times and
//                             exit once it has <lines> lines from every other one
//   chat clear                remove the channel and the id counter
//
// Each instance draws its id cN from a shared shm counter. The wire format
// ("cN> text" plus a trailing NUL, "cN> q" to quit) is byte-exact across the
// C++, Rust, Swift and Zig ports, so chatters can be any mix of languages.

#include <cstdlib>
#include <iostream>
#include <map>
#include <string>
#include <thread>
#include <regex>
#include <atomic>

#include "thoth-ipc/ipc.h"

namespace {

constexpr char const name__[] = "ipc-chat";
constexpr char const quit__[] = "q";
constexpr char const id__  [] = "c";
constexpr char const acc__ [] = "__CHAT_ACC_STORAGE__";

inline std::size_t calc_unique_id() {
    static thoth::shm::handle g_shm { acc__, sizeof(std::atomic<std::size_t>) };
    return static_cast<std::atomic<std::size_t>*>(g_shm.get())->fetch_add(1, std::memory_order_relaxed);
}

int interactive() {
    thoth::channel sender__   { name__, thoth::sender   };
    thoth::channel receiver__ { name__, thoth::receiver };

    std::string buf, id = id__ + std::to_string(calc_unique_id());
    std::regex  reg { "(c\\d+)> (.*)" };

    std::thread r {[&id, &reg, &receiver__] {
        std::cout << id << " is ready." << std::endl;
        while (1) {
            thoth::buff_t buf = receiver__.recv();
            if (buf.empty()) break; // quit
            std::string dat { buf.get<char const *>(), buf.size() - 1 };
            std::smatch mid;
            if (std::regex_match(dat, mid, reg)) {
                if (mid.str(1) == id) {
                    if (mid.str(2) == quit__) {
                        break;
                    }
                    continue;
                }
            }
            std::cout << dat << std::endl;
        }
        std::cout << id << " receiver is quit..." << std::endl;
    }};

    for (/*int i = 1*/;; /*++i*/) {
        std::cin >> buf;
        if (buf.empty() || (buf == quit__)) break;
//        std::cout << "[" << i << "]" << std::endl;
        sender__.send(id + "> " + buf);
        buf.clear();
    }

    receiver__.disconnect();
    r.join();
    std::cout << id << " sender is quit..." << std::endl;
    return 0;
}

// Scripted chatter: rendezvous with <peers> receivers, send <lines> lines,
// then read until every other chatter's <lines> lines have arrived.
int bot(std::size_t lines, std::size_t peers) {
    thoth::channel sender   { name__, thoth::sender   };
    thoth::channel receiver { name__, thoth::receiver };

    std::string const id = id__ + std::to_string(calc_unique_id());
    std::regex  reg { "(c\\d+)> (.*)" };
    std::cout << id << " is ready." << std::endl;

    if (!sender.wait_for_recv(peers, 10000)) {
        std::cerr << id << ": " << peers << " chatters did not show up within 10s" << std::endl;
        return 2;
    }
    for (std::size_t i = 0; i < lines; ++i) {
        if (!sender.send(id + "> line-" + std::to_string(i))) {
            std::cerr << id << ": send failed" << std::endl;
            return 4;
        }
    }

    std::map<std::string, std::size_t> got; // foreign id -> lines received
    std::size_t done = 0;                   // foreign ids with all <lines> lines
    while (lines > 0 && done + 1 < peers) {
        thoth::buff_t buf = receiver.recv(10000);
        if (buf.empty()) {
            std::cerr << id << ": timed out waiting for chat lines" << std::endl;
            return 5;
        }
        std::string dat { buf.get<char const *>(), buf.size() - 1 };
        std::smatch mid;
        if (std::regex_match(dat, mid, reg)) {
            if (mid.str(1) == id || mid.str(2) == quit__) continue;
            if (++got[mid.str(1)] == lines) ++done;
        }
        std::cout << dat << std::endl;
    }
    return 0;
}

} // namespace

int main(int argc, char **argv) {
    std::string const verb = (argc > 1) ? argv[1] : "";
    if (verb.empty()) return interactive();
    if (verb == "bot" && argc > 3) {
        return bot(std::strtoull(argv[2], nullptr, 10), std::strtoull(argv[3], nullptr, 10));
    }
    if (verb == "clear") {
        thoth::channel::clear_storage(name__);
        thoth::shm::handle::clear_storage(acc__);
        return 0;
    }
    std::cerr << "usage:\n  chat\n  chat bot <lines> <peers>\n  chat clear" << std::endl;
    return 1;
}
