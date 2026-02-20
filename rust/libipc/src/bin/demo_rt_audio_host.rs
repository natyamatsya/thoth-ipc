// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Rust port of demo/audio_realtime/host.cpp
//
// Usage: demo_rt_audio_host <path_to_demo_rt_audio_service>
//
// Spawns 2 service replicas, connects to the primary's ShmRing and
// shared_state, consumes audio blocks, simulates a crash, fails over to
// the warm standby, then shuts down cleanly.
//
// Key difference from audio_service demo: no FlatBuffers on the data path.
// Parameters are written directly into shared_state atomics; the ring carries
// raw audio_block structs.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use libipc::proto::service_group::{InstanceRole, ServiceGroup, ServiceGroupConfig};
use libipc::proto::service_registry::ServiceRegistry;
use libipc::proto::shm_ring::ShmRing;
use libipc::{ShmHandle, ShmOpenMode};

// ---------------------------------------------------------------------------
// Audio block — must match service layout exactly.
// ---------------------------------------------------------------------------

const MAX_FRAMES: usize = 1024;
const MAX_CHANNELS: usize = 2;

#[repr(C)]
#[derive(Copy, Clone)]
struct AudioBlock {
    sequence: u64,
    sample_rate: u32,
    channels: u32,
    frames: u32,
    _pad: u32,
    samples: [f32; MAX_FRAMES * MAX_CHANNELS],
}

impl Default for AudioBlock {
    fn default() -> Self {
        unsafe { std::mem::zeroed() }
    }
}

// ---------------------------------------------------------------------------
// Shared state — must match service layout exactly.
// ---------------------------------------------------------------------------

#[repr(C)]
struct SharedState {
    heartbeat_ns: AtomicU64,
    sample_rate: AtomicU32,
    channels: AtomicU32,
    frames_per_buffer: AtomicU32,
    stream_active: AtomicBool,
    _pad0: [u8; 3],
    gain: AtomicU32, // f32 bits
    pan: AtomicU32,  // f32 bits
    blocks_produced: AtomicU64,
    blocks_consumed: AtomicU64,
    underruns: AtomicU64,
    overruns: AtomicU64,
}

fn f32_store(a: &AtomicU32, v: f32) {
    a.store(v.to_bits(), Ordering::Release);
}

fn f32_load(a: &AtomicU32) -> f32 {
    f32::from_bits(a.load(Ordering::Relaxed))
}

fn now_ns() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
}

fn heartbeat_age_ms(state: &SharedState) -> u64 {
    let hb = state.heartbeat_ns.load(Ordering::Acquire);
    if hb == 0 {
        return u64::MAX;
    }
    let age = now_ns().saturating_sub(hb);
    age / 1_000_000
}

// ---------------------------------------------------------------------------
// Per-instance connection: ring + shared state SHM
// ---------------------------------------------------------------------------

struct InstanceConn {
    ring: Option<ShmRing<AudioBlock, 4>>,
    state_shm: Option<ShmHandle>,
    ring_name: String,
    state_name: String,
}

impl InstanceConn {
    fn new() -> Self {
        Self {
            ring: None,
            state_shm: None,
            ring_name: String::new(),
            state_name: String::new(),
        }
    }

    fn connect(&mut self, ring_name: &str, state_name: &str) -> bool {
        self.ring_name = ring_name.to_owned();
        self.state_name = state_name.to_owned();

        let mut ring: ShmRing<AudioBlock, 4> = ShmRing::new(ring_name);
        if ring.open_or_create().is_err() {
            eprintln!("host: failed to open ring '{ring_name}'");
            return false;
        }
        self.ring = Some(ring);

        match ShmHandle::acquire(
            state_name,
            std::mem::size_of::<SharedState>(),
            ShmOpenMode::CreateOrOpen,
        ) {
            Ok(shm) => {
                self.state_shm = Some(shm);
                true
            }
            Err(_) => {
                eprintln!("host: failed to open state '{state_name}'");
                false
            }
        }
    }

    fn state(&self) -> Option<&SharedState> {
        self.state_shm
            .as_ref()
            .map(|s| unsafe { &*(s.get() as *const SharedState) })
    }

