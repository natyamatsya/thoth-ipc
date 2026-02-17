// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Windows implementation of shared memory and named mutex primitives.
// Binary-compatible with cpp-ipc/src/libipc/platform/win/shm_win.cpp
// and cpp-ipc/src/libipc/platform/win/mutex.h.

use std::io;
use std::ptr;
use std::sync::atomic::{AtomicI32, Ordering};

// ---------------------------------------------------------------------------
// Layout helpers — must match C++ calc_size() and acc_of()
// ---------------------------------------------------------------------------

const ALIGN: usize = std::mem::align_of::<AtomicI32>();

pub(crate) fn calc_size(user_size: usize) -> usize {
    let aligned = ((user_size.wrapping_sub(1) / ALIGN) + 1) * ALIGN;
    aligned + std::mem::size_of::<AtomicI32>()
}

unsafe fn acc_of(mem: *mut u8, total_size: usize) -> &'static AtomicI32 {
    let offset = total_size - std::mem::size_of::<AtomicI32>();
    &*(mem.add(offset) as *const AtomicI32)
}

/// Encode a name as a null-terminated wide string for Win32 APIs.
fn to_wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

// ---------------------------------------------------------------------------
// PlatformShm — Windows shared memory via file mapping
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShmMode {
    Create,
    Open,
    CreateOrOpen,
}

pub struct PlatformShm {
    handle: windows_sys::Win32::Foundation::HANDLE,
    mem: *mut u8,
    size: usize,      // total mapped size
    user_size: usize,  // user-requested size
}

unsafe impl Send for PlatformShm {}
unsafe impl Sync for PlatformShm {}

impl PlatformShm {
    pub fn acquire(name: &str, user_size: usize, mode: ShmMode) -> io::Result<Self> {
        use windows_sys::Win32::Foundation::*;
        use windows_sys::Win32::System::Memory::*;

        if name.is_empty() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "name is empty"));
        }
        if user_size == 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "size is 0"));
        }

        let wide_name = to_wide(name);

        let handle;
        let total_size;

        if mode == ShmMode::Open {
            handle = unsafe {
                OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, wide_name.as_ptr())
            };
            if handle == 0 {
                return Err(io::Error::last_os_error());
            }
            total_size = 0; // will be discovered after mapping
        } else {
            total_size = calc_size(user_size);
            handle = unsafe {
                CreateFileMappingW(
                    INVALID_HANDLE_VALUE,
                    ptr::null(),
                    PAGE_READWRITE | SEC_COMMIT,
                    0,
                    total_size as u32,
                    wide_name.as_ptr(),
                )
            };
            let err = unsafe { GetLastError() };
            if mode == ShmMode::Create && err == ERROR_ALREADY_EXISTS {
                if handle != 0 {
                    unsafe { CloseHandle(handle) };
                }
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "shm already exists",
                ));
            }
            if handle == 0 {
                return Err(io::Error::last_os_error());
            }
        };

        // Map the view
        let mem = unsafe { MapViewOfFile(handle, FILE_MAP_ALL_ACCESS, 0, 0, 0) };
        if mem.is_null() {
            let e = io::Error::last_os_error();
            unsafe { CloseHandle(handle) };
            return Err(e);
        }

        // Discover actual size if opening existing
        let (final_total, final_user) = if total_size == 0 {
            let mut info: MEMORY_BASIC_INFORMATION = unsafe { std::mem::zeroed() };
            let ret = unsafe {
                VirtualQuery(
                    mem as *const _,
                    &mut info,
                    std::mem::size_of::<MEMORY_BASIC_INFORMATION>(),
                )
            };
            if ret == 0 {
                let e = io::Error::last_os_error();
                unsafe {
                    UnmapViewOfFile(mem);
                    CloseHandle(handle);
                }
                return Err(e);
            }
            let actual = info.RegionSize;
            let u = actual - std::mem::size_of::<AtomicI32>();
            (actual, u)
        } else {
            (total_size, user_size)
        };

        // Increment reference counter
        unsafe { acc_of(mem as *mut u8, final_total).fetch_add(1, Ordering::Release) };

        Ok(Self {
            handle,
            mem: mem as *mut u8,
            size: final_total,
            user_size: final_user,
        })
    }

    pub fn as_ptr(&self) -> *const u8 {
        self.mem
    }

    pub fn as_mut_ptr(&self) -> *mut u8 {
        self.mem
    }

    pub fn mapped_size(&self) -> usize {
        self.size
    }

    pub fn user_size(&self) -> usize {
        self.user_size
    }

    pub fn ref_count(&self) -> i32 {
        if self.mem.is_null() || self.size == 0 {
            return 0;
        }
        unsafe { acc_of(self.mem, self.size).load(Ordering::Acquire) }
    }

    pub fn unlink(&self) {
        // On Windows, shm is backed by the pagefile — no file to unlink.
    }

    pub fn unlink_by_name(_name: &str) {
        // No-op on Windows.
    }
}

impl Drop for PlatformShm {
    fn drop(&mut self) {
        use windows_sys::Win32::Foundation::CloseHandle;
        use windows_sys::Win32::System::Memory::UnmapViewOfFile;

        if !self.mem.is_null() && self.size > 0 {
            unsafe { acc_of(self.mem, self.size).fetch_sub(1, Ordering::AcqRel) };
            unsafe { UnmapViewOfFile(self.mem as *const _) };
        }
        if self.handle != 0 {
            unsafe { CloseHandle(self.handle) };
        }
    }
}

// ---------------------------------------------------------------------------
// PlatformMutex — Windows named mutex
// ---------------------------------------------------------------------------

pub struct PlatformMutex {
    handle: windows_sys::Win32::Foundation::HANDLE,
}

unsafe impl Send for PlatformMutex {}
unsafe impl Sync for PlatformMutex {}

impl PlatformMutex {
    pub fn open(name: &str) -> io::Result<Self> {
        use windows_sys::Win32::Foundation::FALSE;
        use windows_sys::Win32::System::Threading::CreateMutexW;

        let wide_name = to_wide(name);
        let h = unsafe { CreateMutexW(ptr::null(), FALSE, wide_name.as_ptr()) };
        if h == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { handle: h })
    }

    pub fn lock(&self) -> io::Result<()> {
        use windows_sys::Win32::Foundation::*;
        use windows_sys::Win32::System::Threading::*;

        loop {
            let ret = unsafe { WaitForSingleObject(self.handle, INFINITE) };
            match ret {
                WAIT_OBJECT_0 => return Ok(()),
                WAIT_TIMEOUT => {
                    return Err(io::Error::new(io::ErrorKind::TimedOut, "mutex lock timed out"))
                }
                WAIT_ABANDONED => {
                    // Previous owner died — we acquired the lock. Unlock+retry for consistency.
                    let _ = self.unlock();
                }
                _ => return Err(io::Error::last_os_error()),
            }
        }
    }

    pub fn unlock(&self) -> io::Result<()> {
        use windows_sys::Win32::System::Threading::ReleaseMutex;

        if unsafe { ReleaseMutex(self.handle) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    pub fn clear_storage(_name: &str) {
        // No-op on Windows.
    }
}

impl Drop for PlatformMutex {
    fn drop(&mut self) {
        use windows_sys::Win32::Foundation::CloseHandle;
        if self.handle != 0 {
            unsafe { CloseHandle(self.handle) };
        }
    }
}
