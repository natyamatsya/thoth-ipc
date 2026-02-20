// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// SHM-backed process service registry.
// Port of cpp-ipc/include/libipc/proto/service_registry.h.

use std::io;
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::{ShmHandle, ShmOpenMode};

// ---------------------------------------------------------------------------
// Constants (match C++)
// ---------------------------------------------------------------------------

pub const MAX_SERVICES: usize = 32;
pub const MAX_NAME_LEN: usize = 64;

// ---------------------------------------------------------------------------
// Shared memory layout
// ---------------------------------------------------------------------------

/// A single service entry in the shared registry.
#[repr(C)]
#[derive(Clone)]
pub struct ServiceEntry {
    /// Logical service name (null-terminated).
    pub name: [u8; MAX_NAME_LEN],
    /// Channel the service listens on.
    pub control_channel: [u8; MAX_NAME_LEN],
    /// Channel the service replies on.
    pub reply_channel: [u8; MAX_NAME_LEN],
    /// PID of the owning process.
    pub pid: i32,
    /// Unix timestamp (seconds) when registered.
    pub registered_at: i64,
    /// Reserved flags.
    pub flags: u32,
}

impl ServiceEntry {
    pub fn active(&self) -> bool {
        self.pid > 0 && self.name[0] != 0
    }

    pub fn name_str(&self) -> &str {
        let end = self.name.iter().position(|&b| b == 0).unwrap_or(MAX_NAME_LEN);
        std::str::from_utf8(&self.name[..end]).unwrap_or("")
    }

    pub fn control_channel_str(&self) -> &str {
        let end = self.control_channel.iter().position(|&b| b == 0).unwrap_or(MAX_NAME_LEN);
        std::str::from_utf8(&self.control_channel[..end]).unwrap_or("")
    }

    pub fn reply_channel_str(&self) -> &str {
        let end = self.reply_channel.iter().position(|&b| b == 0).unwrap_or(MAX_NAME_LEN);
        std::str::from_utf8(&self.reply_channel[..end]).unwrap_or("")
    }

    pub fn is_alive(&self) -> bool {
        if self.pid <= 0 {
            return false;
        }
        is_pid_alive(self.pid)
    }
}

impl Default for ServiceEntry {
    fn default() -> Self {
        unsafe { std::mem::zeroed() }
    }
}

/// Shared memory layout for the registry.
#[repr(C)]
struct RegistryData {
    spinlock: AtomicI32,
    count: u32,
    entries: [ServiceEntry; MAX_SERVICES],
}

impl RegistryData {
    fn lock(&self) {
        while self.spinlock.compare_exchange(0, 1, Ordering::Acquire, Ordering::Relaxed).is_err() {
            std::hint::spin_loop();
        }
    }

    fn unlock(&self) {
        self.spinlock.store(0, Ordering::Release);
    }
}

// ---------------------------------------------------------------------------
// Platform: is_pid_alive
// ---------------------------------------------------------------------------

#[cfg(unix)]
fn is_pid_alive(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 || *libc::__error() != libc::ESRCH }
}

#[cfg(windows)]
fn is_pid_alive(pid: i32) -> bool {
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows_sys::Win32::Foundation::{CloseHandle, STILL_ACTIVE};
    use windows_sys::Win32::System::Threading::GetExitCodeProcess;
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid as u32);
        if h == 0 {
            return false;
        }
        let mut code: u32 = 0;
        let ok = GetExitCodeProcess(h, &mut code) != 0 && code == STILL_ACTIVE;
        CloseHandle(h);
        ok
    }
}

#[cfg(not(any(unix, windows)))]
fn is_pid_alive(_pid: i32) -> bool {
    true
}

// ---------------------------------------------------------------------------
// Current PID
// ---------------------------------------------------------------------------

fn current_pid() -> i32 {
    #[cfg(unix)]
    { unsafe { libc::getpid() } }
    #[cfg(windows)]
    { unsafe { windows_sys::Win32::System::Threading::GetCurrentProcessId() as i32 } }
    #[cfg(not(any(unix, windows)))]
    { 1 }
}

// ---------------------------------------------------------------------------
// ServiceRegistry
// ---------------------------------------------------------------------------

/// Service registry backed by a well-known shared memory segment.
///
/// Any process that opens a `ServiceRegistry` with the same domain sees the
/// same set of registered services.
///
/// Port of `ipc::proto::service_registry` from the C++ libipc library.
pub struct ServiceRegistry {
    _shm: ShmHandle,
    data: *mut RegistryData,
}

unsafe impl Send for ServiceRegistry {}
unsafe impl Sync for ServiceRegistry {}

impl ServiceRegistry {
    fn shm_name(domain: &str) -> String {
        if domain.is_empty() {
            "__ipc_registry__default".to_owned()
        } else {
            format!("__ipc_registry__{domain}")
        }
    }

    /// Open or create the registry for `domain` (default: `"default"`).
    pub fn open(domain: &str) -> io::Result<Self> {
        let name = Self::shm_name(domain);
        let shm = ShmHandle::acquire(&name, std::mem::size_of::<RegistryData>(), ShmOpenMode::CreateOrOpen)?;
        let data = shm.get() as *mut RegistryData;
        Ok(Self { _shm: shm, data })
    }

