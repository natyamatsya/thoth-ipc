// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Higher-level protocol layer built on top of the core IPC transport.
// Port of cpp-ipc/include/libipc/proto/.

pub mod message;
pub mod process_manager;
pub mod rt_prio;
pub mod service_group;
pub mod service_registry;
pub mod shm_ring;
pub mod typed_channel;
pub mod typed_route;

pub use message::{Builder, Message};
pub use process_manager::{
    force_kill, request_shutdown, shutdown, spawn, spawn_simple, wait_for_exit, ProcessHandle,
    WaitResult,
};
pub use rt_prio::{audio_period_ns, set_realtime_priority};
pub use service_group::{InstanceRole, ManagedInstance, ServiceGroup, ServiceGroupConfig};
pub use service_registry::{ServiceEntry, ServiceRegistry, MAX_NAME_LEN, MAX_SERVICES};
pub use shm_ring::ShmRing;
pub use typed_channel::TypedChannel;
pub use typed_route::TypedRoute;
