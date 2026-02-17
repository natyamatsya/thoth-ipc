// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Cross-platform shared memory handle.
// Delegates to platform::PlatformShm (POSIX or Windows).

use std::io;

use crate::platform::PlatformShm;

/// Open mode for shared memory segments.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShmOpenMode {
    /// Create exclusively — fail if already exists.
    Create,
    /// Open existing — fail if it does not exist.
    Open,
    /// Create if missing, open if it already exists.
    CreateOrOpen,
}

/// A named, inter-process shared memory region.
///
/// Binary-compatible with `ipc::shm::handle` from the C++ libipc library.
/// The memory layout includes a trailing `atomic<int32_t>` reference counter
/// that is shared between all processes mapping the same segment.
pub struct ShmHandle {
    inner: PlatformShm,
}

impl ShmHandle {
    /// Acquire a named shared memory region of `size` bytes (user-visible).
    ///
    /// The actual mapped region is slightly larger to hold the ref counter.
    pub fn acquire(name: &str, size: usize, mode: ShmOpenMode) -> io::Result<Self> {
        #[cfg(unix)]
        let platform_mode = match mode {
            ShmOpenMode::Create => crate::platform::posix::ShmMode::Create,
            ShmOpenMode::Open => crate::platform::posix::ShmMode::Open,
            ShmOpenMode::CreateOrOpen => crate::platform::posix::ShmMode::CreateOrOpen,
        };
        #[cfg(windows)]
        let platform_mode = match mode {
            ShmOpenMode::Create => crate::platform::windows::ShmMode::Create,
            ShmOpenMode::Open => crate::platform::windows::ShmMode::Open,
            ShmOpenMode::CreateOrOpen => crate::platform::windows::ShmMode::CreateOrOpen,
        };

        let inner = PlatformShm::acquire(name, size, platform_mode)?;
        Ok(Self { inner })
    }

    /// Pointer to the start of the user-visible shared memory region.
    pub fn as_ptr(&self) -> *const u8 {
        self.inner.as_ptr()
    }

    /// Mutable pointer to the start of the user-visible shared memory region.
    pub fn as_mut_ptr(&self) -> *mut u8 {
        self.inner.as_mut_ptr()
    }

    /// Total mapped size (including the trailing ref counter).
    pub fn mapped_size(&self) -> usize {
        self.inner.mapped_size()
    }

    /// User-requested size (the usable portion).
    pub fn user_size(&self) -> usize {
        self.inner.user_size()
    }

    /// The platform name used to open the segment.
    #[cfg(unix)]
    pub fn name(&self) -> &str {
        self.inner.name()
    }

    /// Current reference count (number of processes/handles mapping this segment).
    pub fn ref_count(&self) -> i32 {
        self.inner.ref_count()
    }

    /// Force-remove the backing file / kernel object.
    pub fn unlink(&self) {
        self.inner.unlink();
    }

    /// Mutable pointer to the user-visible region (alias for `as_mut_ptr`).
    /// Matches C++ `shm::handle::get()`.
    pub fn get(&self) -> *mut u8 {
        self.inner.as_mut_ptr()
    }

    /// Remove a named shm segment by name without needing an open handle.
    pub fn unlink_by_name(name: &str) {
        PlatformShm::unlink_by_name(name);
    }

    /// Remove the backing storage for a named shm segment.
    pub fn clear_storage(name: &str) {
        PlatformShm::unlink_by_name(name);
    }
}
