#pragma once

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <chrono>
#include <thread>
#include <functional>
#include <algorithm>

#include "libipc/proto/service_registry.h"
#include "libipc/proto/process_manager.h"
#include "libipc/proto/typed_channel.h"

namespace ipc {
namespace proto {

// Instance role within a service group.
enum class instance_role { primary, standby, dead };

// A single managed instance.
struct managed_instance {
    int              id = -1;
    instance_role    role = instance_role::dead;
    process_handle   proc;
    service_entry    entry{};       // last known registry entry
    std::string      instance_name; // e.g. "audio_compute.0"

    bool is_alive() const noexcept { return proc.is_alive(); }
};

// Configuration for a service group.
struct service_group_config {
    const char *service_name;  // logical name, e.g. "audio_compute"
    const char *executable;    // path to service binary
    int         replicas = 2;  // total instances (1 primary + N-1 standby)
    bool        auto_respawn = true;
    std::chrono::milliseconds spawn_timeout{5000};
};

// Manages a group of redundant service instances with automatic failover.
//
// Usage:
//   service_group group(registry, {
//       .service_name = "audio_compute",
//       .executable   = "./audio_service",
//       .replicas     = 2,
//   });
//   group.start();
//
//   auto *primary = group.primary();
//   // connect to primary->entry.control_channel ...
//
//   // Periodically:
//   if (group.health_check()) {
//       // failover happened — reconnect channels
//       primary = group.primary();
//   }
//
class service_group {
    service_registry &registry_;
    service_group_config config_;
    std::vector<managed_instance> instances_;
    int primary_idx_ = -1;

public:
    using failover_callback = std::function<void(const managed_instance &old_primary,
                                                 const managed_instance &new_primary)>;

    service_group(service_registry &reg, const service_group_config &cfg)
        : registry_{reg}, config_{cfg} {
        instances_.resize(cfg.replicas);
        for (int i = 0; i < cfg.replicas; ++i) {
            instances_[i].id = i;
            instances_[i].instance_name = std::string(cfg.service_name) + "." + std::to_string(i);
        }
    }

    // Spawn all instances. The first live one becomes primary.
    bool start() {
        for (auto &inst : instances_) {
            if (!spawn_instance(inst)) continue;
        }
        // Elect primary: first alive instance
        return elect_primary();
    }

    // Perform a health check on all instances.
    // Returns true if a failover occurred (caller should reconnect).
    bool health_check() {
        bool failover_needed = false;
        for (auto &inst : instances_) {
            if (inst.role == instance_role::dead) continue;
            if (!inst.is_alive()) {
                if (inst.role == instance_role::primary)
                    failover_needed = true;
                inst.role = instance_role::dead;
            }
        }

        if (failover_needed) {
            // Promote a standby to primary
            if (!elect_primary()) return true; // all dead, caller should handle

            // Respawn dead instances as standbys
            if (config_.auto_respawn)
                respawn_dead();

            return true; // failover happened
        }

        // Respawn dead standbys in the background
        if (config_.auto_respawn)
            respawn_dead();

        return false;
    }

    // Get the current primary instance. Returns nullptr if none alive.
    const managed_instance *primary() const noexcept {
        if (primary_idx_ < 0 || primary_idx_ >= (int)instances_.size())
            return nullptr;
        auto &inst = instances_[primary_idx_];
        if (inst.role != instance_role::primary) return nullptr;
        return &inst;
    }

    // Get all instances.
    const std::vector<managed_instance> &instances() const noexcept {
        return instances_;
    }

    // Shut down all instances gracefully.
    void stop(std::chrono::milliseconds grace = std::chrono::milliseconds{3000}) {
        for (auto &inst : instances_) {
            if (inst.is_alive())
                ipc::proto::shutdown(inst.proc, grace);
            inst.role = instance_role::dead;
        }
        primary_idx_ = -1;
    }

    // Number of live instances.
    int alive_count() const noexcept {
        int n = 0;
        for (auto &inst : instances_)
            if (inst.is_alive()) ++n;
        return n;
    }

    // Force a failover (e.g. for testing). Kills the primary and promotes standby.
    bool force_failover() {
        if (primary_idx_ < 0) return false;
        auto &inst = instances_[primary_idx_];
        if (inst.is_alive()) {
            force_kill(inst.proc);
            // Reap the zombie so is_alive() returns false
            wait_for_exit(inst.proc, std::chrono::milliseconds{2000});
        }
        inst.role = instance_role::dead;
        bool ok = elect_primary();
        if (config_.auto_respawn)
            respawn_dead();
        return ok;
    }

private:
    bool spawn_instance(managed_instance &inst) {
        // Pass instance ID as argument so the service can register with a unique name
        auto h = ipc::proto::spawn(
            inst.instance_name.c_str(),
            config_.executable,
            {std::to_string(inst.id)});
        if (!h.valid()) return false;
        inst.proc = h;

        // Wait for it to appear in the registry
        using clock = std::chrono::steady_clock;
        auto deadline = clock::now() + config_.spawn_timeout;
        while (clock::now() < deadline) {
            auto *e = registry_.find(inst.instance_name.c_str());
            if (e) {
                inst.entry = *e;
                inst.role = instance_role::standby;
                return true;
            }
            if (!h.is_alive()) return false;
            std::this_thread::sleep_for(std::chrono::milliseconds{50});
        }
        return false;
    }

    bool elect_primary() {
        primary_idx_ = -1;
        for (int i = 0; i < (int)instances_.size(); ++i) {
            if (instances_[i].is_alive()) {
                instances_[i].role = instance_role::primary;
                primary_idx_ = i;
                // Demote others to standby
                for (int j = 0; j < (int)instances_.size(); ++j)
                    if (j != i && instances_[j].is_alive())
                        instances_[j].role = instance_role::standby;
                return true;
            }
        }
        return false; // all dead
    }

    void respawn_dead() {
        for (auto &inst : instances_) {
            if (inst.role == instance_role::dead)
                spawn_instance(inst);
        }
    }
};

} // namespace proto
} // namespace ipc
