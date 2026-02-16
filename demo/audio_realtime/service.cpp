// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#include <cstdio>
#include <csignal>
#include <cmath>
#include <atomic>
#include <thread>
#include <chrono>
#include <string>

#include "rt_audio_common.h"
#include "libipc/proto/shm_ring.h"
#include "libipc/proto/rt_prio.h"
#include "libipc/proto/service_registry.h"

static std::atomic<bool> g_running{true};

static void on_signal(int) { g_running.store(false); }

// Simulated audio render: fill a block with a sine tone scaled by gain.
static void render_audio(audio_block &blk, uint64_t seq,
                         const shared_state &state) {
    blk.sequence    = seq;
    blk.sample_rate = state.sample_rate.load(std::memory_order_relaxed);
    blk.channels    = state.channels.load(std::memory_order_relaxed);
    blk.frames      = state.frames_per_buffer.load(std::memory_order_relaxed);

    float gain = state.gain.load(std::memory_order_relaxed);
    float pan  = state.pan.load(std::memory_order_relaxed);
    float l_gain = gain * (1.0f - pan) * 0.5f;
    float r_gain = gain * (1.0f + pan) * 0.5f;

    constexpr float freq = 440.0f;
    float sr = static_cast<float>(blk.sample_rate);

    for (uint32_t f = 0; f < blk.frames; ++f) {
        float t = static_cast<float>(seq * blk.frames + f) / sr;
        float s = std::sin(2.0f * 3.14159265f * freq * t);
        if (blk.channels >= 1) blk.samples[f * blk.channels + 0] = s * l_gain;
        if (blk.channels >= 2) blk.samples[f * blk.channels + 1] = s * r_gain;
    }
}

int main(int argc, char *argv[]) {
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    std::string instance_id = (argc > 1) ? argv[1] : "";
    std::string svc_name  = "rt_audio";
    std::string ring_name = "rt_audio_ring";
    std::string state_name = "rt_audio_state";
    if (!instance_id.empty()) {
        svc_name  += "." + instance_id;
        ring_name += "_" + instance_id;
        state_name += "_" + instance_id;
    }

    std::printf("rt_service[%s]: starting (pid=%d)\n", svc_name.c_str(), ::getpid());

    // Open shared state (host creates it, we open existing or create)
    shared_state_handle ssh;
    if (!ssh.open_or_create(state_name.c_str())) {
        std::printf("rt_service[%s]: failed to open shared state\n", svc_name.c_str());
        return 1;
    }
    auto *state = ssh.get();

    // Open the audio ring buffer
    ipc::proto::shm_ring<audio_block, 4> ring(ring_name.c_str());
    if (!ring.open_or_create()) {
        std::printf("rt_service[%s]: failed to open ring buffer\n", svc_name.c_str());
        return 1;
    }

    // Register in the service registry
    ipc::proto::service_registry registry("audio_rt");
    registry.register_service(svc_name.c_str(), ring_name.c_str(), state_name.c_str());
    std::printf("rt_service[%s]: registered (ring=%s state=%s)\n",
                svc_name.c_str(), ring_name.c_str(), state_name.c_str());

    // Set real-time thread priority (best-effort, non-fatal if it fails)
    uint32_t sr = 48000, fpb = 256;
    auto period = ipc::proto::audio_period_ns(sr, fpb);
    if (ipc::proto::set_realtime_priority(period))
        std::printf("rt_service[%s]: real-time priority set (period=%llu ns)\n",
                    svc_name.c_str(), (unsigned long long)period);
    else
        std::printf("rt_service[%s]: running without RT priority\n", svc_name.c_str());

    // Audio render loop: produce blocks at the configured rate
    uint64_t seq = 0;
    auto next_wake = std::chrono::steady_clock::now();

    std::printf("rt_service[%s]: entering render loop\n", svc_name.c_str());

    while (g_running.load(std::memory_order_relaxed)) {
        // Wait for stream to be active
        if (!state->stream_active.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::milliseconds{10});
            state->touch_heartbeat();
            continue;
        }

        // Compute the callback period from current config
        sr  = state->sample_rate.load(std::memory_order_relaxed);
        fpb = state->frames_per_buffer.load(std::memory_order_relaxed);
        if (sr == 0 || fpb == 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds{1});
            continue;
        }
        auto callback_period = std::chrono::nanoseconds(
            static_cast<uint64_t>(fpb) * 1'000'000'000ULL / sr);

        // Render and push to ring buffer
        audio_block blk{};
        render_audio(blk, seq, *state);

        // Overwrite mode: never block, drop oldest if consumer is slow
        ring.write_overwrite(blk);
        ++seq;

        state->blocks_produced.fetch_add(1, std::memory_order_relaxed);
        state->touch_heartbeat();

        // Sleep until next callback period
        next_wake += callback_period;
        auto now = std::chrono::steady_clock::now();
        if (next_wake > now)
            std::this_thread::sleep_until(next_wake);
        else
            next_wake = now; // we fell behind, reset
    }

    std::printf("rt_service[%s]: shutting down\n", svc_name.c_str());
    registry.unregister_service(svc_name.c_str());
    return 0;
}
