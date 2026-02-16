#include <cstdio>
#include <csignal>
#include <atomic>
#include <thread>
#include <chrono>
#include <cmath>
#include <vector>

#include "audio_protocol_generated.h"
#include "libipc/proto/typed_channel.h"

static std::atomic<bool> g_running{true};

static void on_signal(int) { g_running.store(false); }

struct StreamState {
    uint32_t sample_rate   = 48000;
    uint16_t channels      = 2;
    uint32_t buffer_frames = 512;
    bool     active        = false;
    float    gain          = 1.0f;
    float    pan           = 0.0f;
};

static float get_param(const StreamState &st, audio::ParamType id) {
    switch (id) {
    case audio::ParamType_Gain: return st.gain;
    case audio::ParamType_Pan:  return st.pan;
    default: return 0.0f;
    }
}

static bool set_param(StreamState &st, audio::ParamType id, float val) {
    switch (id) {
    case audio::ParamType_Gain: st.gain = val; return true;
    case audio::ParamType_Pan:  st.pan  = val; return true;
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

int main() {
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    std::printf("audio_service: starting...\n");

    // Control channel: service receives commands, sends replies
    ipc::proto::typed_channel<audio::ControlMsg> control("audio_ctrl", ipc::receiver);
    ipc::proto::typed_channel<audio::ReplyMsg>   reply("audio_reply", ipc::sender);

    StreamState state;
    uint64_t reply_seq = 0;

    std::printf("audio_service: waiting for commands on 'audio_ctrl'\n");

    while (g_running.load()) {
        auto msg = control.recv(100); // 100ms timeout
        if (!msg) continue;

        auto *ctrl = msg.root();
        if (!ctrl) continue;

        auto seq = ctrl->seq();
        std::printf("audio_service: received command seq=%llu type=%u\n",
                    (unsigned long long)seq, ctrl->payload_type());

        switch (ctrl->payload_type()) {
        case audio::ControlPayload_StartStream: {
            auto *ss = ctrl->payload_as_StartStream();
            state.sample_rate   = ss->sample_rate();
            state.channels      = ss->channels();
            state.buffer_frames = ss->buffer_frames();
            state.active        = true;
            std::printf("audio_service: stream started (%u Hz, %u ch, %u frames)\n",
                        state.sample_rate, state.channels, state.buffer_frames);
            send_ack(reply, ++reply_seq, seq, audio::Status_Ok);
            break;
        }
        case audio::ControlPayload_StopStream: {
            state.active = false;
            std::printf("audio_service: stream stopped\n");
            send_ack(reply, ++reply_seq, seq, audio::Status_Ok);
            break;
        }
        case audio::ControlPayload_SetParam: {
            auto *sp = ctrl->payload_as_SetParam();
            auto status = set_param(state, sp->param_id(), sp->value())
                ? audio::Status_Ok : audio::Status_InvalidParam;
            std::printf("audio_service: set param %u = %f -> %s\n",
                        sp->param_id(), sp->value(),
                        status == audio::Status_Ok ? "ok" : "invalid");
            send_ack(reply, ++reply_seq, seq, status);
            break;
        }
        case audio::ControlPayload_GetParam: {
            auto *gp = ctrl->payload_as_GetParam();
            float val = get_param(state, gp->param_id());
            std::printf("audio_service: get param %u -> %f\n",
                        gp->param_id(), val);
            send_param_value(reply, ++reply_seq, seq, gp->param_id(), val);
            break;
        }
        default:
            send_ack(reply, ++reply_seq, seq, audio::Status_Error);
            break;
        }
    }

    std::printf("audio_service: shutting down\n");
    return 0;
}
