// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Rust port of demo/audio_service/host.cpp
//
// Usage: demo_audio_host <path_to_demo_audio_service>
//
// Spawns 2 service replicas, connects to the primary, sends commands,
// simulates a crash, fails over to the standby, then shuts down cleanly.

#![allow(dead_code)]

include!(concat!(env!("OUT_DIR"), "/audio_protocol_generated.rs"));

// Note: the generated file imports `core::cmp::Ordering`; avoid importing
// std::sync::atomic names directly to prevent conflicts.

use std::thread;
use std::time::Duration;

use libipc::channel::Mode;
use libipc::proto::message::Builder;
use libipc::proto::service_group::{ServiceGroup, ServiceGroupConfig};
use libipc::proto::service_registry::ServiceRegistry;
use libipc::proto::typed_channel::TypedChannel;

use audio::{
    ControlMsg, ControlMsgBuilder, ControlPayload, GetParamBuilder, ParamType, ReplyMsg,
    ReplyPayload, SetParamBuilder, StartStreamBuilder,
};

fn send_and_recv(
    control: &mut TypedChannel<ControlMsg<'static>>,
    reply: &mut TypedChannel<ReplyMsg<'static>>,
    b: &Builder,
    label: &str,
) -> bool {
    println!("host: sending {label}");
    if control.send_builder(b, 0).is_err() {
        println!("host: send failed (service down?)");
        return false;
    }
    let msg = match reply.recv(Some(2000)) {
        Ok(m) => m,
        Err(_) => {
            println!("host: no reply (timeout)");
            return false;
        }
    };
    if msg.is_empty() {
        println!("host: no reply (timeout)");
        return false;
    }
    let buf = msg.data().to_vec();
    let r = match flatbuffers::root::<ReplyMsg>(&buf) {
        Ok(r) => r,
        Err(e) => {
            println!("host: bad reply: {e}");
            return false;
        }
    };
    match r.payload_type() {
        ReplyPayload::Ack => {
            if let Some(ack) = r.payload_as_ack() {
                println!(
                    "host:   ack ref_seq={} status={:?}",
                    ack.ref_seq(),
                    ack.status()
                );
            }
        }
        ReplyPayload::ParamValue => {
            if let Some(pv) = r.payload_as_param_value() {
                println!("host:   param {:?} = {}", pv.param_id(), pv.value());
            }
        }
        _ => {}
    }
    true
}

fn build_start_stream(seq: u64, sample_rate: u32, channels: u16, buffer_frames: u32) -> Builder {
    let mut b = Builder::new(256);
    let ss_off = {
        let mut bld = StartStreamBuilder::new(b.fbb());
        bld.add_sample_rate(sample_rate);
        bld.add_channels(channels);
        bld.add_buffer_frames(buffer_frames);
        bld.finish()
    };
    let msg_off = {
        let mut bld = ControlMsgBuilder::new(b.fbb());
        bld.add_seq(seq);
        bld.add_payload_type(ControlPayload::StartStream);
        bld.add_payload(ss_off.as_union_value());
        bld.finish()
    };
    b.finish(msg_off);
    b
}

fn build_set_param(seq: u64, param: ParamType, value: f32) -> Builder {
    let mut b = Builder::new(256);
    let sp_off = {
        let mut bld = SetParamBuilder::new(b.fbb());
        bld.add_param_id(param);
        bld.add_value(value);
        bld.finish()
    };
    let msg_off = {
        let mut bld = ControlMsgBuilder::new(b.fbb());
        bld.add_seq(seq);
        bld.add_payload_type(ControlPayload::SetParam);
        bld.add_payload(sp_off.as_union_value());
        bld.finish()
    };
    b.finish(msg_off);
    b
}

fn build_get_param(seq: u64, param: ParamType) -> Builder {
    let mut b = Builder::new(256);
    let gp_off = {
        let mut bld = GetParamBuilder::new(b.fbb());
        bld.add_param_id(param);
        bld.finish()
    };
    let msg_off = {
        let mut bld = ControlMsgBuilder::new(b.fbb());
        bld.add_seq(seq);
        bld.add_payload_type(ControlPayload::GetParam);
        bld.add_payload(gp_off.as_union_value());
        bld.finish()
    };
    b.finish(msg_off);
    b
}

