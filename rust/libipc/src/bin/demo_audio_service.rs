// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Rust port of demo/audio_service/service.cpp
//
// Usage: demo_audio_service [instance_id]
//
// Registers itself in the service registry, then loops receiving ControlMsg
// commands on a typed channel and sending ReplyMsg responses.

#![allow(dead_code)]

include!(concat!(env!("OUT_DIR"), "/audio_protocol_generated.rs"));

// Note: the generated file imports `core::cmp::Ordering`; use full paths for
// `std::sync::atomic` to avoid a name collision.

use libipc::channel::Mode;
use libipc::proto::message::Builder;
use libipc::proto::service_registry::ServiceRegistry;
use libipc::proto::typed_channel::TypedChannel;

use audio::{
    AckBuilder, ControlMsg, ControlPayload, ParamType, ParamValueBuilder, ReplyMsg,
    ReplyMsgBuilder, Status,
};

struct StreamState {
    sample_rate: u32,
    channels: u16,
    buffer_frames: u32,
    active: bool,
    gain: f32,
    pan: f32,
}

impl Default for StreamState {
    fn default() -> Self {
        Self {
            sample_rate: 48000,
            channels: 2,
            buffer_frames: 512,
            active: false,
            gain: 1.0,
            pan: 0.0,
        }
    }
}

fn get_param(st: &StreamState, id: ParamType) -> f32 {
    match id {
        ParamType::Gain => st.gain,
        ParamType::Pan => st.pan,
        _ => 0.0,
    }
}

fn set_param(st: &mut StreamState, id: ParamType, val: f32) -> bool {
    match id {
        ParamType::Gain => {
            st.gain = val;
            true
        }
        ParamType::Pan => {
            st.pan = val;
            true
        }
        _ => false,
    }
}

fn send_ack(reply: &mut TypedChannel<ReplyMsg<'static>>, seq: u64, ref_seq: u64, status: Status) {
    let mut b = Builder::new(256);
    let ack_off = {
        let mut bld = AckBuilder::new(b.fbb());
        bld.add_ref_seq(ref_seq);
        bld.add_status(status);
        bld.finish()
    };
    let msg_off = {
        let mut bld = ReplyMsgBuilder::new(b.fbb());
        bld.add_seq(seq);
        bld.add_payload_type(audio::ReplyPayload::Ack);
        bld.add_payload(ack_off.as_union_value());
        bld.finish()
    };
    b.finish(msg_off);
    reply.send_builder(&b, 0).ok();
}

fn send_param_value(
    reply: &mut TypedChannel<ReplyMsg<'static>>,
    seq: u64,
    ref_seq: u64,
    id: ParamType,
    val: f32,
) {
    let mut b = Builder::new(256);
    let pv_off = {
        let mut bld = ParamValueBuilder::new(b.fbb());
        bld.add_ref_seq(ref_seq);
        bld.add_param_id(id);
        bld.add_value(val);
        bld.finish()
    };
    let msg_off = {
        let mut bld = ReplyMsgBuilder::new(b.fbb());
        bld.add_seq(seq);
        bld.add_payload_type(audio::ReplyPayload::ParamValue);
        bld.add_payload(pv_off.as_union_value());
        bld.finish()
    };
    b.finish(msg_off);
    reply.send_builder(&b, 0).ok();
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let instance_id = args.get(1).map(|s| s.as_str()).unwrap_or("");

    let svc_name = if instance_id.is_empty() {
        "audio_compute".to_string()
    } else {
        format!("audio_compute.{instance_id}")
    };
    let ctrl_ch = if instance_id.is_empty() {
        "audio_ctrl".to_string()
    } else {
        format!("audio_ctrl_{instance_id}")
    };
    let reply_ch = if instance_id.is_empty() {
        "audio_reply".to_string()
    } else {
        format!("audio_reply_{instance_id}")
    };

    TypedChannel::<ControlMsg>::clear_storage(&ctrl_ch);
    TypedChannel::<ReplyMsg>::clear_storage(&reply_ch);

    let registry = ServiceRegistry::open("audio").expect("registry");
    let mut control: TypedChannel<ControlMsg> =
        TypedChannel::connect(&ctrl_ch, Mode::Receiver).expect("control channel");
    let mut reply: TypedChannel<ReplyMsg> =
        TypedChannel::connect(&reply_ch, Mode::Sender).expect("reply channel");

    registry.register_service(&svc_name, &ctrl_ch, &reply_ch);

    println!(
        "audio_service[{svc_name}]: starting (pid={})...",
        std::process::id()
    );
    println!("audio_service[{svc_name}]: registered in service registry");
    println!("audio_service: waiting for commands on '{ctrl_ch}'");

    let running = std::sync::atomic::AtomicBool::new(true);

    let mut state = StreamState::default();
    let mut reply_seq: u64 = 0;

    while running.load(std::sync::atomic::Ordering::Acquire) {
        let msg = match control.recv(Some(100)) {
            Ok(m) => m,
            Err(_) => continue,
        };
        if msg.is_empty() {
            continue;
        }

        let buf = msg.data().to_vec();
        let ctrl = match flatbuffers::root::<ControlMsg>(&buf) {
            Ok(c) => c,
            Err(_) => continue,
        };

        let seq = ctrl.seq();
        println!(
            "audio_service: received command seq={seq} type={:?}",
            ctrl.payload_type()
        );

        match ctrl.payload_type() {
            ControlPayload::StartStream => {
                if let Some(ss) = ctrl.payload_as_start_stream() {
                    state.sample_rate = ss.sample_rate();
                    state.channels = ss.channels();
                    state.buffer_frames = ss.buffer_frames();
                    state.active = true;
                    println!(
                        "audio_service: stream started ({} Hz, {} ch, {} frames)",
                        state.sample_rate, state.channels, state.buffer_frames
                    );
                    reply_seq += 1;
                    send_ack(&mut reply, reply_seq, seq, Status::Ok);
                }
            }
            ControlPayload::StopStream => {
                state.active = false;
                println!("audio_service: stream stopped");
                reply_seq += 1;
                send_ack(&mut reply, reply_seq, seq, Status::Ok);
            }
            ControlPayload::SetParam => {
                if let Some(sp) = ctrl.payload_as_set_param() {
                    let ok = set_param(&mut state, sp.param_id(), sp.value());
                    let status = if ok { Status::Ok } else { Status::InvalidParam };
                    println!(
                        "audio_service: set param {:?} = {} -> {:?}",
                        sp.param_id(),
                        sp.value(),
                        status
                    );
                    reply_seq += 1;
                    send_ack(&mut reply, reply_seq, seq, status);
                }
            }
            ControlPayload::GetParam => {
                if let Some(gp) = ctrl.payload_as_get_param() {
                    let val = get_param(&state, gp.param_id());
                    println!("audio_service: get param {:?} -> {val}", gp.param_id());
                    reply_seq += 1;
                    send_param_value(&mut reply, reply_seq, seq, gp.param_id(), val);
                }
            }
            _ => {
                reply_seq += 1;
                send_ack(&mut reply, reply_seq, seq, Status::Error);
            }
        }
    }

    registry.unregister_service(&svc_name);
    println!("audio_service: shutting down");
}
