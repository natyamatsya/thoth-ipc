// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Higher-level protocol layer built on top of the core IPC transport.
// Port of cpp-ipc/include/libipc/proto/.

pub mod shm_ring;
pub mod service_registry;
pub mod process_manager;
pub mod rt_prio;
pub mod service_group;

pub use shm_ring::ShmRing;
pub use service_registry::{ServiceEntry, ServiceRegistry, MAX_NAME_LEN, MAX_SERVICES};
pub use process_manager::{
    ProcessHandle, WaitResult,
    spawn, spawn_simple, request_shutdown, force_kill, wait_for_exit, shutdown,
};
pub use rt_prio::{audio_period_ns, set_realtime_priority};
pub use service_group::{InstanceRole, ManagedInstance, ServiceGroup, ServiceGroupConfig};
