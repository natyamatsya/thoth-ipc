// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
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
    #[cfg(target_os = "macos")]
    inner: AppleSemaphore,
    #[cfg(all(unix, not(target_os = "macos")))]
    inner: PosixSemaphore,
    #[cfg(windows)]
    inner: WindowsSemaphore,
}

impl IpcSemaphore {
    /// Open (or create) a named semaphore with the given initial count.
    pub fn open(name: &str, count: u32) -> io::Result<Self> {
        #[cfg(target_os = "macos")]
        let inner = AppleSemaphore::open(name, count)?;
        #[cfg(all(unix, not(target_os = "macos")))]
        let inner = PosixSemaphore::open(name, count)?;
        #[cfg(windows)]
        let inner = WindowsSemaphore::open(name, count)?;
        Ok(Self { inner })
    }

    /// Whether this semaphore handle is valid (always true after successful `open`).
    /// Mirrors C++ `ipc::sync::semaphore::valid()`.
    pub fn valid(&self) -> bool {
        true
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
        #[cfg(target_os = "macos")]
        AppleSemaphore::clear_storage(name);
        #[cfg(all(unix, not(target_os = "macos")))]
        PosixSemaphore::clear_storage(name);
        #[cfg(windows)]
        {
            let _ = name;
        }
    }
}

// ---------------------------------------------------------------------------
// macOS: ulock-based counting semaphore in shared memory — byte-exact with the
// C++ `apple/semaphore_impl.h` (`ulock_sem_t { atomic<u32> count; }`). A POSIX
// `sem_open` object (the generic-unix path below) is a different kernel object
// and does not interoperate with the C++ shm-ulock semaphore; this one does.
// ---------------------------------------------------------------------------

#[cfg(target_os = "macos")]
mod apple {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::time::{Duration, Instant};

    const UL_COMPARE_AND_WAIT_SHARED: u32 = 3;

    extern "C" {
        fn __ulock_wait(operation: u32, addr: *mut u32, value: u64, timeout_us: u32) -> libc::c_int;
        fn __ulock_wake(operation: u32, addr: *mut u32, wake_value: u64) -> libc::c_int;
    }

    pub(super) struct AppleSemaphore {
        shm: crate::shm::ShmHandle,
    }

    unsafe impl Send for AppleSemaphore {}
    unsafe impl Sync for AppleSemaphore {}

    impl AppleSemaphore {
        #[inline]
        fn count_ptr(&self) -> *mut u32 {
            self.shm.get() as *mut u32
        }
        #[inline]
        fn count(&self) -> &AtomicU32 {
            unsafe { &*(self.count_ptr() as *const AtomicU32) }
        }

        pub(super) fn open(name: &str, count: u32) -> io::Result<Self> {
            if name.is_empty() {
                return Err(io::Error::new(io::ErrorKind::InvalidInput, "name is empty"));
            }
            // The harness passes the fully-qualified logical name ("<name>_s");
            // hash it to the byte-exact shm object name (C++ shm::acquire(name)).
            let posix_name = shm_name::make_shm_name(name);
            // sizeof(ulock_sem_t) = 4 (atomic<u32> count); ShmHandle appends the
            // C++ trailing acc_ ref counter (calc_size(4) = 8).
            let shm = crate::shm::ShmHandle::acquire(
                &posix_name,
                std::mem::size_of::<u32>(),
                crate::shm::ShmOpenMode::CreateOrOpen,
            )?;
            let sem = Self { shm };
            // First opener initialises the count (mirrors C++ `ref() <= 1`).
            if sem.shm.ref_count() <= 1 {
                sem.count().store(count, Ordering::Release);
            }
            Ok(sem)
        }

        pub(super) fn wait(&self, timeout_ms: Option<u64>) -> io::Result<bool> {
            let deadline = timeout_ms.map(|ms| Instant::now() + Duration::from_millis(ms));
            loop {
                // Try to decrement (CAS loop); succeeds while count > 0.
                let mut cur = self.count().load(Ordering::Acquire);
                while cur > 0 {
                    match self.count().compare_exchange_weak(
                        cur,
                        cur - 1,
                        Ordering::Acquire,
                        Ordering::Relaxed,
                    ) {
                        Ok(_) => return Ok(true),
                        Err(c) => cur = c,
                    }
                }
                // count == 0: sleep until it changes (or timeout).
                let timeout_us = match deadline {
                    Some(dl) => {
                        let now = Instant::now();
                        if now >= dl {
                            return Ok(false);
                        }
                        let rem = (dl - now).as_micros();
                        if rem == 0 {
                            return Ok(false);
                        }
                        rem.min(u32::MAX as u128) as u32
                    }
                    None => 0, // infinite
                };
                let ret = unsafe {
                    __ulock_wait(UL_COMPARE_AND_WAIT_SHARED, self.count_ptr(), 0, timeout_us)
                };
                if ret < 0 {
                    let e = io::Error::last_os_error();
                    match e.raw_os_error() {
                        Some(libc::EINTR) => {} // retry
                        Some(libc::ETIMEDOUT) if deadline.is_some() => return Ok(false),
                        _ => {} // spurious / other: re-check the count
                    }
                }
                // Woken or spurious: loop back and retry the CAS.
            }
        }

        pub(super) fn post(&self, count: u32) -> io::Result<()> {
            for _ in 0..count {
                self.count().fetch_add(1, Ordering::Release);
                unsafe { __ulock_wake(UL_COMPARE_AND_WAIT_SHARED, self.count_ptr(), 0) };
            }
            Ok(())
        }

        pub(super) fn clear_storage(name: &str) {
            let posix_name = shm_name::make_shm_name(name);
            crate::shm::ShmHandle::clear_storage(&posix_name);
        }
    }
}

#[cfg(target_os = "macos")]
use apple::AppleSemaphore;

// ---------------------------------------------------------------------------
// POSIX implementation
// ---------------------------------------------------------------------------

#[cfg(all(unix, not(target_os = "macos")))]
struct PosixSemaphore {
    handle: *mut libc::sem_t,
    sem_name: std::ffi::CString,
}

#[cfg(all(unix, not(target_os = "macos")))]
unsafe impl Send for PosixSemaphore {}
#[cfg(all(unix, not(target_os = "macos")))]
unsafe impl Sync for PosixSemaphore {}

#[cfg(all(unix, not(target_os = "macos")))]
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

#[cfg(all(unix, not(target_os = "macos")))]
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
        let qualified = crate::platform::windows::win_object_name(name);
        let wide: Vec<u16> = qualified.encode_utf16().chain(std::iter::once(0)).collect();
        let h =
            unsafe { CreateSemaphoreW(std::ptr::null(), count as i32, i32::MAX, wide.as_ptr()) };
        if h.is_null() {
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
        if !self.handle.is_null() {
            unsafe { CloseHandle(self.handle) };
        }
    }
}
