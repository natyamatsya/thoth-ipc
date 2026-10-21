/// \brief To create a basic command line program.
//
// Usage (start the client first, then the service):
//   linux_client            answer every "Hello, World!" with "Copy.", forever
//   linux_client <count>    answer <count> messages, then exit
//
// The client receives on "service ipc r" and replies on "service ipc w" (both
// multi-writer thoth::channel). Strings go on the wire with their trailing NUL;
// the Rust and Zig ports are wire-identical, so the client and the service can
// be any mix of languages. `linux_service clear` removes both channels.

#include <stdio.h>
#include <stdlib.h>
#include <string>
#include <thread>
#include <chrono>

#include "thoth-ipc/ipc.h"

namespace {

/// The payload without the trailing NUL the senders append.
std::string text_of(thoth::buff_t const &msg) {
    auto p = static_cast<char const *>(msg.data());
    std::size_t n = msg.size();
    if (n > 0 && p[n - 1] == '\0') --n;
    return std::string(p, n);
}

int run_forever(thoth::channel &ipc_r, thoth::channel &ipc_w) {
    while (1) {
        auto msg = ipc_r.recv();
        if (msg.empty()) {
            printf("My Sample Client: message recv error\n");
            return -1;
        }
        printf("My Sample Client: message recv: [%s]\n", text_of(msg).c_str());
        while (!ipc_w.send("Copy.")) {
            printf("My Sample Client: message send error\n");
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
        printf("My Sample Client: message send [Copy]\n");
    }
}

int run_count(thoth::channel &ipc_r, thoth::channel &ipc_w, unsigned long long count) {
    for (unsigned long long k = 0; k < count; ++k) {
        auto msg = ipc_r.recv(10000);
        if (msg.empty()) {
            fprintf(stderr, "My Sample Client: message recv timed out\n");
            return 5;
        }
        printf("My Sample Client: message recv: [%s]\n", text_of(msg).c_str());
        // The service's receiver must be there before the first reply.
        if (k == 0 && !ipc_w.wait_for_recv(1, 5000)) {
            fprintf(stderr, "My Sample Client: no service receiver within 5s\n");
            return 2;
        }
        if (!ipc_w.send("Copy.")) {
            fprintf(stderr, "My Sample Client: message send error\n");
            return 4;
        }
        printf("My Sample Client: message send [Copy]\n");
    }
    return 0;
}

} // namespace

int main(int argc, char *argv[]) {
    setvbuf(stdout, nullptr, _IOLBF, 0); // one flushed line per status line
    char *end = nullptr;
    unsigned long long count = argc > 1 ? strtoull(argv[1], &end, 10) : 0;
    if (argc > 2 || (argc > 1 && (end == argv[1] || *end != '\0'))) {
        fprintf(stderr, "usage:\n  linux_client\n  linux_client <count>\n");
        return 1;
    }

    printf("My Sample Client: Entry\n");
    thoth::channel ipc_r{"service ipc r", thoth::receiver};
    thoth::channel ipc_w{"service ipc w", thoth::sender};

    int rc = argc > 1 ? run_count(ipc_r, ipc_w, count) : run_forever(ipc_r, ipc_w);
    if (rc != 0) return rc;

    printf("My Sample Client: Exit\n");
    return 0;
}
