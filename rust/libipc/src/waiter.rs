// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/src/libipc/waiter.h.
// Condition-variable + mutex wrapper used by the IPC channel to
// sleep/wake sender and receiver threads.

use std::io;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::{IpcCondition, IpcMutex};

/// A named waiter combining a condition variable, a mutex, and a quit flag.
///
/// Used internally by IPC channels to implement blocking send/recv with
/// timeout support. Mirrors `ipc::detail::waiter` from the C++ library.
pub struct Waiter {
    cond: IpcCondition,
    lock: IpcMutex,
    quit: AtomicBool,
}

impl Waiter {
    /// Open a named waiter. Creates the underlying condition variable and mutex
    /// with names derived from `name`.
    pub fn open(name: &str) -> io::Result<Self> {
        let cond_name = format!("{name}_WAITER_COND_");
        let lock_name = format!("{name}_WAITER_LOCK_");
        let cond = IpcCondition::open(&cond_name)?;
        let lock = IpcMutex::open(&lock_name)?;
        Ok(Self {
            cond,
            lock,
            quit: AtomicBool::new(false),
        })
    }

    /// Block until `pred` returns `false` or quit is signalled.
    /// Returns `false` on timeout, `true` otherwise.
    pub fn wait_if<F>(&self, pred: F, timeout_ms: Option<u64>) -> io::Result<bool>
    where
        F: Fn() -> bool,
    {
        self.lock.lock()?;
        while !self.quit.load(Ordering::Relaxed) && pred() {
            match self.cond.wait(&self.lock, timeout_ms)? {
                false => {
                    self.lock.unlock()?;
                    return Ok(false); // timeout
                }
                true => {} // signalled, re-check predicate
            }
        }
        self.lock.unlock()?;
        Ok(true)
    }

    /// Wake one waiter.
    pub fn notify(&self) -> io::Result<()> {
        // Barrier: briefly acquire lock to ensure waiter is in cond_wait
        self.lock.lock()?;
        self.lock.unlock()?;
        self.cond.notify()
    }

    /// Wake all waiters.
    pub fn broadcast(&self) -> io::Result<()> {
        self.lock.lock()?;
        self.lock.unlock()?;
        self.cond.broadcast()
    }

    /// Signal quit and broadcast to wake all waiters.
    pub fn quit_waiting(&self) -> io::Result<()> {
        self.quit.store(true, Ordering::Release);
        self.broadcast()
    }

    /// Remove the backing storage for a named waiter.
    pub fn clear_storage(name: &str) {
        IpcCondition::clear_storage(&format!("{name}_WAITER_COND_"));
        IpcMutex::clear_storage(&format!("{name}_WAITER_LOCK_"));
    }
}
