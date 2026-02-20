// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Redundant service group with automatic failover.
// Port of cpp-ipc/include/libipc/proto/service_group.h.

use std::time::{Duration, Instant};

use super::process_manager::{force_kill, shutdown, spawn, wait_for_exit, ProcessHandle};
use super::service_registry::{ServiceEntry, ServiceRegistry};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Role of an instance within the group.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstanceRole {
    Primary,
    Standby,
    Dead,
}

/// A single managed service instance.
pub struct ManagedInstance {
    pub id: usize,
    pub role: InstanceRole,
    pub proc: ProcessHandle,
    pub entry: ServiceEntry,
    pub instance_name: String,
}

impl ManagedInstance {
    pub fn is_alive(&self) -> bool {
        self.proc.is_alive()
    }
}

/// Configuration for a service group.
pub struct ServiceGroupConfig {
    /// Logical service name (e.g. `"audio_compute"`).
    pub service_name: String,
    /// Path to the service binary.
    pub executable: String,
    /// Total instances (1 primary + N-1 standby).
    pub replicas: usize,
    /// Automatically respawn dead instances.
    pub auto_respawn: bool,
    /// Timeout waiting for a spawned process to register.
    pub spawn_timeout: Duration,
}

impl ServiceGroupConfig {
    pub fn new(service_name: &str, executable: &str) -> Self {
        Self {
            service_name: service_name.to_owned(),
            executable: executable.to_owned(),
            replicas: 2,
            auto_respawn: true,
            spawn_timeout: Duration::from_secs(5),
        }
    }
}

// ---------------------------------------------------------------------------
// ServiceGroup
// ---------------------------------------------------------------------------

/// Manages a group of redundant service instances with automatic failover.
///
/// Port of `ipc::proto::service_group` from the C++ libipc library.
pub struct ServiceGroup<'a> {
    registry: &'a ServiceRegistry,
    config: ServiceGroupConfig,
    instances: Vec<ManagedInstance>,
    primary_idx: Option<usize>,
}

impl<'a> ServiceGroup<'a> {
    pub fn new(registry: &'a ServiceRegistry, config: ServiceGroupConfig) -> Self {
        let replicas = config.replicas;
        let service_name = config.service_name.clone();
        let mut instances = Vec::with_capacity(replicas);
        for i in 0..replicas {
            instances.push(ManagedInstance {
                id: i,
                role: InstanceRole::Dead,
                proc: ProcessHandle::invalid(),
                entry: ServiceEntry::default(),
                instance_name: format!("{service_name}.{i}"),
            });
        }
        Self {
            registry,
            config,
            instances,
            primary_idx: None,
        }
    }

    /// Spawn all instances. The first live one becomes primary.
    /// Returns `true` if at least one instance is alive.
    pub fn start(&mut self) -> bool {
        for i in 0..self.instances.len() {
            self.spawn_instance(i);
        }
        self.elect_primary()
    }

    /// Perform a health check. Returns `true` if a failover occurred.
    pub fn health_check(&mut self) -> bool {
        let mut failover_needed = false;
        for inst in &mut self.instances {
            if inst.role == InstanceRole::Dead {
                continue;
            }
            if !inst.is_alive() {
                if inst.role == InstanceRole::Primary {
                    failover_needed = true;
                }
                inst.role = InstanceRole::Dead;
            }
        }

        if failover_needed {
            self.elect_primary();
            if self.config.auto_respawn {
                self.respawn_dead();
            }
            return true;
        }

        if self.config.auto_respawn {
            self.respawn_dead();
        }
        false
    }

    /// Get the current primary instance.
    pub fn primary(&self) -> Option<&ManagedInstance> {
        let idx = self.primary_idx?;
        let inst = &self.instances[idx];
        if inst.role == InstanceRole::Primary {
            Some(inst)
        } else {
            None
        }
    }

    /// All instances.
    pub fn instances(&self) -> &[ManagedInstance] {
        &self.instances
    }

    /// Shut down all instances gracefully.
    pub fn stop(&mut self, grace: Duration) {
        for inst in &mut self.instances {
            if inst.is_alive() {
                shutdown(&inst.proc, grace);
            }
            inst.role = InstanceRole::Dead;
        }
        self.primary_idx = None;
    }

    /// Number of live instances.
    pub fn alive_count(&self) -> usize {
        self.instances.iter().filter(|i| i.is_alive()).count()
    }

    /// Force a failover: kill the primary, promote a standby.
    pub fn force_failover(&mut self) -> bool {
        if let Some(idx) = self.primary_idx {
            let inst = &self.instances[idx];
            if inst.is_alive() {
                force_kill(&inst.proc);
                wait_for_exit(&inst.proc, Duration::from_secs(2));
            }
            self.instances[idx].role = InstanceRole::Dead;
        }
        let ok = self.elect_primary();
        if self.config.auto_respawn {
            self.respawn_dead();
        }
        ok
    }

    // --- private ---

    fn spawn_instance(&mut self, i: usize) -> bool {
        self.registry.gc();
        let inst = &self.instances[i];
        let instance_name = inst.instance_name.clone();
        let executable = self.config.executable.clone();
        let id_str = i.to_string();
        let h = spawn(&instance_name, &executable, &[&id_str]);
        if !h.valid() {
            return false;
        }

        let deadline = Instant::now() + self.config.spawn_timeout;
        loop {
            if let Some(e) = self.registry.find(&instance_name) {
                self.instances[i].proc = h;
                self.instances[i].entry = e;
                self.instances[i].role = InstanceRole::Standby;
                return true;
            }
            if !self.instances[i].proc.is_alive() && !h.is_alive() {
                return false;
            }
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn elect_primary(&mut self) -> bool {
        self.primary_idx = None;
        for i in 0..self.instances.len() {
            if self.instances[i].is_alive() {
                self.instances[i].role = InstanceRole::Primary;
                self.primary_idx = Some(i);
                for j in 0..self.instances.len() {
                    if j != i && self.instances[j].is_alive() {
                        self.instances[j].role = InstanceRole::Standby;
                    }
                }
                return true;
            }
        }
        false
    }

    fn respawn_dead(&mut self) {
        for i in 0..self.instances.len() {
            if self.instances[i].role == InstanceRole::Dead {
                self.spawn_instance(i);
            }
        }
    }
}
