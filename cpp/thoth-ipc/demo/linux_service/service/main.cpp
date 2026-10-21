/// \brief To create a basic command line program.
//
// Usage (start the client first, then the service):
//   linux_service            send "Hello, World!" every 3 s, forever
//   linux_service <count>    exchange <count> messages with the client, then exit
//   linux_service clear      remove both channels, so the next run starts fresh
//
// The service sends on "service ipc r" and receives the client's "Copy." reply
// on "service ipc w" (both multi-writer thoth::channel). Strings go on the wire
// with their trailing NUL; the Rust and Zig ports are wire-identical, so the
// service and the client can be any mix of languages.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <thread>
#include <chrono>

#include "thoth-ipc/ipc.h"

namespace {

constexpr char const name_r__[] = "service ipc r";
constexpr char const name_w__[] = "service ipc w";

/// The payload without the trailing NUL the senders append.
std::string text_of(thoth::buff_t const &msg) {
    auto p = static_cast<char const *>(msg.data());
    std::size_t n = msg.size();
    if (n > 0 && p[n - 1] == '\0') --n;
    return std::string(p, n);
}

int run_forever(thoth::channel &ipc_r, thoth::channel &ipc_w) {
    while (1) {
        if (!ipc_r.send("Hello, World!")) {
            printf("My Sample Service: send failed.\n");
        }
        else {
            printf("My Sample Service: send [Hello, World!]\n");
            auto msg = ipc_w.recv(1000);
            if (msg.empty()) {
                printf("My Sample Service: recv error\n");
            } else {
                printf("My Sample Service: recv [%s]\n", text_of(msg).c_str());
            }
        }
        std::this_thread::sleep_for(std::chrono::seconds(3));
    }
}

int run_count(thoth::channel &ipc_r, thoth::channel &ipc_w, unsigned long long count) {
    if (!ipc_r.wait_for_recv(1, 5000)) {
        fprintf(stderr, "My Sample Service: no client within 5s - start the client first\n");
        return 2;
    }
    for (unsigned long long k = 0; k < count; ++k) {
        if (!ipc_r.send("Hello, World!")) {
            fprintf(stderr, "My Sample Service: send failed.\n");
            return 4;
        }
        printf("My Sample Service: send [Hello, World!]\n");
        auto msg = ipc_w.recv(5000);
        if (msg.empty()) {
            fprintf(stderr, "My Sample Service: recv timed out\n");
            return 5;
        }
        auto reply = text_of(msg);
        if (reply != "Copy.") {
            fprintf(stderr, "My Sample Service: unexpected reply [%s]\n", reply.c_str());
            return 6;
        }
        printf("My Sample Service: recv [%s]\n", reply.c_str());
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    return 0;
}

} // namespace

int main(int argc, char *argv[]) {
    setvbuf(stdout, nullptr, _IOLBF, 0); // one flushed line per status line
    if (argc > 1 && strcmp(argv[1], "clear") == 0) {
        thoth::channel::clear_storage(name_r__);
        thoth::channel::clear_storage(name_w__);
        return 0;
    }
    char *end = nullptr;
    unsigned long long count = argc > 1 ? strtoull(argv[1], &end, 10) : 0;
    if (argc > 2 || (argc > 1 && (end == argv[1] || *end != '\0'))) {
        fprintf(stderr, "usage:\n  linux_service\n  linux_service <count>\n  linux_service clear\n");
        return 1;
    }

    printf("My Sample Service: Main: Entry\n");

    thoth::channel ipc_r{name_r__, thoth::sender};
    thoth::channel ipc_w{name_w__, thoth::receiver};

    int rc = argc > 1 ? run_count(ipc_r, ipc_w, count) : run_forever(ipc_r, ipc_w);
    if (rc != 0) return rc;

    printf("My Sample Service: Main: Exit\n");
    return 0;
}
