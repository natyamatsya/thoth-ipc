#include <cstdio>
#include <thread>
#include <chrono>

#include "audio_protocol_generated.h"
#include "libipc/proto/typed_channel.h"

static void wait_reply(ipc::proto::typed_channel<audio::ReplyMsg> &reply) {
    auto msg = reply.recv(2000); // 2s timeout
    if (!msg) {
        std::printf("host: no reply (timeout)\n");
        return;
    }
    auto *r = msg.root();
    std::printf("host: reply seq=%llu type=%u\n",
                (unsigned long long)r->seq(), r->payload_type());

    switch (r->payload_type()) {
    case audio::ReplyPayload_Ack: {
        auto *ack = r->payload_as_Ack();
        std::printf("host:   ack ref_seq=%llu status=%u\n",
                    (unsigned long long)ack->ref_seq(), ack->status());
        break;
    }
    case audio::ReplyPayload_ParamValue: {
        auto *pv = r->payload_as_ParamValue();
        std::printf("host:   param %u = %f (ref_seq=%llu)\n",
                    pv->param_id(), pv->value(),
                    (unsigned long long)pv->ref_seq());
        break;
    }
    default:
        break;
    }
}

int main() {
    std::printf("host: connecting...\n");

    ipc::proto::typed_channel<audio::ControlMsg> control("audio_ctrl", ipc::sender);
    ipc::proto::typed_channel<audio::ReplyMsg>   reply("audio_reply", ipc::receiver);

    // Wait for service to connect
    control.raw().wait_for_recv(1);
    std::printf("host: service connected\n");

    uint64_t seq = 0;

    // 1. Start stream
    {
        ipc::proto::builder b;
        auto ss = audio::CreateStartStream(b.fbb(), 48000, 2, 256);
        auto msg = audio::CreateControlMsg(b.fbb(), ++seq,
            audio::ControlPayload_StartStream, ss.Union());
        b.finish(msg);
        std::printf("host: sending StartStream (48kHz, 2ch, 256 frames)\n");
        control.send(b);
        wait_reply(reply);
    }

    // 2. Set gain
    {
        ipc::proto::builder b;
        auto sp = audio::CreateSetParam(b.fbb(), audio::ParamType_Gain, 0.75f);
        auto msg = audio::CreateControlMsg(b.fbb(), ++seq,
            audio::ControlPayload_SetParam, sp.Union());
        b.finish(msg);
        std::printf("host: sending SetParam(Gain, 0.75)\n");
        control.send(b);
        wait_reply(reply);
    }

    // 3. Get gain back
    {
        ipc::proto::builder b;
        auto gp = audio::CreateGetParam(b.fbb(), audio::ParamType_Gain);
        auto msg = audio::CreateControlMsg(b.fbb(), ++seq,
            audio::ControlPayload_GetParam, gp.Union());
        b.finish(msg);
        std::printf("host: sending GetParam(Gain)\n");
        control.send(b);
        wait_reply(reply);
    }

    // 4. Stop stream
    {
        ipc::proto::builder b;
        auto ss = audio::CreateStopStream(b.fbb());
        auto msg = audio::CreateControlMsg(b.fbb(), ++seq,
            audio::ControlPayload_StopStream, ss.Union());
        b.finish(msg);
        std::printf("host: sending StopStream\n");
        control.send(b);
        wait_reply(reply);
    }

    std::printf("host: done\n");
    return 0;
}
