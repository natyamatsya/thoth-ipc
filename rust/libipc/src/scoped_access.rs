// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// RAII guard that locks a named mutex for the lifetime of the access,
// providing read/write to a shared memory region.
// Mirrors Sourcetrail's `IpcSharedMemory::ScopedAccess`.

use std::io;

use crate::{IpcMutex, ShmHandle};

/// RAII guard: locks the mutex on construction, unlocks on drop.
/// Provides `read()` / `write()` access to the underlying shared memory.
pub struct ScopedAccess<'a> {
    shm: &'a ShmHandle,
    mtx: &'a IpcMutex,
}

impl<'a> ScopedAccess<'a> {
    /// Create a new scoped access guard. Locks `mtx` immediately.
    pub fn new(shm: &'a ShmHandle, mtx: &'a IpcMutex) -> io::Result<Self> {
        mtx.lock()?;
        Ok(Self { shm, mtx })
    }

    /// Read the raw shared memory contents.
    /// Returns `(pointer, length)` where length is the total mapped size.
    pub fn read(&self) -> (&[u8], usize) {
        let len = self.shm.mapped_size();
        let slice = unsafe { std::slice::from_raw_parts(self.shm.as_ptr(), len) };
        (slice, len)
    }

    /// Write `buf` into the shared memory region.
    ///
    /// # Errors
    /// Returns an error if `buf` is larger than the mapped region.
    pub fn write(&self, buf: &[u8]) -> io::Result<()> {
        let cap = self.shm.mapped_size();
        if buf.len() > cap {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!(
                    "buffer too large for shared memory region ({} > {})",
                    buf.len(),
                    cap
                ),
            ));
        }
        unsafe {
            std::ptr::copy_nonoverlapping(buf.as_ptr(), self.shm.as_mut_ptr(), buf.len());
        }
        Ok(())
    }

    /// Raw pointer to the mapped region (for zero-copy FlatBuffer access).
    pub fn as_ptr(&self) -> *const u8 {
        self.shm.as_ptr()
    }

    /// Mutable raw pointer to the mapped region.
    pub fn as_mut_ptr(&self) -> *mut u8 {
        self.shm.as_mut_ptr()
    }

    /// Total mapped size.
    pub fn size(&self) -> usize {
        self.shm.mapped_size()
    }
}

impl<'a> Drop for ScopedAccess<'a> {
    fn drop(&mut self) {
        let _ = self.mtx.unlock();
    }
}
