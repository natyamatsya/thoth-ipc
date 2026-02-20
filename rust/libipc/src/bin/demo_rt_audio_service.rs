// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Rust port of demo/audio_realtime/service.cpp
//
// Usage: demo_rt_audio_service [instance_id]
//
// Registers itself in the service registry (ring name in control_channel,
// state name in reply_channel), then runs a real-time audio render loop
// producing audio_block values into a ShmRing<AudioBlock, 4>.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use libipc::proto::rt_prio::{audio_period_ns, set_realtime_priority};
use libipc::proto::service_registry::ServiceRegistry;
use libipc::proto::shm_ring::ShmRing;
use libipc::{ShmHandle, ShmOpenMode};

// ---------------------------------------------------------------------------
// Audio block — must match the host layout exactly.
// ---------------------------------------------------------------------------

const MAX_FRAMES: usize   = 1024;
const MAX_CHANNELS: usize = 2;

#[repr(C)]
#[derive(Copy, Clone)]
struct AudioBlock {
    sequence:    u64,
    sample_rate: u32,
    channels:    u32,
    frames:      u32,
    _pad:        u32,
    samples:     [f32; MAX_FRAMES * MAX_CHANNELS],
}

impl Default for AudioBlock {
    fn default() -> Self {
        unsafe { std::mem::zeroed() }
    }
}

// ---------------------------------------------------------------------------
// Shared state — atomics in SHM, written by host, read by service.
// Layout must match the host's SharedState exactly.
// ---------------------------------------------------------------------------

#[repr(C)]
struct SharedState {
    heartbeat_ns:      AtomicU64,
    sample_rate:       AtomicU32,
    channels:          AtomicU32,
    frames_per_buffer: AtomicU32,
    stream_active:     AtomicBool,
    _pad0:             [u8; 3],
    gain:              AtomicU32, // f32 bits
    pan:               AtomicU32, // f32 bits
    blocks_produced:   AtomicU64,
    blocks_consumed:   AtomicU64,
    underruns:         AtomicU64,
    overruns:          AtomicU64,
}

fn f32_load(a: &AtomicU32) -> f32 {
    f32::from_bits(a.load(Ordering::Relaxed))
}

fn now_ns() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Audio render: 440 Hz sine scaled by gain/pan
// ---------------------------------------------------------------------------

fn render_audio(blk: &mut AudioBlock, seq: u64, state: &SharedState) {
    blk.sequence    = seq;
    blk.sample_rate = state.sample_rate.load(Ordering::Relaxed);
    blk.channels    = state.channels.load(Ordering::Relaxed);
    blk.frames      = state.frames_per_buffer.load(Ordering::Relaxed);

    let gain  = f32_load(&state.gain);
    let pan   = f32_load(&state.pan);
    let l_gain = gain * (1.0 - pan) * 0.5;
    let r_gain = gain * (1.0 + pan) * 0.5;

    let freq: f32 = 440.0;
    let two_pi: f32 = 2.0 * std::f32::consts::PI;
    let sr = blk.sample_rate as f32;

    for f in 0..blk.frames as usize {
        let t = (seq as f32 * blk.frames as f32 + f as f32) / sr;
        let s = (two_pi * freq * t).sin();
        if blk.channels >= 1 { blk.samples[f * blk.channels as usize]     = s * l_gain; }
        if blk.channels >= 2 { blk.samples[f * blk.channels as usize + 1] = s * r_gain; }
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let instance_id = args.get(1).map(|s| s.as_str()).unwrap_or("");

    let svc_name   = if instance_id.is_empty() { "rt_audio".to_string() }
                     else { format!("rt_audio.{instance_id}") };
    let ring_name  = if instance_id.is_empty() { "rt_audio_ring".to_string() }
                     else { format!("rt_audio_ring_{instance_id}") };
    let state_name = if instance_id.is_empty() { "rt_audio_state".to_string() }
                     else { format!("rt_audio_state_{instance_id}") };

    // Open shared state SHM.
    let state_shm = ShmHandle::acquire(
        &state_name,
        std::mem::size_of::<SharedState>(),
        ShmOpenMode::CreateOrOpen,
    )
    .expect("shared state shm");
    let state = unsafe { &*(state_shm.get() as *const SharedState) };

    // Open ring buffer.
    let mut ring: ShmRing<AudioBlock, 4> = ShmRing::new(&ring_name);
    ring.open_or_create().expect("ring open");

    // Register in service registry (ring name → control_channel, state name → reply_channel).
    let registry = ServiceRegistry::open("audio_rt").expect("registry");
    registry.register_service(&svc_name, &ring_name, &state_name);

    println!("rt_service[{svc_name}]: starting (pid={})...", std::process::id());
    println!("rt_service[{svc_name}]: registered (ring={ring_name} state={state_name})");

    // Set real-time thread priority (best-effort).
    let period = audio_period_ns(48000, 256);
    if set_realtime_priority(period, None, None) {
        println!("rt_service[{svc_name}]: real-time priority set (period={period} ns)");
    } else {
        println!("rt_service[{svc_name}]: running without RT priority");
    }

    let running = AtomicBool::new(true);

    // Install signal handler.
    #[cfg(unix)]
    unsafe {
        extern "C" fn on_signal(_: libc::c_int) {}
        libc::signal(libc::SIGINT,  on_signal as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, on_signal as *const () as libc::sighandler_t);
    }

    println!("rt_service[{svc_name}]: entering render loop");

    let mut seq: u64 = 0;
    let mut next_wake = Instant::now();

    while running.load(Ordering::Relaxed) {
        if !state.stream_active.load(Ordering::Acquire) {
            std::thread::sleep(Duration::from_millis(10));
            state.heartbeat_ns.store(now_ns(), Ordering::Release);
            continue;
        }

        let sr  = state.sample_rate.load(Ordering::Relaxed);
        let fpb = state.frames_per_buffer.load(Ordering::Relaxed);
        if sr == 0 || fpb == 0 {
            std::thread::sleep(Duration::from_millis(1));
            continue;
        }

        let callback_period = Duration::from_nanos(fpb as u64 * 1_000_000_000 / sr as u64);

        let mut blk = AudioBlock::default();
        render_audio(&mut blk, seq, state);

        ring.write_overwrite(&blk);
        seq += 1;

        state.blocks_produced.fetch_add(1, Ordering::Relaxed);
        state.heartbeat_ns.store(now_ns(), Ordering::Release);

        next_wake += callback_period;
        let now = Instant::now();
        if next_wake > now {
            std::thread::sleep(next_wake - now);
        } else {
            next_wake = now;
        }
    }

    registry.unregister_service(&svc_name);
    println!("rt_service[{svc_name}]: shutting down");
}

#[cfg(unix)]
extern crate libc;
