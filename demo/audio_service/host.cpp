// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

#include <cstdio>
#include <cstdlib>
#include <thread>
#include <chrono>
#include <string>

#include "audio_protocol_generated.h"
#include "libipc/proto/typed_channel.h"
#include "libipc/proto/service_registry.h"
#include "libipc/proto/service_group.h"

// --- Helpers ---

static bool send_and_recv(ipc::proto::typed_channel<audio::ControlMsg> &control,
                          ipc::proto::typed_channel<audio::ReplyMsg> &reply,
                          ipc::proto::builder &b, const char *label) {
    std::printf("host: sending %s\n", label);
    if (!control.send(b)) {
        std::printf("host: send failed (service down?)\n");
        return false;
    }
    auto msg = reply.recv(2000);
    if (!msg) {
        std::printf("host: no reply (timeout)\n");
        return false;
    }
    auto *r = msg.root();
    switch (r->payload_type()) {
    case audio::ReplyPayload_Ack: {
        auto *ack = r->payload_as_Ack();
        std::printf("host:   ack ref_seq=%llu status=%u\n",
                    (unsigned long long)ack->ref_seq(), ack->status());
        break;
    }
    case audio::ReplyPayload_ParamValue: {
        auto *pv = r->payload_as_ParamValue();
        std::printf("host:   param %u = %f\n", pv->param_id(), pv->value());
        break;
    }
    default: break;
    }
    return true;
}

static bool connect_to_primary(const ipc::proto::managed_instance &primary,
                               ipc::proto::typed_channel<audio::ControlMsg> &control,
                               ipc::proto::typed_channel<audio::ReplyMsg> &reply) {
    std::printf("host: connecting to %s (pid=%d) ctrl='%s' reply='%s'\n",
                primary.instance_name.c_str(), primary.entry.pid,
                primary.entry.control_channel, primary.entry.reply_channel);
    control.disconnect();
    reply.disconnect();
    control.connect(primary.entry.control_channel, ipc::sender);
    reply.connect(primary.entry.reply_channel, ipc::receiver);
    // Brief settle time for the channel shared memory handshake
    std::this_thread::sleep_for(std::chrono::milliseconds{200});
    std::printf("host: connected (recv_count=%zu)\n", control.raw().recv_count());
    return true;
}

// --- Main ---

int main(int argc, char *argv[]) {
    if (argc < 2) {
        std::printf("usage: audio_host <path_to_audio_service>\n");
        return 1;
    }
    const char *service_bin = argv[1];

    ipc::proto::service_registry registry("audio");
    registry.gc(); // clean stale entries from previous runs

    // --- Start a redundant service group (2 replicas) ---
    ipc::proto::service_group group(registry, {
        .service_name = "audio_compute",
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

    // --- Connect to the primary ---
    ipc::proto::typed_channel<audio::ControlMsg> control;
    ipc::proto::typed_channel<audio::ReplyMsg>   reply;
    connect_to_primary(*group.primary(), control, reply);

    uint64_t seq = 0;

    // 1. Send some commands to the primary
    {
        ipc::proto::builder b;
        auto ss = audio::CreateStartStream(b.fbb(), 48000, 2, 256);
        auto msg = audio::CreateControlMsg(b.fbb(), ++seq,
            audio::ControlPayload_StartStream, ss.Union());
        b.finish(msg);
        send_and_recv(control, reply, b, "StartStream (48kHz, 2ch, 256)");
    }
    {
        ipc::proto::builder b;
        auto sp = audio::CreateSetParam(b.fbb(), audio::ParamType_Gain, 0.75f);
        auto msg = audio::CreateControlMsg(b.fbb(), ++seq,
            audio::ControlPayload_SetParam, sp.Union());
        b.finish(msg);
        send_and_recv(control, reply, b, "SetParam(Gain, 0.75)");
    }

    // 2. List all instances
    std::printf("\nhost: --- instances before crash ---\n");
    for (auto &inst : group.instances())
        std::printf("  [%d] %-24s  role=%-8s  pid=%d  alive=%d\n",
                    inst.id, inst.instance_name.c_str(),
                    inst.role == ipc::proto::instance_role::primary ? "PRIMARY" :
                    inst.role == ipc::proto::instance_role::standby ? "STANDBY" : "DEAD",
                    inst.proc.pid, inst.is_alive());

    // 3. Simulate a crash: kill the primary
    std::printf("\n*** SIMULATING PRIMARY CRASH ***\n\n");
    group.force_failover();

    // 4. Health check detects the crash + promotes standby
    std::printf("host: health_check → failover=%s\n",
                group.health_check() ? "yes" : "no");

    std::printf("\nhost: --- instances after failover ---\n");
    for (auto &inst : group.instances())
        std::printf("  [%d] %-24s  role=%-8s  pid=%d  alive=%d\n",
                    inst.id, inst.instance_name.c_str(),
                    inst.role == ipc::proto::instance_role::primary ? "PRIMARY" :
                    inst.role == ipc::proto::instance_role::standby ? "STANDBY" : "DEAD",
                    inst.proc.pid, inst.is_alive());

    // 5. Reconnect to the new primary
    auto *new_primary = group.primary();
    if (!new_primary) {
        std::printf("host: all instances dead!\n");
        return 1;
    }
    connect_to_primary(*new_primary, control, reply);

    // 6. Resume sending commands — seamless to the application
    {
        ipc::proto::builder b;
        auto ss = audio::CreateStartStream(b.fbb(), 48000, 2, 256);
        auto msg = audio::CreateControlMsg(b.fbb(), ++seq,
            audio::ControlPayload_StartStream, ss.Union());
        b.finish(msg);
        send_and_recv(control, reply, b, "StartStream (re-sent after failover)");
    }
    {
        ipc::proto::builder b;
        auto gp = audio::CreateGetParam(b.fbb(), audio::ParamType_Gain);
        auto msg = audio::CreateControlMsg(b.fbb(), ++seq,
            audio::ControlPayload_GetParam, gp.Union());
        b.finish(msg);
        send_and_recv(control, reply, b, "GetParam(Gain) on new primary");
    }

    // 7. Show final state
    std::printf("\nhost: --- final state ---\n");
    std::printf("host: %d instances alive\n", group.alive_count());
    for (auto &svc : registry.list())
        std::printf("  %-24s  pid=%-6d  ctrl=%s\n",
                    svc.name, svc.pid, svc.control_channel);

    // 8. Clean shutdown of all instances
    std::printf("\nhost: shutting down all instances...\n");
    group.stop();
    std::printf("host: done\n");
    return 0;
}
