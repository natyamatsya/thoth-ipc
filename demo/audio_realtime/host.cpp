// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <thread>
#include <chrono>
#include <string>

#include "rt_audio_common.h"
#include "libipc/proto/shm_ring.h"
#include "libipc/proto/service_registry.h"
#include "libipc/proto/service_group.h"

// ---------------------------------------------------------------------------
// Per-instance connection: ring + shared state
// ---------------------------------------------------------------------------
struct instance_conn {
    ipc::proto::shm_ring<audio_block, 4> ring{""};
    shared_state_handle                  ssh;
    shared_state                        *state = nullptr;
    std::string                          ring_name;
    std::string                          state_name;

    bool connect(const ipc::proto::service_entry &entry) {
        ring_name  = entry.control_channel; // we store ring name here
        state_name = entry.reply_channel;   // and state name here
        ring.~shm_ring();
        new (&ring) ipc::proto::shm_ring<audio_block, 4>(ring_name.c_str());
        if (!ring.open_or_create()) {
            std::printf("host: failed to open ring '%s'\n", ring_name.c_str());
            return false;
        }
        ssh.close();
        if (!ssh.open_or_create(state_name.c_str())) {
            std::printf("host: failed to open state '%s'\n", state_name.c_str());
            return false;
        }
        state = ssh.get();
        return true;
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static void print_stats(const shared_state &s) {
    std::printf("  produced=%llu  consumed=%llu  underruns=%llu  overruns=%llu  heartbeat_age=%llu ms\n",
                (unsigned long long)s.blocks_produced.load(),
                (unsigned long long)s.blocks_consumed.load(),
                (unsigned long long)s.underruns.load(),
                (unsigned long long)s.overruns.load(),
                (unsigned long long)s.heartbeat_age_ms());
}

static void configure_stream(shared_state &s, uint32_t sr, uint32_t ch, uint32_t fpb) {
    s.sample_rate.store(sr, std::memory_order_relaxed);
    s.channels.store(ch, std::memory_order_relaxed);
    s.frames_per_buffer.store(fpb, std::memory_order_relaxed);
    s.stream_active.store(true, std::memory_order_release);
}

static void stop_stream(shared_state &s) {
    s.stream_active.store(false, std::memory_order_release);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main(int argc, char *argv[]) {
    if (argc < 2) {
        std::printf("usage: rt_audio_host <path_to_rt_audio_service>\n");
        return 1;
    }
    const char *service_bin = argv[1];

    ipc::proto::service_registry registry("audio_rt");
    registry.gc();

    // --- Start redundant service group ---
    ipc::proto::service_group group(registry, {
        .service_name = "rt_audio",
        .executable   = service_bin,
        .replicas     = 2,
        .auto_respawn = true,
    });

    std::printf("host: starting service group (2 replicas)...\n");
    if (!group.start()) {
        std::printf("host: failed to start service group\n");
        return 1;
    }
    std::printf("host: %d instances alive\n", group.alive_count());

    // --- Connect to primary ---
    instance_conn conn;
    auto *primary = group.primary();
    if (!primary || !conn.connect(primary->entry)) {
        std::printf("host: failed to connect to primary\n");
        return 1;
    }
    std::printf("host: connected to %s (pid=%d)\n",
                primary->instance_name.c_str(), primary->entry.pid);

    // --- Configure stream (written via shared state, no FlatBuffers) ---
    std::printf("\nhost: configuring stream: 48kHz, 2ch, 256 frames\n");
    configure_stream(*conn.state, 48000, 2, 256);

    // --- Also configure standby instances (warm standby state replication) ---
    for (auto &inst : group.instances()) {
        if (inst.role == ipc::proto::instance_role::standby) {
            shared_state_handle standby_ssh;
            if (standby_ssh.open_or_create(inst.entry.reply_channel)) {
                auto *ss = standby_ssh.get();
                ss->sample_rate.store(48000, std::memory_order_relaxed);
                ss->channels.store(2, std::memory_order_relaxed);
                ss->frames_per_buffer.store(256, std::memory_order_relaxed);
                ss->gain.store(conn.state->gain.load(), std::memory_order_relaxed);
                ss->pan.store(conn.state->pan.load(), std::memory_order_relaxed);
                // Don't activate yet — activated on failover
                std::printf("host: replicated config to standby %s\n",
                            inst.instance_name.c_str());
            }
        }
    }

    // --- Consume audio blocks from the ring buffer ---
    std::printf("\nhost: consuming audio for 500ms...\n");
    uint64_t consumed = 0;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds{500};

    while (std::chrono::steady_clock::now() < deadline) {
        audio_block blk;
        if (conn.ring.read(blk)) {
            ++consumed;
            conn.state->blocks_consumed.fetch_add(1, std::memory_order_relaxed);
            if (consumed % 50 == 0)
                std::printf("  block seq=%llu  frames=%u  peak=%.3f\n",
                            (unsigned long long)blk.sequence, blk.frames,
                            std::abs(blk.samples[0]));
        } else {
            // Ring empty — this would be an underrun in a real DAW
            conn.state->underruns.fetch_add(1, std::memory_order_relaxed);
            std::this_thread::sleep_for(std::chrono::microseconds{100});
        }
    }

    std::printf("host: consumed %llu blocks\n", (unsigned long long)consumed);
    print_stats(*conn.state);

    // --- Set gain via shared state (no FlatBuffers, no IPC channel) ---
    std::printf("\nhost: setting gain=0.5 via shared state\n");
    conn.state->gain.store(0.5f, std::memory_order_release);

    // Replicate to standbys
    for (auto &inst : group.instances()) {
        if (inst.role == ipc::proto::instance_role::standby) {
            shared_state_handle standby_ssh;
            if (standby_ssh.open_or_create(inst.entry.reply_channel))
                standby_ssh.get()->gain.store(0.5f, std::memory_order_release);
        }
    }

    // Consume a few more blocks to see the gain change
    std::printf("host: consuming 100 more blocks with new gain...\n");
    consumed = 0;
    while (consumed < 100) {
        audio_block blk;
        if (conn.ring.read(blk)) {
            ++consumed;
            if (consumed == 100)
                std::printf("  block seq=%llu  peak=%.3f (should be ~0.5x)\n",
                            (unsigned long long)blk.sequence,
                            std::abs(blk.samples[0]));
        } else {
            std::this_thread::sleep_for(std::chrono::microseconds{100});
        }
    }

    // --- Heartbeat watchdog demo ---
    std::printf("\nhost: heartbeat age = %llu ms (should be <10)\n",
                (unsigned long long)conn.state->heartbeat_age_ms());

    // --- Simulate crash + failover ---
    std::printf("\n*** SIMULATING PRIMARY CRASH ***\n\n");
    auto old_primary_name = primary->instance_name;
    group.force_failover();

    // The new primary's stream is not active yet — activate it
    primary = group.primary();
    if (!primary) {
        std::printf("host: all instances dead!\n");
        return 1;
    }
    std::printf("host: new primary = %s (pid=%d)\n",
                primary->instance_name.c_str(), primary->entry.pid);

    // Reconnect to the new primary's ring + state
    if (!conn.connect(primary->entry)) {
        std::printf("host: failed to reconnect\n");
        return 1;
    }

    // Activate stream on new primary (warm standby already has config)
    conn.state->stream_active.store(true, std::memory_order_release);
    std::printf("host: activated stream on new primary\n");

    // Brief settle time for the service to start producing
    std::this_thread::sleep_for(std::chrono::milliseconds{50});

    // Consume audio from the new primary
    std::printf("host: consuming audio from new primary for 300ms...\n");
    consumed = 0;
    deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds{300};

    while (std::chrono::steady_clock::now() < deadline) {
        audio_block blk;
        if (conn.ring.read(blk)) {
            ++consumed;
            conn.state->blocks_consumed.fetch_add(1, std::memory_order_relaxed);
        } else {
            conn.state->underruns.fetch_add(1, std::memory_order_relaxed);
            std::this_thread::sleep_for(std::chrono::microseconds{100});
        }
    }

    std::printf("host: consumed %llu blocks from new primary\n",
                (unsigned long long)consumed);
    print_stats(*conn.state);

    // --- Show final instance state ---
    std::printf("\nhost: --- final state ---\n");
    for (auto &inst : group.instances())
        std::printf("  [%d] %-20s  role=%-8s  pid=%d  alive=%d\n",
                    inst.id, inst.instance_name.c_str(),
                    inst.role == ipc::proto::instance_role::primary ? "PRIMARY" :
                    inst.role == ipc::proto::instance_role::standby ? "STANDBY" : "DEAD",
                    inst.proc.pid, inst.is_alive());

    // --- Clean shutdown ---
    std::printf("\nhost: shutting down...\n");
    stop_stream(*conn.state);
    std::this_thread::sleep_for(std::chrono::milliseconds{50});
    group.stop();
    std::printf("host: done\n");
    return 0;
}