fn reconnect(
    ctrl_ch: &str,
    reply_ch: &str,
    control: &mut TypedChannel<ControlMsg<'static>>,
    reply: &mut TypedChannel<ReplyMsg<'static>>,
) {
    println!("host: connecting ctrl='{ctrl_ch}' reply='{reply_ch}'");
    control.disconnect();
    reply.disconnect();
    *control = TypedChannel::connect(ctrl_ch, Mode::Sender).expect("control sender");
    *reply = TypedChannel::connect(reply_ch, Mode::Receiver).expect("reply receiver");
    thread::sleep(Duration::from_millis(200));
    println!(
        "host: connected (recv_count={})",
        control.raw().recv_count()
    );
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: demo_audio_host <path_to_demo_audio_service>");
        std::process::exit(1);
    }
    let service_bin = &args[1];

    let registry = ServiceRegistry::open("audio").expect("registry");
    registry.gc();

    let cfg = ServiceGroupConfig::new("audio_compute", service_bin);
    // Override replicas to 2 (default already is 2, but be explicit).
    let cfg = ServiceGroupConfig { replicas: 2, ..cfg };
    let mut group = ServiceGroup::new(&registry, cfg);

    println!("host: starting service group (2 replicas)...");
    if !group.start() {
        eprintln!("host: failed to start service group");
        std::process::exit(1);
    }
    println!("host: {} instances alive", group.alive_count());

    // Connect to the primary.
    let (ctrl_ch, reply_ch, primary_name, primary_pid) = {
        let p = group.primary().expect("no primary");
        (
            p.entry.control_channel_str().to_owned(),
            p.entry.reply_channel_str().to_owned(),
            p.instance_name.clone(),
            p.entry.pid,
        )
    };
    println!(
        "host: connecting to {primary_name} (pid={primary_pid}) ctrl='{ctrl_ch}' reply='{reply_ch}'"
    );
    let mut control: TypedChannel<ControlMsg> =
        TypedChannel::connect(&ctrl_ch, Mode::Sender).expect("control sender");
    let mut reply: TypedChannel<ReplyMsg> =
        TypedChannel::connect(&reply_ch, Mode::Receiver).expect("reply receiver");
    thread::sleep(Duration::from_millis(200));
    println!(
        "host: connected (recv_count={})",
        control.raw().recv_count()
    );

    let mut seq: u64 = 0;

    // 1. Send commands to the primary.
    seq += 1;
    send_and_recv(
        &mut control,
        &mut reply,
        &build_start_stream(seq, 48000, 2, 256),
        "StartStream (48kHz, 2ch, 256)",
    );
    seq += 1;
    send_and_recv(
        &mut control,
        &mut reply,
        &build_set_param(seq, ParamType::Gain, 0.75),
        "SetParam(Gain, 0.75)",
    );

    // 2. List instances before crash.
    println!("\nhost: --- instances before crash ---");
    for inst in group.instances() {
        println!(
            "  [{}] {:<24}  role={:<8}  pid={}  alive={}",
            inst.id,
            inst.instance_name,
            format!("{:?}", inst.role),
            inst.entry.pid,
            inst.is_alive() as u8
        );
    }

    // 3. Simulate crash.
    println!("\n*** SIMULATING PRIMARY CRASH ***\n");
    group.force_failover();

    // 4. Health check detects crash + promotes standby.
    let failed_over = group.health_check();
    println!(
        "host: health_check → failover={}",
        if failed_over { "yes" } else { "no" }
    );

    println!("\nhost: --- instances after failover ---");
    for inst in group.instances() {
        println!(
            "  [{}] {:<24}  role={:<8}  pid={}  alive={}",
            inst.id,
            inst.instance_name,
            format!("{:?}", inst.role),
            inst.entry.pid,
            inst.is_alive() as u8
        );
    }

    // 5. Wait for respawned standby.
    println!("host: waiting for new standby to register...");
    thread::sleep(Duration::from_millis(500));
    println!(
        "host: {} instances alive after respawn",
        group.alive_count()
    );

    println!("\nhost: --- instances after respawn ---");
    for inst in group.instances() {
        println!(
            "  [{}] {:<24}  role={:<8}  pid={}  alive={}",
            inst.id,
            inst.instance_name,
            format!("{:?}", inst.role),
            inst.entry.pid,
            inst.is_alive() as u8
        );
    }

    // 6. Reconnect to the new primary.
    let (new_ctrl, new_reply, new_name, new_pid) = {
        let p = match group.primary() {
            Some(p) => p,
            None => {
                eprintln!("host: all instances dead!");
                std::process::exit(1);
            }
        };
        (
            p.entry.control_channel_str().to_owned(),
            p.entry.reply_channel_str().to_owned(),
            p.instance_name.clone(),
            p.entry.pid,
        )
    };
    println!(
        "host: connecting to {new_name} (pid={new_pid}) ctrl='{new_ctrl}' reply='{new_reply}'"
    );
    reconnect(&new_ctrl, &new_reply, &mut control, &mut reply);

    // 7. Resume commands on new primary.
    seq += 1;
    send_and_recv(
        &mut control,
        &mut reply,
        &build_start_stream(seq, 48000, 2, 256),
        "StartStream (re-sent after failover)",
    );
    seq += 1;
    send_and_recv(
        &mut control,
        &mut reply,
        &build_get_param(seq, ParamType::Gain),
        "GetParam(Gain) on new primary",
    );

    // 8. Final state.
    println!("\nhost: --- final state ---");
    println!("host: {} instances alive", group.alive_count());
    for svc in registry.list() {
        println!(
            "  {:<24}  pid={:<6}  ctrl={}",
            svc.name_str(),
            svc.pid,
            svc.control_channel_str()
        );
    }

    // 9. Clean shutdown.
    println!("\nhost: shutting down all instances...");
    group.stop(Duration::from_secs(3));
    println!("host: done");
}
