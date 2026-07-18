// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Polyglot pipeline stage — one hop of a multi-language thoth::route pipeline.
//
// Usage:
//   pipeline source <out> <count> <tag>
//   pipeline stage  <in> <out> <count> <tag>
//   pipeline sink   <in> <count> <tag>
//
// A pipeline is a chain of single-writer->single-reader thoth::route hops, each
// hop a separate process — and, because the wire format is byte-exact across
// the C++, Rust, Swift and Zig ports, each stage can be a *different language*.
// The source seeds items, every stage appends its tag, and the sink prints the
// fully-transformed item, so one printed line shows every language a message
// passed through. See demo/pipeline/run.sh and the repo README.

#include <cstdlib>
#include <iostream>
#include <string>

#include "thoth-ipc/ipc.h"

namespace {

std::string decode(thoth::buff_t const &buf) {
    std::string s(buf.get<char const *>(), buf.size());
    if (!s.empty() && s.back() == '\0') s.pop_back();
    return s;
}

int source(char const *out, std::size_t count, std::string const &tag) {
    thoth::route tx { out, thoth::sender };
    if (!tx.wait_for_recv(1, 5000)) {
        std::cerr << "[source " << tag << "] no downstream on '" << out << "' within 5s" << std::endl;
        return 2;
    }
    for (std::size_t k = 0; k < count; ++k) {
        std::string msg = "item-" + std::to_string(k) + " [" + tag + "]";
        while (!tx.send(msg, 2000)) {}
    }
    std::cerr << "[source " << tag << "] emitted " << count << " items -> '" << out << "'" << std::endl;
    return 0;
}

int stage(char const *in, char const *out, std::size_t count, std::string const &tag) {
    thoth::route rx { in,  thoth::receiver };
    thoth::route tx { out, thoth::sender };
    if (!tx.wait_for_recv(1, 5000)) {
        std::cerr << "[stage " << tag << "] no downstream on '" << out << "' within 5s" << std::endl;
        return 2;
    }
    for (std::size_t i = 0; i < count; ++i) {
        thoth::buff_t buf = rx.recv(10000);
        if (buf.empty()) { std::cerr << "[stage " << tag << "] upstream stalled" << std::endl; return 5; }
        std::string msg = decode(buf) + " -> " + tag;
        while (!tx.send(msg, 2000)) {}
    }
    std::cerr << "[stage " << tag << "] forwarded " << count << " items '" << in << "' -> '" << out << "'" << std::endl;
    return 0;
}

int sink(char const *in, std::size_t count, std::string const &tag) {
    thoth::route rx { in, thoth::receiver };
    std::cerr << "[sink " << tag << "] ready on '" << in << "', expecting " << count << " items" << std::endl;
    for (std::size_t i = 0; i < count; ++i) {
        thoth::buff_t buf = rx.recv(10000);
        if (buf.empty()) { std::cerr << "[sink " << tag << "] upstream stalled after " << i << "/" << count << std::endl; break; }
        std::cout << decode(buf) << " -> [" << tag << " sink]" << std::endl;
    }
    return 0;
}

} // namespace

int main(int argc, char **argv) {
    std::string const verb = (argc > 1) ? argv[1] : "";
    auto num = [&](int i) { return std::strtoull(argv[i], nullptr, 10); };
    if (verb == "source" && argc >= 5) return source(argv[2], num(3), argv[4]);
    if (verb == "stage"  && argc >= 6) return stage(argv[2], argv[3], num(4), argv[5]);
    if (verb == "sink"   && argc >= 5) return sink(argv[2], num(3), argv[4]);
    std::cerr << "usage:\n  pipeline source <out> <count> <tag>\n  "
                 "pipeline stage <in> <out> <count> <tag>\n  "
                 "pipeline sink <in> <count> <tag>" << std::endl;
    return 1;
}
