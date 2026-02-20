// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Cross-platform named inter-process mutex.
// Delegates to platform::PlatformMutex (POSIX or Windows).

use std::io;

use crate::platform::PlatformMutex;

/// A named, inter-process mutex.
///
/// On POSIX this is a `pthread_mutex_t` stored in shared memory with
/// `PTHREAD_PROCESS_SHARED` and `PTHREAD_MUTEX_ROBUST` attributes.
/// On Windows this is a kernel named mutex via `CreateMutex`.
///
/// Binary-compatible with `ipc::sync::mutex` from the C++ libipc library.
pub struct IpcMutex {
    inner: PlatformMutex,
}

impl IpcMutex {
    /// Open (or create) a named inter-process mutex.
    pub fn open(name: &str) -> io::Result<Self> {
        let inner = PlatformMutex::open(name)?;
        Ok(Self { inner })
    }

    /// Whether this mutex handle is valid (always true after successful `open`).  
    /// Mirrors C++ `ipc::sync::mutex::valid()`.
    pub fn valid(&self) -> bool {
        true
    }

    /// Lock the mutex (blocking, infinite timeout).
    ///
    /// On POSIX, handles `EOWNERDEAD` (previous owner died) by calling
    /// `pthread_mutex_consistent` and returning success.
    pub fn lock(&self) -> io::Result<()> {
        self.inner.lock()
    }

    /// Lock the mutex with a timeout.
    /// Returns `Ok(true)` if the lock was acquired within `timeout_ms` milliseconds.
    /// Returns `Ok(false)` on timeout.
    /// Mirrors C++ `ipc::sync::mutex::lock(tm)`.
    pub fn lock_timeout(&self, timeout_ms: u64) -> io::Result<bool> {
        self.inner.lock_timeout(timeout_ms)
    }

    /// Try to lock the mutex without blocking.
    /// Returns `Ok(true)` if the lock was acquired, `Ok(false)` if contended.
    pub fn try_lock(&self) -> io::Result<bool> {
        self.inner.try_lock()
    }

    /// Unlock the mutex.
    pub fn unlock(&self) -> io::Result<()> {
        self.inner.unlock()
    }

    /// Remove the backing storage for a named mutex (static helper).
    pub fn clear_storage(name: &str) {
        PlatformMutex::clear_storage(name);
    }

    /// Raw pointer to the underlying platform mutex.
    /// On POSIX this is `*mut pthread_mutex_t`, on Windows a `HANDLE`.
    /// Used internally by `IpcCondition` for `pthread_cond_wait`.
    pub(crate) fn native_mutex_ptr(&self) -> *mut u8 {
        self.inner.native_ptr()
    }
}
