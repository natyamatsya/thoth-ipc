// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// C++23 service process — demonstrates that process separation lets each
// component use a different language standard.  The host and the ipc library
// are compiled as C++17; this service links against the same library but is
// free to use C++23 features (std::print, std::expected, std::numbers, …).

#include <cmath>
#include <csignal>
#include <atomic>
#include <chrono>
#include <expected>
#include <numbers>
#include <print>
#include <string>
#include <string_view>
#include <thread>

#ifdef _WIN32
#  include <process.h>
#else
#  include <unistd.h>
#endif

#include "rt_audio_common.h"
#include "libipc/proto/shm_ring.h"
#include "libipc/proto/rt_prio.h"
#include "libipc/proto/service_registry.h"

static std::atomic<bool> g_running{true};

static void on_signal(int) { g_running.store(false); }

static auto current_pid() noexcept -> int {
#ifdef _WIN32
    return _getpid();
#else
    return ::getpid();
#endif
}

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

    constexpr float freq  = 440.0f;
    constexpr float two_pi = 2.0f * std::numbers::pi_v<float>;
    float sr = static_cast<float>(blk.sample_rate);

    for (uint32_t f = 0; f < blk.frames; ++f) {
        float t = static_cast<float>(seq * blk.frames + f) / sr;
        float s = std::sin(two_pi * freq * t);
        if (blk.channels >= 1) blk.samples[f * blk.channels + 0] = s * l_gain;
        if (blk.channels >= 2) blk.samples[f * blk.channels + 1] = s * r_gain;
    }
}

// Validated service configuration — lightweight, movable.
struct service_config {
    std::string svc_name;
    std::string ring_name;
    std::string state_name;
};

// Validate names and return a config, or an error string on failure.
static auto make_config(std::string_view instance_id)
    -> std::expected<service_config, std::string>
{
    service_config cfg{
        .svc_name   = "rt_audio",
        .ring_name  = "rt_audio_ring",
        .state_name = "rt_audio_state",
    };
    if (!instance_id.empty()) {
        cfg.svc_name   += std::string{"."} + std::string{instance_id};
        cfg.ring_name  += std::string{"_"} + std::string{instance_id};
        cfg.state_name += std::string{"_"} + std::string{instance_id};
    }
    return cfg;
}

// Open all IPC resources; returns an error string on failure.
static auto open_resources(const service_config &cfg,
                           shared_state_handle &ssh,
                           ipc::proto::shm_ring<audio_block, 4> &ring,
                           ipc::proto::service_registry &registry)
    -> std::expected<void, std::string>
{
    if (!ssh.open_or_create(cfg.state_name.c_str()))
        return std::unexpected{std::format("failed to open shared state '{}'",
                                           cfg.state_name)};
    if (!ring.open_or_create())
        return std::unexpected{std::format("failed to open ring buffer '{}'",
                                           cfg.ring_name)};
    registry.register_service(cfg.svc_name.c_str(),
                              cfg.ring_name.c_str(),
                              cfg.state_name.c_str());
    return {};
}

int main(int argc, char *argv[]) {
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    std::string_view instance_id = (argc > 1) ? argv[1] : "";

    auto cfg = make_config(instance_id);
    if (!cfg) {
        std::println(stderr, "rt_service: {}", cfg.error());
        return 1;
    }

    shared_state_handle                  ssh;
    ipc::proto::shm_ring<audio_block, 4> ring{cfg->ring_name.c_str()};
    ipc::proto::service_registry         registry{"audio_rt"};

    if (auto res = open_resources(*cfg, ssh, ring, registry); !res) {
        std::println(stderr, "rt_service[{}]: {}", cfg->svc_name, res.error());
        return 1;
    }
    auto *state = ssh.get();

    std::println("rt_service[{}]: starting (pid={})", cfg->svc_name, current_pid());
    std::println("rt_service[{}]: registered (ring={} state={})",
                 cfg->svc_name, cfg->ring_name, cfg->state_name);

    // Set real-time thread priority (best-effort, non-fatal if it fails)
    uint32_t sr = 48000, fpb = 256;
    auto period = ipc::proto::audio_period_ns(sr, fpb);
    if (ipc::proto::set_realtime_priority(period))
        std::println("rt_service[{}]: real-time priority set (period={} ns)",
                     cfg->svc_name, period);
    else
        std::println("rt_service[{}]: running without RT priority", cfg->svc_name);

    // Audio render loop: produce blocks at the configured rate
    uint64_t seq = 0;
    auto next_wake = std::chrono::steady_clock::now();

    std::println("rt_service[{}]: entering render loop", cfg->svc_name);

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

    std::println("rt_service[{}]: shutting down", cfg->svc_name);
    registry.unregister_service(cfg->svc_name.c_str());
    return 0;
}
