#pragma once

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>
#include <chrono>
#include <thread>
#include <functional>

#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <spawn.h>

extern char **environ;

namespace ipc {
namespace proto {

// Handle to a spawned child process.
struct process_handle {
    pid_t       pid  = -1;
    std::string name;        // logical name (for registry)
    std::string executable;  // path to the binary

    bool valid() const noexcept { return pid > 0; }

    bool is_alive() const noexcept {
        if (pid <= 0) return false;
        return (::kill(pid, 0) == 0) || (errno != ESRCH);
    }
};

// Result of a wait operation.
struct wait_result {
    bool  exited    = false;
    int   exit_code = -1;
    bool  signaled  = false;
    int   signal    = 0;
};

// Spawn a child process.
// argv[0] should be the executable path; argv must be null-terminated.
inline process_handle spawn(const char *name,
                            const char *executable,
                            const std::vector<std::string> &args = {}) {
    process_handle h;
    h.name = name ? name : "";
    h.executable = executable ? executable : "";

    // Build argv
    std::vector<char *> argv;
    argv.push_back(const_cast<char *>(executable));
    for (auto &a : args)
        argv.push_back(const_cast<char *>(a.c_str()));
    argv.push_back(nullptr);

    pid_t pid = -1;
    int err = ::posix_spawn(&pid, executable, nullptr, nullptr,
                            argv.data(), environ);
    if (err != 0) return h; // pid stays -1

    h.pid = pid;
    return h;
}

// Convenience overload: spawn with a single executable path, no extra args.
inline process_handle spawn(const char *name, const char *executable) {
    return spawn(name, executable, {});
}

// Send SIGTERM to gracefully request shutdown.
inline bool request_shutdown(const process_handle &h) {
    if (!h.valid()) return false;
    return ::kill(h.pid, SIGTERM) == 0;
}

// Send SIGKILL to forcefully terminate.
inline bool force_kill(const process_handle &h) {
    if (!h.valid()) return false;
    return ::kill(h.pid, SIGKILL) == 0;
}

// Wait for a process to exit, with a timeout.
// Returns immediately if the process has already exited.
inline wait_result wait_for_exit(const process_handle &h,
                                 std::chrono::milliseconds timeout = std::chrono::milliseconds{5000}) {
    wait_result r;
    if (!h.valid()) return r;

    using clock = std::chrono::steady_clock;
    auto deadline = clock::now() + timeout;

    while (clock::now() < deadline) {
        int status = 0;
        pid_t ret = ::waitpid(h.pid, &status, WNOHANG);
        if (ret == h.pid) {
            if (WIFEXITED(status)) {
                r.exited = true;
                r.exit_code = WEXITSTATUS(status);
            }
            if (WIFSIGNALED(status)) {
                r.signaled = true;
                r.signal = WTERMSIG(status);
            }
            return r;
        }
        if (ret == -1) return r; // error (not our child, etc.)
        std::this_thread::sleep_for(std::chrono::milliseconds{10});
    }
    return r; // timed out, process still running
}

// Graceful shutdown: SIGTERM → wait → SIGKILL if still alive.
inline wait_result shutdown(const process_handle &h,
                            std::chrono::milliseconds grace = std::chrono::milliseconds{3000}) {
    if (!h.valid()) return {};
    request_shutdown(h);
    auto r = wait_for_exit(h, grace);
    if (!r.exited && !r.signaled && h.is_alive()) {
        force_kill(h);
        r = wait_for_exit(h, std::chrono::milliseconds{1000});
    }
    return r;
}

// Convenience: spawn, then wait until it registers in a service_registry.
// Returns true if the service appeared within the timeout.
// Requires service_registry.h to be included before this call.
template <typename Registry>
bool spawn_and_wait(Registry &registry,
                    const char *service_name,
                    const char *executable,
                    const std::vector<std::string> &args = {},
                    std::chrono::milliseconds timeout = std::chrono::milliseconds{5000},
                    process_handle *out_handle = nullptr) {
    auto h = spawn(service_name, executable, args);
    if (!h.valid()) return false;
    if (out_handle) *out_handle = h;

    using clock = std::chrono::steady_clock;
    auto deadline = clock::now() + timeout;

    while (clock::now() < deadline) {
        if (registry.find(service_name)) return true;
        if (!h.is_alive()) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds{50});
    }
    return false;
}

} // namespace proto
} // namespace ipc
