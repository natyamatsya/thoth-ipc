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

    /// Lock the mutex (blocking, infinite timeout).
    ///
    /// On POSIX, handles `EOWNERDEAD` (previous owner died) by calling
    /// `pthread_mutex_consistent` and returning success.
    pub fn lock(&self) -> io::Result<()> {
        self.inner.lock()
    }

    /// Unlock the mutex.
    pub fn unlock(&self) -> io::Result<()> {
        self.inner.unlock()
    }

    /// Remove the backing storage for a named mutex (static helper).
    pub fn clear_storage(name: &str) {
        PlatformMutex::clear_storage(name);
    }
}
