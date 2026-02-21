// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// C++23 service process — demonstrates that process separation lets each
// component use a different language standard.  The host and the ipc library
// are compiled as C++17; this service links against the same library but is
// free to use C++23 features (std::print, std::expected, using enum, …).

#include <csignal>
#include <atomic>
#include <chrono>
#include <cmath>
#include <expected>
#include <print>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#ifdef _WIN32
#  include <process.h>
#else
#  include <unistd.h>
#endif

#include "audio_protocol_generated.h"
#include "libipc/proto/typed_channel.h"
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

struct StreamState {
    uint32_t sample_rate   = 48000;
    uint16_t channels      = 2;
    uint32_t buffer_frames = 512;
    bool     active        = false;
    float    gain          = 1.0f;
    float    pan           = 0.0f;
};

static float get_param(const StreamState &st, audio::ParamType id) {
    using enum audio::ParamType;
    switch (id) {
    case ParamType_Gain: return st.gain;
    case ParamType_Pan:  return st.pan;
    default: return 0.0f;
    }
}

static bool set_param(StreamState &st, audio::ParamType id, float val) {
    using enum audio::ParamType;
    switch (id) {
    case ParamType_Gain: st.gain = val; return true;
    case ParamType_Pan:  st.pan  = val; return true;
    default: return false;
    }
}

static void send_ack(ipc::proto::typed_channel<audio::ReplyMsg> &reply,
                     uint64_t seq, uint64_t ref_seq, audio::Status status) {
    ipc::proto::builder b;
    auto ack = audio::CreateAck(b.fbb(), ref_seq, status);
    auto msg = audio::CreateReplyMsg(b.fbb(), seq,
        audio::ReplyPayload_Ack, ack.Union());
    b.finish(msg);
    reply.send(b);
}

static void send_param_value(ipc::proto::typed_channel<audio::ReplyMsg> &reply,
                             uint64_t seq, uint64_t ref_seq,
                             audio::ParamType id, float val) {
    ipc::proto::builder b;
    auto pv = audio::CreateParamValue(b.fbb(), ref_seq, id, val);
    auto msg = audio::CreateReplyMsg(b.fbb(), seq,
        audio::ReplyPayload_ParamValue, pv.Union());
    b.finish(msg);
    reply.send(b);
}

// Validated service configuration — lightweight, movable.
struct service_config {
    std::string svc_name;
    std::string ctrl_ch;
    std::string reply_ch;
};

// Build channel names from instance ID.
static auto make_config(std::string_view instance_id)
    -> std::expected<service_config, std::string>
{
    service_config cfg{
        .svc_name = "audio_compute",
        .ctrl_ch  = "audio_ctrl",
        .reply_ch = "audio_reply",
    };
    if (!instance_id.empty()) {
        cfg.svc_name += std::string{"."} + std::string{instance_id};
        cfg.ctrl_ch  += std::string{"_"} + std::string{instance_id};
        cfg.reply_ch += std::string{"_"} + std::string{instance_id};
    }
    return cfg;
}

int main(int argc, char *argv[]) {
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    std::string_view instance_id = (argc > 1) ? argv[1] : "";

    auto cfg = make_config(instance_id);
    if (!cfg) {
        std::println(stderr, "audio_service: {}", cfg.error());
        return 1;
    }

    // Clear stale channel storage from previous runs
    ipc::proto::typed_channel<audio::ControlMsg>::clear_storage(cfg->ctrl_ch.c_str());
    ipc::proto::typed_channel<audio::ReplyMsg>::clear_storage(cfg->reply_ch.c_str());

    ipc::proto::service_registry                 registry{"audio"};
    ipc::proto::typed_channel<audio::ControlMsg> control{cfg->ctrl_ch.c_str(), ipc::receiver};
    ipc::proto::typed_channel<audio::ReplyMsg>   reply{cfg->reply_ch.c_str(), ipc::sender};

    registry.register_service(cfg->svc_name.c_str(),
                              cfg->ctrl_ch.c_str(),
                              cfg->reply_ch.c_str());

    std::println("audio_service[{}]: starting (pid={})...", cfg->svc_name, current_pid());
    std::println("audio_service[{}]: registered in service registry", cfg->svc_name);

    StreamState state;
    uint64_t reply_seq = 0;

    std::println("audio_service: waiting for commands on '{}'", cfg->ctrl_ch);

    while (g_running.load()) {
        auto msg = control.recv(100); // 100ms timeout
        if (!msg) continue;

        auto *ctrl = msg.root();
        if (!ctrl) continue;

        auto seq = ctrl->seq();
        std::println("audio_service: received command seq={} type={}",
                     seq, static_cast<unsigned>(ctrl->payload_type()));

        using enum audio::ControlPayload;
        switch (ctrl->payload_type()) {
        case ControlPayload_StartStream: {
            auto *ss = ctrl->payload_as_StartStream();
            state.sample_rate   = ss->sample_rate();
            state.channels      = ss->channels();
            state.buffer_frames = ss->buffer_frames();
            state.active        = true;
            std::println("audio_service: stream started ({} Hz, {} ch, {} frames)",
                         state.sample_rate, state.channels, state.buffer_frames);
            send_ack(reply, ++reply_seq, seq, audio::Status_Ok);
            break;
        }
        case ControlPayload_StopStream: {
            state.active = false;
            std::println("audio_service: stream stopped");
            send_ack(reply, ++reply_seq, seq, audio::Status_Ok);
            break;
        }
        case ControlPayload_SetParam: {
            auto *sp = ctrl->payload_as_SetParam();
            auto status = set_param(state, sp->param_id(), sp->value())
                ? audio::Status_Ok : audio::Status_InvalidParam;
            std::println("audio_service: set param {} = {} -> {}",
                         static_cast<unsigned>(sp->param_id()), sp->value(),
                         status == audio::Status_Ok ? "ok" : "invalid");
            send_ack(reply, ++reply_seq, seq, status);
            break;
        }
        case ControlPayload_GetParam: {
            auto *gp = ctrl->payload_as_GetParam();
            float val = get_param(state, gp->param_id());
            std::println("audio_service: get param {} -> {}",
                         static_cast<unsigned>(gp->param_id()), val);
            send_param_value(reply, ++reply_seq, seq, gp->param_id(), val);
            break;
        }
        default:
            send_ack(reply, ++reply_seq, seq, audio::Status_Error);
            break;
        }
    }

    registry.unregister_service(cfg->svc_name.c_str());
    std::println("audio_service: shutting down");
    return 0;
}