    fn read_block(&mut self) -> Option<AudioBlock> {
        let ring = self.ring.as_mut()?;
        let mut blk = AudioBlock::default();
        if ring.read(&mut blk) {
            Some(blk)
        } else {
            None
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn configure_stream(state: &SharedState, sr: u32, ch: u32, fpb: u32) {
    state.sample_rate.store(sr, Ordering::Relaxed);
    state.channels.store(ch, Ordering::Relaxed);
    state.frames_per_buffer.store(fpb, Ordering::Relaxed);
    state.stream_active.store(true, Ordering::Release);
}

fn print_stats(state: &SharedState) {
    println!(
        "  produced={}  consumed={}  underruns={}  overruns={}  heartbeat_age={} ms",
        state.blocks_produced.load(Ordering::Relaxed),
        state.blocks_consumed.load(Ordering::Relaxed),
        state.underruns.load(Ordering::Relaxed),
        state.overruns.load(Ordering::Relaxed),
        heartbeat_age_ms(state),
    );
}

fn open_state(state_name: &str) -> Option<(ShmHandle, &'static SharedState)> {
    let shm = ShmHandle::acquire(
        state_name,
        std::mem::size_of::<SharedState>(),
        ShmOpenMode::CreateOrOpen,
    )
    .ok()?;
    let ptr = unsafe { &*(shm.get() as *const SharedState) };
    // Extend lifetime: the ShmHandle keeps the mapping alive as long as we hold it.
    let ptr: &'static SharedState = unsafe { std::mem::transmute(ptr) };
    Some((shm, ptr))
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: demo_rt_audio_host <path_to_demo_rt_audio_service>");
        std::process::exit(1);
    }
    let service_bin = &args[1];

    let registry = ServiceRegistry::open("audio_rt").expect("registry");
    registry.gc();

    let cfg = ServiceGroupConfig::new("rt_audio", service_bin);
    let cfg = ServiceGroupConfig { replicas: 2, ..cfg };
    let mut group = ServiceGroup::new(&registry, cfg);

    println!("host: starting service group (2 replicas)...");
    if !group.start() {
        eprintln!("host: failed to start service group");
        std::process::exit(1);
    }
    println!("host: {} instances alive", group.alive_count());

    // Connect to the primary.
    let (ring_name, state_name, primary_name, primary_pid) = {
        let p = group.primary().expect("no primary");
        (
            p.entry.control_channel_str().to_owned(), // ring name stored here
            p.entry.reply_channel_str().to_owned(),   // state name stored here
            p.instance_name.clone(),
            p.entry.pid,
        )
    };

    let mut conn = InstanceConn::new();
    if !conn.connect(&ring_name, &state_name) {
        eprintln!("host: failed to connect to primary");
        std::process::exit(1);
    }
    println!("host: connected to {primary_name} (pid={primary_pid})");

    // Configure stream via shared state (no FlatBuffers).
    println!("\nhost: configuring stream: 48kHz, 2ch, 256 frames");
    configure_stream(conn.state().unwrap(), 48000, 2, 256);

    // Replicate config to standby instances (warm standby).
    for inst in group.instances() {
        if inst.role != InstanceRole::Standby {
            continue;
        }
        let sname = inst.entry.reply_channel_str().to_owned();
        if let Some((shm, ss)) = open_state(&sname) {
            ss.sample_rate.store(48000, Ordering::Relaxed);
            ss.channels.store(2, Ordering::Relaxed);
            ss.frames_per_buffer.store(256, Ordering::Relaxed);
            f32_store(&ss.gain, f32_load(&conn.state().unwrap().gain));
            f32_store(&ss.pan, f32_load(&conn.state().unwrap().pan));
            println!("host: replicated config to standby {}", inst.instance_name);
            drop(shm);
        }
    }

    // Consume audio blocks for 500 ms.
    println!("\nhost: consuming audio for 500ms...");
    let mut consumed: u64 = 0;
    let deadline = Instant::now() + Duration::from_millis(500);

    while Instant::now() < deadline {
        if let Some(blk) = conn.read_block() {
            consumed += 1;
            conn.state()
                .unwrap()
                .blocks_consumed
                .fetch_add(1, Ordering::Relaxed);
            if consumed % 50 == 0 {
                println!(
                    "  block seq={}  frames={}  peak={:.3}",
                    blk.sequence,
                    blk.frames,
                    blk.samples[0].abs()
                );
            }
        } else {
            conn.state()
                .unwrap()
                .underruns
                .fetch_add(1, Ordering::Relaxed);
            thread::sleep(Duration::from_micros(100));
        }
    }

    println!("host: consumed {consumed} blocks");
    print_stats(conn.state().unwrap());

    // Update gain via shared state.
    println!("\nhost: setting gain=0.5 via shared state");
    f32_store(&conn.state().unwrap().gain, 0.5);

    // Replicate gain to standbys.
    for inst in group.instances() {
        if inst.role != InstanceRole::Standby {
            continue;
        }
        let sname = inst.entry.reply_channel_str().to_owned();
        if let Some((shm, ss)) = open_state(&sname) {
            f32_store(&ss.gain, 0.5);
            drop(shm);
        }
    }

    // Consume 100 more blocks to observe gain change.
    println!("host: consuming 100 more blocks with new gain...");
    consumed = 0;
    while consumed < 100 {
        if let Some(blk) = conn.read_block() {
            consumed += 1;
            if consumed == 100 {
                println!(
                    "  block seq={}  peak={:.3} (should be ~0.5x)",
                    blk.sequence,
                    blk.samples[0].abs()
                );
            }
        } else {
            thread::sleep(Duration::from_micros(100));
        }
    }

    // Heartbeat watchdog demo.
    println!(
        "\nhost: heartbeat age = {} ms (should be <10)",
        heartbeat_age_ms(conn.state().unwrap())
    );

    // Simulate crash + failover.
    println!("\n*** SIMULATING PRIMARY CRASH ***\n");
    group.force_failover();

    let (new_ring, new_state_name, new_name, new_pid) = {
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
    println!("host: new primary = {new_name} (pid={new_pid})");

    // Reconnect to new primary's ring + state.
    if !conn.connect(&new_ring, &new_state_name) {
        eprintln!("host: failed to reconnect");
        std::process::exit(1);
    }

    // Activate stream on new primary (warm standby already has config).
    conn.state()
        .unwrap()
        .stream_active
        .store(true, Ordering::Release);
    println!("host: activated stream on new primary");

    // Wait for respawned standby.
    println!("\nhost: waiting for new standby to register...");
    thread::sleep(Duration::from_millis(500));

    // Replicate state to new standby.
    for inst in group.instances() {
        if inst.role != InstanceRole::Standby || !inst.is_alive() {
            continue;
        }
        println!(
            "host: new standby {} (pid={}) is alive",
            inst.instance_name, inst.entry.pid
        );
        let sname = inst.entry.reply_channel_str().to_owned();
        if let Some((shm, ss)) = open_state(&sname) {
            ss.sample_rate.store(48000, Ordering::Relaxed);
            ss.channels.store(2, Ordering::Relaxed);
            ss.frames_per_buffer.store(256, Ordering::Relaxed);
            f32_store(&ss.gain, f32_load(&conn.state().unwrap().gain));
            f32_store(&ss.pan, f32_load(&conn.state().unwrap().pan));
            println!(
                "host: replicated state to new standby {}",
                inst.instance_name
            );
            drop(shm);
        }
    }

    println!("\nhost: --- instances after respawn ---");
    for inst in group.instances() {
        println!(
            "  [{}] {:<20}  role={:<8}  pid={}  alive={}",
            inst.id,
            inst.instance_name,
            format!("{:?}", inst.role),
            inst.entry.pid,
            inst.is_alive() as u8
        );
    }

    // Brief settle time.
    thread::sleep(Duration::from_millis(50));

    // Consume audio from new primary for 300 ms.
    println!("\nhost: consuming audio from new primary for 300ms...");
    consumed = 0;
    let deadline = Instant::now() + Duration::from_millis(300);

    while Instant::now() < deadline {
        if let Some(_blk) = conn.read_block() {
            consumed += 1;
            conn.state()
                .unwrap()
                .blocks_consumed
                .fetch_add(1, Ordering::Relaxed);
        } else {
            conn.state()
                .unwrap()
                .underruns
                .fetch_add(1, Ordering::Relaxed);
            thread::sleep(Duration::from_micros(100));
        }
    }

    println!("host: consumed {consumed} blocks from new primary");
    print_stats(conn.state().unwrap());

    // Final state.
    println!("\nhost: --- final state ---");
    for inst in group.instances() {
        println!(
            "  [{}] {:<20}  role={:<8}  pid={}  alive={}",
            inst.id,
            inst.instance_name,
            format!("{:?}", inst.role),
            inst.entry.pid,
            inst.is_alive() as u8
        );
    }

    // Clean shutdown.
    println!("\nhost: shutting down...");
    if let Some(s) = conn.state() {
        s.stream_active.store(false, Ordering::Release);
    }
    thread::sleep(Duration::from_millis(50));
    group.stop(Duration::from_secs(3));
    println!("host: done");
}
