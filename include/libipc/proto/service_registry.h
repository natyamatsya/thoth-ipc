// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#pragma once

#include <cstring>
#include <cstdint>
#include <ctime>
#include <string>
#include <vector>
#include <atomic>
#include <functional>

#include <unistd.h>
#include <signal.h>

#include "libipc/shm.h"

namespace ipc {
namespace proto {

// Maximum number of concurrently registered services.
static constexpr std::size_t max_services = 32;
// Maximum length of name/channel strings (including null terminator).
static constexpr std::size_t max_name_len = 64;

// A single service entry in the shared registry.
struct service_entry {
    char     name[max_name_len];            // logical service name
    char     control_channel[max_name_len]; // channel the service listens on
    char     reply_channel[max_name_len];   // channel the service replies on
    pid_t    pid;
    int64_t  registered_at;                 // unix timestamp (seconds)
    uint32_t flags;                         // reserved

    bool active() const noexcept { return pid > 0 && name[0] != '\0'; }

    bool is_alive() const noexcept {
        if (pid <= 0) return false;
        return (::kill(pid, 0) == 0) || (errno != ESRCH);
    }
};

// Shared memory layout for the registry.
struct registry_data {
    std::atomic<int32_t> spinlock;  // simple test-and-set lock
    uint32_t             count;
    service_entry        entries[max_services];

    void lock() noexcept {
        while (spinlock.exchange(1, std::memory_order_acquire) != 0)
            ; // spin
    }
    void unlock() noexcept {
        spinlock.store(0, std::memory_order_release);
    }
};

// Scoped lock helper for registry_data.
struct registry_lock_guard {
    registry_data &reg;
    registry_lock_guard(registry_data &r) : reg{r} { reg.lock(); }
    ~registry_lock_guard() { reg.unlock(); }
};

// Service registry backed by a well-known shared memory segment.
// Any process that creates a service_registry with the same domain
// sees the same set of registered services.
class service_registry {
    ipc::shm::handle shm_;
    registry_data   *data_ = nullptr;

    static std::string make_shm_name(const char *domain) {
        std::string s = "__ipc_registry__";
        if (domain && domain[0])
            s += domain;
        return s;
    }

public:
    // Open or create the registry for the given domain.
    explicit service_registry(const char *domain = "default") {
        auto name = make_shm_name(domain);
        shm_ = ipc::shm::handle{name.c_str(), sizeof(registry_data)};
        auto *mem = shm_.get();
        if (!mem) return;
        data_ = static_cast<registry_data *>(mem);
        // First opener initializes (shm ref == 1).
        if (shm_.ref() <= 1) {
            std::memset(data_, 0, sizeof(registry_data));
        }
    }

    ~service_registry() = default;

    bool valid() const noexcept { return data_ != nullptr; }

    // Register a service. Returns true on success.
    bool register_service(const char *name,
                          const char *control_ch,
                          const char *reply_ch,
                          pid_t pid = ::getpid()) {
        if (!valid() || !name || !name[0]) return false;
        registry_lock_guard g{*data_};
        // Check for duplicate or reuse dead slot
        for (uint32_t i = 0; i < max_services; ++i) {
            auto &e = data_->entries[i];
            if (e.active() && std::strcmp(e.name, name) == 0) {
                if (e.is_alive()) return false; // already registered and alive
                // Stale entry — reuse
                fill_entry(e, name, control_ch, reply_ch, pid);
                return true;
            }
        }
        // Find empty slot
        for (uint32_t i = 0; i < max_services; ++i) {
            auto &e = data_->entries[i];
            if (!e.active() || !e.is_alive()) {
                fill_entry(e, name, control_ch, reply_ch, pid);
                if (data_->count < max_services) ++data_->count;
                return true;
            }
        }
        return false; // registry full
    }

    // Unregister a service by name. Only the owning PID can unregister.
    bool unregister_service(const char *name, pid_t pid = ::getpid()) {
        if (!valid() || !name) return false;
        registry_lock_guard g{*data_};
        for (uint32_t i = 0; i < max_services; ++i) {
            auto &e = data_->entries[i];
            if (e.active() && std::strcmp(e.name, name) == 0 && e.pid == pid) {
                std::memset(&e, 0, sizeof(service_entry));
                return true;
            }
        }
        return false;
    }

    // Look up a service by name. Returns nullptr if not found.
    const service_entry *find(const char *name) {
        if (!valid() || !name) return nullptr;
        registry_lock_guard g{*data_};
        for (uint32_t i = 0; i < max_services; ++i) {
            auto &e = data_->entries[i];
            if (e.active() && std::strcmp(e.name, name) == 0) {
                if (!e.is_alive()) {
                    std::memset(&e, 0, sizeof(service_entry));
                    continue; // auto-clean stale
                }
                // Copy to caller (lock is held, entry could be invalidated later)
                last_result_ = e;
                return &last_result_;
            }
        }
        return nullptr;
    }

    // Find all live instances whose name starts with the given prefix.
    // Useful for service groups: find_all("audio_compute") returns
    // "audio_compute.0", "audio_compute.1", etc.
    std::vector<service_entry> find_all(const char *prefix) {
        std::vector<service_entry> result;
        if (!valid() || !prefix) return result;
        auto plen = std::strlen(prefix);
        registry_lock_guard g{*data_};
        for (uint32_t i = 0; i < max_services; ++i) {
            auto &e = data_->entries[i];
            if (!e.active()) continue;
            if (!e.is_alive()) {
                std::memset(&e, 0, sizeof(service_entry));
                continue;
            }
            if (std::strncmp(e.name, prefix, plen) == 0)
                result.push_back(e);
        }
        return result;
    }

    // List all live services.
    std::vector<service_entry> list() {
        std::vector<service_entry> result;
        if (!valid()) return result;
        registry_lock_guard g{*data_};
        for (uint32_t i = 0; i < max_services; ++i) {
            auto &e = data_->entries[i];
            if (!e.active()) continue;
            if (!e.is_alive()) {
                std::memset(&e, 0, sizeof(service_entry));
                continue;
            }
            result.push_back(e);
        }
        return result;
    }

    // Remove all entries for dead processes.
    std::size_t gc() {
        std::size_t removed = 0;
        if (!valid()) return removed;
        registry_lock_guard g{*data_};
        for (uint32_t i = 0; i < max_services; ++i) {
            auto &e = data_->entries[i];
            if (e.active() && !e.is_alive()) {
                std::memset(&e, 0, sizeof(service_entry));
                ++removed;
            }
        }
        return removed;
    }

    // Clear the entire registry.
    void clear() {
        if (!valid()) return;
        registry_lock_guard g{*data_};
        std::memset(data_->entries, 0, sizeof(data_->entries));
        data_->count = 0;
    }

private:
    service_entry last_result_{}; // find() returns a pointer to this copy

    static void fill_entry(service_entry &e, const char *name,
                           const char *ctrl, const char *reply, pid_t pid) {
        std::memset(&e, 0, sizeof(service_entry));
        std::strncpy(e.name, name, max_name_len - 1);
        if (ctrl)  std::strncpy(e.control_channel, ctrl, max_name_len - 1);
        if (reply) std::strncpy(e.reply_channel, reply, max_name_len - 1);
        e.pid = pid;
        e.registered_at = static_cast<int64_t>(std::time(nullptr));
    }
};

} // namespace proto
} // namespace ipc