    fn reg(&self) -> &RegistryData {
        unsafe { &*self.data }
    }

    fn fill_entry(e: &mut ServiceEntry, name: &str, ctrl: &str, reply: &str, pid: i32) {
        *e = ServiceEntry::default();
        copy_str(&mut e.name, name);
        copy_str(&mut e.control_channel, ctrl);
        copy_str(&mut e.reply_channel, reply);
        e.pid = pid;
        e.registered_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
    }

    /// Register a service. Returns `true` on success.
    pub fn register_service(&self, name: &str, control_ch: &str, reply_ch: &str) -> bool {
        self.register_service_as(name, control_ch, reply_ch, current_pid())
    }

    /// Register with an explicit PID (useful for testing).
    pub fn register_service_as(&self, name: &str, control_ch: &str, reply_ch: &str, pid: i32) -> bool {
        if name.is_empty() { return false; }
        let reg = self.reg();
        reg.lock();
        let entries = unsafe { &mut (*self.data).entries };
        // Check for duplicate or reuse stale slot
        for e in entries.iter_mut() {
            if e.active() && e.name_str() == name {
                if e.is_alive() {
                    reg.unlock();
                    return false; // already registered and alive
                }
                Self::fill_entry(e, name, control_ch, reply_ch, pid);
                reg.unlock();
                return true;
            }
        }
        // Find empty slot
        for e in entries.iter_mut() {
            if !e.active() || !e.is_alive() {
                Self::fill_entry(e, name, control_ch, reply_ch, pid);
                unsafe {
                    let count = &mut (*self.data).count;
                    if (*count as usize) < MAX_SERVICES { *count += 1; }
                }
                reg.unlock();
                return true;
            }
        }
        reg.unlock();
        false // registry full
    }

    /// Unregister a service by name. Only the owning PID can unregister.
    pub fn unregister_service(&self, name: &str) -> bool {
        self.unregister_service_as(name, current_pid())
    }

    /// Unregister with an explicit PID.
    pub fn unregister_service_as(&self, name: &str, pid: i32) -> bool {
        let reg = self.reg();
        reg.lock();
        let entries = unsafe { &mut (*self.data).entries };
        for e in entries.iter_mut() {
            if e.active() && e.name_str() == name && e.pid == pid {
                *e = ServiceEntry::default();
                reg.unlock();
                return true;
            }
        }
        reg.unlock();
        false
    }

    /// Look up a service by exact name. Returns a copy if found and alive.
    pub fn find(&self, name: &str) -> Option<ServiceEntry> {
        let reg = self.reg();
        reg.lock();
        let entries = unsafe { &mut (*self.data).entries };
        let mut result = None;
        for e in entries.iter_mut() {
            if e.active() && e.name_str() == name {
                if !e.is_alive() {
                    *e = ServiceEntry::default(); // auto-clean stale
                    continue;
                }
                result = Some(e.clone());
                break;
            }
        }
        reg.unlock();
        result
    }

    /// Find all live entries whose name starts with `prefix`.
    pub fn find_all(&self, prefix: &str) -> Vec<ServiceEntry> {
        let reg = self.reg();
        reg.lock();
        let entries = unsafe { &mut (*self.data).entries };
        let mut result = Vec::new();
        for e in entries.iter_mut() {
            if !e.active() { continue; }
            if !e.is_alive() {
                *e = ServiceEntry::default();
                continue;
            }
            if e.name_str().starts_with(prefix) {
                result.push(e.clone());
            }
        }
        reg.unlock();
        result
    }

    /// List all live services.
    pub fn list(&self) -> Vec<ServiceEntry> {
        let reg = self.reg();
        reg.lock();
        let entries = unsafe { &mut (*self.data).entries };
        let mut result = Vec::new();
        for e in entries.iter_mut() {
            if !e.active() { continue; }
            if !e.is_alive() {
                *e = ServiceEntry::default();
                continue;
            }
            result.push(e.clone());
        }
        reg.unlock();
        result
    }

    /// Remove all entries for dead processes. Returns count removed.
    pub fn gc(&self) -> usize {
        let reg = self.reg();
        reg.lock();
        let entries = unsafe { &mut (*self.data).entries };
        let mut removed = 0;
        for e in entries.iter_mut() {
            if e.active() && !e.is_alive() {
                *e = ServiceEntry::default();
                removed += 1;
            }
        }
        reg.unlock();
        removed
    }

    /// Clear the entire registry.
    pub fn clear(&self) {
        let reg = self.reg();
        reg.lock();
        unsafe {
            let entries = &mut (*self.data).entries;
            for e in entries.iter_mut() { *e = ServiceEntry::default(); }
            (*self.data).count = 0;
        }
        reg.unlock();
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn copy_str(dst: &mut [u8; MAX_NAME_LEN], src: &str) {
    let bytes = src.as_bytes();
    let len = bytes.len().min(MAX_NAME_LEN - 1);
    dst[..len].copy_from_slice(&bytes[..len]);
    dst[len] = 0;
}
