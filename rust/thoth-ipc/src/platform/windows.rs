// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Windows implementation of shared memory and named mutex primitives.
// Binary-compatible with cpp-ipc/src/thoth_ipc/platform/win/shm_win.cpp
// and cpp-ipc/src/thoth_ipc/platform/win/mutex.h.

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

/// Compile-time Windows object namespace (default `Local`, the session-local
/// `BaseNamedObjects`). Enable the `win-global` feature to target `Global\`
/// (session 0 — services / cross-session). Must match the C++ side's
/// `LIBIPC_WIN_OBJ_NS` at build time so C++ and Rust name the same kernel
/// objects.
#[cfg(feature = "win-global")]
pub(crate) const WIN_OBJ_NS: &str = "Global";
#[cfg(not(feature = "win-global"))]
pub(crate) const WIN_OBJ_NS: &str = "Local";

/// Qualify a logical object name with the Windows namespace prefix. `Local\<n>`
/// and a bare `<n>` both resolve to the same per-session kernel object, so the
/// default is wire-compatible with an unprefixed peer while making the
/// namespace explicit and switchable. An empty `WIN_OBJ_NS` yields the bare
/// name (verbatim).
pub(crate) fn win_object_name(name: &str) -> String {
    if WIN_OBJ_NS.is_empty() {
        name.to_owned()
    } else {
        format!("{WIN_OBJ_NS}\\{name}")
    }
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
    user_size: usize, // user-requested size
    logical_name: String,
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

        let wide_name = to_wide(&win_object_name(name));

        let handle;
        let total_size;
        let mut opened_existing = false;

        if mode == ShmMode::Open {
            handle = unsafe { OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, wide_name.as_ptr()) };
            if handle.is_null() {
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
                if !handle.is_null() {
                    unsafe { CloseHandle(handle) };
                }
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "shm already exists",
                ));
            }
            opened_existing = err == ERROR_ALREADY_EXISTS;
            if handle.is_null() {
                return Err(io::Error::last_os_error());
            }
        };

        // Map the view
        let mem = unsafe { MapViewOfFile(handle, FILE_MAP_ALL_ACCESS, 0, 0, 0) };
        if mem.Value.is_null() {
            let e = io::Error::last_os_error();
            unsafe { CloseHandle(handle) };
            return Err(e);
        }

        // Discover actual size if opening existing
        let (final_total, final_user) = if total_size == 0 || opened_existing {
            let mut info: MEMORY_BASIC_INFORMATION = unsafe { std::mem::zeroed() };
            let ret = unsafe {
                VirtualQuery(
                    mem.Value as *const _,
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
        unsafe { acc_of(mem.Value as *mut u8, final_total).fetch_add(1, Ordering::Release) };

        Ok(Self {
            handle,
            mem: mem.Value as *mut u8,
            size: final_total,
            user_size: final_user,
            logical_name: name.to_owned(),
        })
    }

    /// Whether this platform can grow an existing shared memory object.
    /// Windows sections are fixed at `CreateFileMapping` — no resize API
    /// exists, so this is always false.
    pub const fn can_grow() -> bool {
        false
    }

    pub fn grow(&mut self, new_user_size: usize) -> io::Result<()> {
        if new_user_size <= self.user_size {
            return Ok(());
        }
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "shared memory growth is unsupported on this platform: Windows sections \
             are fixed at CreateFileMapping; size segments up front or chunk payloads",
        ))
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
        use windows_sys::Win32::System::Memory::{UnmapViewOfFile, MEMORY_MAPPED_VIEW_ADDRESS};

        if !self.mem.is_null() && self.size > 0 {
            unsafe { acc_of(self.mem, self.size).fetch_sub(1, Ordering::AcqRel) };
            unsafe {
                UnmapViewOfFile(MEMORY_MAPPED_VIEW_ADDRESS {
                    Value: self.mem as *mut core::ffi::c_void,
                })
            };
        }
        if !self.handle.is_null() {
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

        let wide_name = to_wide(&win_object_name(name));
        let h = unsafe { CreateMutexW(ptr::null(), FALSE, wide_name.as_ptr()) };
        if h.is_null() {
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
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "mutex lock timed out",
                    ))
                }
                WAIT_ABANDONED => {
                    // Previous owner died — we acquired the lock. Unlock+retry for consistency.
                    let _ = self.unlock();
                }
                _ => return Err(io::Error::last_os_error()),
            }
        }
    }

    /// Lock with a timeout in milliseconds. `Ok(true)` if acquired, `Ok(false)`
    /// on timeout. Mirrors the POSIX `PlatformMutex::lock_timeout`.
    pub fn lock_timeout(&self, timeout_ms: u64) -> io::Result<bool> {
        use windows_sys::Win32::Foundation::*;
        use windows_sys::Win32::System::Threading::*;

        let ms = timeout_ms.min(u32::MAX as u64) as u32;
        let ret = unsafe { WaitForSingleObject(self.handle, ms) };
        match ret {
            // WAIT_ABANDONED: the previous owner died; ownership is granted to us.
            WAIT_OBJECT_0 | WAIT_ABANDONED => Ok(true),
            WAIT_TIMEOUT => Ok(false),
            _ => Err(io::Error::last_os_error()),
        }
    }

    pub fn try_lock(&self) -> io::Result<bool> {
        use windows_sys::Win32::Foundation::*;
        use windows_sys::Win32::System::Threading::*;

        let ret = unsafe { WaitForSingleObject(self.handle, 0) };
        match ret {
            WAIT_OBJECT_0 => Ok(true),
            WAIT_TIMEOUT => Ok(false),
            WAIT_ABANDONED => {
                let _ = self.unlock();
                Ok(false)
            }
            _ => Err(io::Error::last_os_error()),
        }
    }

    pub fn unlock(&self) -> io::Result<()> {
        use windows_sys::Win32::System::Threading::ReleaseMutex;

        if unsafe { ReleaseMutex(self.handle) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    pub(crate) fn native_ptr(&self) -> *mut u8 {
        self.handle as *mut u8
    }

    pub fn clear_storage(_name: &str) {
        // No-op on Windows.
    }
}

impl Drop for PlatformMutex {
    fn drop(&mut self) {
        use windows_sys::Win32::Foundation::CloseHandle;
        if !self.handle.is_null() {
            unsafe { CloseHandle(self.handle) };
        }
    }
}
