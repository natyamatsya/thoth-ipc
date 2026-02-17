// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Cross-platform named inter-process semaphore.
// POSIX: sem_open / sem_wait / sem_post (with macOS sem_timedwait emulation).
// Windows: CreateSemaphore / WaitForSingleObject / ReleaseSemaphore.

use std::io;

use crate::shm_name;

/// A named, inter-process semaphore.
///
/// On POSIX this uses `sem_open` with a name derived from `make_shm_name`.
/// On macOS, timed waits are emulated via `sem_trywait` polling (macOS lacks
/// `sem_timedwait`). On Windows this uses `CreateSemaphore`.
pub struct IpcSemaphore {
    #[cfg(unix)]
    inner: PosixSemaphore,
    #[cfg(windows)]
    inner: WindowsSemaphore,
}

impl IpcSemaphore {
    /// Open (or create) a named semaphore with the given initial count.
    pub fn open(name: &str, count: u32) -> io::Result<Self> {
        #[cfg(unix)]
        let inner = PosixSemaphore::open(name, count)?;
        #[cfg(windows)]
        let inner = WindowsSemaphore::open(name, count)?;
        Ok(Self { inner })
    }

    /// Decrement (wait on) the semaphore.
    /// If `timeout_ms` is `None`, blocks indefinitely.
    /// If `timeout_ms` is `Some(ms)`, waits at most `ms` milliseconds.
    /// Returns `Ok(true)` if acquired, `Ok(false)` on timeout.
    pub fn wait(&self, timeout_ms: Option<u64>) -> io::Result<bool> {
        self.inner.wait(timeout_ms)
    }

    /// Increment (post) the semaphore `count` times.
    pub fn post(&self, count: u32) -> io::Result<()> {
        self.inner.post(count)
    }

    /// Remove the backing storage for a named semaphore.
    pub fn clear_storage(name: &str) {
        #[cfg(unix)]
        PosixSemaphore::clear_storage(name);
        #[cfg(windows)]
        { let _ = name; }
    }
}

// ---------------------------------------------------------------------------
// POSIX implementation
// ---------------------------------------------------------------------------

#[cfg(unix)]
struct PosixSemaphore {
    handle: *mut libc::sem_t,
    sem_name: std::ffi::CString,
}

#[cfg(unix)]
unsafe impl Send for PosixSemaphore {}
#[cfg(unix)]
unsafe impl Sync for PosixSemaphore {}

#[cfg(unix)]
impl PosixSemaphore {
    fn open(name: &str, count: u32) -> io::Result<Self> {
        if name.is_empty() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "name is empty"));
        }

        // Append "_s" before hashing to separate from shm namespace (matches C++)
        let raw = format!("{name}_s");
        let posix_name = shm_name::make_shm_name(&raw);
        let c_name = std::ffi::CString::new(posix_name.as_bytes())
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;

        let h = unsafe {
            libc::sem_open(
                c_name.as_ptr(),
                libc::O_CREAT,
                0o666 as libc::c_uint,
                count as libc::c_uint,
            )
        };
        if h == libc::SEM_FAILED {
            return Err(io::Error::last_os_error());
        }

        Ok(Self {
            handle: h,
            sem_name: c_name,
        })
    }

    fn wait(&self, timeout_ms: Option<u64>) -> io::Result<bool> {
        match timeout_ms {
            None => {
                if unsafe { libc::sem_wait(self.handle) } != 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(true)
            }
            Some(ms) => self.timed_wait(ms),
        }
    }

    #[cfg(not(target_os = "macos"))]
    fn timed_wait(&self, ms: u64) -> io::Result<bool> {
        use std::time::{SystemTime, UNIX_EPOCH};
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        let deadline = now + std::time::Duration::from_millis(ms);
        let ts = libc::timespec {
            tv_sec: deadline.as_secs() as libc::time_t,
            tv_nsec: deadline.subsec_nanos() as libc::c_long,
        };
        if unsafe { libc::sem_timedwait(self.handle, &ts) } == 0 {
            return Ok(true);
        }
        let e = io::Error::last_os_error();
        if e.raw_os_error() == Some(libc::ETIMEDOUT) {
            return Ok(false);
        }
        Err(e)
    }

    // macOS lacks sem_timedwait — emulate with polling (matches C++ apple/semaphore_impl.h)
    #[cfg(target_os = "macos")]
    fn timed_wait(&self, ms: u64) -> io::Result<bool> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(ms);
        loop {
            if unsafe { libc::sem_trywait(self.handle) } == 0 {
                return Ok(true);
            }
            let e = io::Error::last_os_error();
            if e.raw_os_error() != Some(libc::EAGAIN) {
                return Err(e);
            }
            if std::time::Instant::now() >= deadline {
                return Ok(false);
            }
            std::thread::sleep(std::time::Duration::from_micros(100));
        }
    }

    fn post(&self, count: u32) -> io::Result<()> {
        for _ in 0..count {
            if unsafe { libc::sem_post(self.handle) } != 0 {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(())
    }

    fn clear_storage(name: &str) {
        let raw = format!("{name}_s");
        let posix_name = shm_name::make_shm_name(&raw);
        if let Ok(c_name) = std::ffi::CString::new(posix_name.as_bytes()) {
            unsafe { libc::sem_unlink(c_name.as_ptr()) };
        }
    }
}

#[cfg(unix)]
impl Drop for PosixSemaphore {
    fn drop(&mut self) {
        if self.handle != libc::SEM_FAILED {
            unsafe { libc::sem_close(self.handle) };
            unsafe { libc::sem_unlink(self.sem_name.as_ptr()) };
        }
    }
}

// ---------------------------------------------------------------------------
// Windows implementation
// ---------------------------------------------------------------------------

#[cfg(windows)]
struct WindowsSemaphore {
    handle: windows_sys::Win32::Foundation::HANDLE,
}

#[cfg(windows)]
unsafe impl Send for WindowsSemaphore {}
#[cfg(windows)]
unsafe impl Sync for WindowsSemaphore {}

#[cfg(windows)]
impl WindowsSemaphore {
    fn open(name: &str, count: u32) -> io::Result<Self> {
        use windows_sys::Win32::System::Threading::CreateSemaphoreW;

        if name.is_empty() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "name is empty"));
        }
        let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
        let h = unsafe {
            CreateSemaphoreW(
                std::ptr::null(),
                count as i32,
                i32::MAX,
                wide.as_ptr(),
            )
        };
        if h == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { handle: h })
    }

    fn wait(&self, timeout_ms: Option<u64>) -> io::Result<bool> {
        use windows_sys::Win32::Foundation::*;
        use windows_sys::Win32::System::Threading::*;

        let ms = match timeout_ms {
            None => INFINITE,
            Some(ms) => ms as u32,
        };
        let ret = unsafe { WaitForSingleObject(self.handle, ms) };
        match ret {
            WAIT_OBJECT_0 => Ok(true),
            WAIT_TIMEOUT => Ok(false),
            _ => Err(io::Error::last_os_error()),
        }
    }

    fn post(&self, count: u32) -> io::Result<()> {
        use windows_sys::Win32::System::Threading::ReleaseSemaphore;

        if unsafe { ReleaseSemaphore(self.handle, count as i32, std::ptr::null_mut()) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
}

#[cfg(windows)]
impl Drop for WindowsSemaphore {
    fn drop(&mut self) {
        use windows_sys::Win32::Foundation::CloseHandle;
        if self.handle != 0 {
            unsafe { CloseHandle(self.handle) };
        }
    }
}
