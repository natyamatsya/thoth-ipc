// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// POSIX implementation of shared memory and named mutex primitives.
// Binary-compatible with cpp-ipc/src/libipc/platform/posix/shm_posix.cpp
// and cpp-ipc/src/libipc/platform/posix/mutex.h.

use std::ffi::CString;
use std::io;
use std::ptr;
use std::sync::atomic::{AtomicI32, Ordering};

use crate::shm_name;

// ---------------------------------------------------------------------------
// Robust mutex symbols — not exposed by `libc` crate on all platforms.
// On macOS robust mutexes are not used (matching the C++ implementation).
// ---------------------------------------------------------------------------

#[cfg(not(target_os = "macos"))]
const EOWNERDEAD: i32 = libc::EOWNERDEAD;

#[cfg(not(target_os = "macos"))]
extern "C" {
    fn pthread_mutexattr_setrobust(
        attr: *mut libc::pthread_mutexattr_t,
        robustness: libc::c_int,
    ) -> libc::c_int;
    fn pthread_mutex_consistent(mutex: *mut libc::pthread_mutex_t) -> libc::c_int;
}

#[cfg(not(target_os = "macos"))]
const PTHREAD_MUTEX_ROBUST: libc::c_int = 1;

// ---------------------------------------------------------------------------
// Layout helpers — must match C++ calc_size() and acc_of()
// ---------------------------------------------------------------------------

/// Mirrors C++ `calc_size()`: rounds up to `alignof(info_t)` then appends
/// an `atomic<int32_t>` reference counter at the end.
/// `alignof(info_t)` == `alignof(atomic<int32_t>)` == 4.
const ALIGN: usize = std::mem::align_of::<AtomicI32>();

pub(crate) fn calc_size(user_size: usize) -> usize {
    let aligned = ((user_size.wrapping_sub(1) / ALIGN) + 1) * ALIGN;
    aligned + std::mem::size_of::<AtomicI32>()
}

/// Returns a reference to the trailing `AtomicI32` ref-counter inside a mapped
/// region of `total_size` bytes starting at `mem`.
///
/// # Safety
/// `mem` must point to a valid mapped region of at least `total_size` bytes.
unsafe fn acc_of(mem: *mut u8, total_size: usize) -> &'static AtomicI32 {
    let offset = total_size - std::mem::size_of::<AtomicI32>();
    &*(mem.add(offset) as *const AtomicI32)
}

// ---------------------------------------------------------------------------
// PlatformShm — POSIX shared memory
// ---------------------------------------------------------------------------

pub struct PlatformShm {
    mem: *mut u8,
    size: usize,      // total mapped size (including ref counter)
    user_size: usize, // user-requested size
    name: String,     // POSIX name (with leading '/')
}

// Safety: the shared memory region is process-shared by design.
unsafe impl Send for PlatformShm {}
unsafe impl Sync for PlatformShm {}

/// Open mode flags — mirrors C++ `ipc::shm::create` / `ipc::shm::open`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShmMode {
    Create,
    Open,
    CreateOrOpen,
}

impl PlatformShm {
    /// Acquire a named shared memory region, binary-compatible with C++ `ipc::shm::acquire`
    /// + `ipc::shm::get_mem`.
    pub fn acquire(name: &str, user_size: usize, mode: ShmMode) -> io::Result<Self> {
        if name.is_empty() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "name is empty"));
        }
        if user_size == 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "size is 0"));
        }

        let posix_name = shm_name::make_shm_name(name);
        let c_name = CString::new(posix_name.as_bytes())
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;

        let mut flags = libc::O_RDWR;
        let mut need_truncate = true;
        match mode {
            ShmMode::Open => {
                need_truncate = false;
            }
            ShmMode::Create => {
                flags |= libc::O_CREAT | libc::O_EXCL;
            }
            ShmMode::CreateOrOpen => {
                flags |= libc::O_CREAT;
            }
        }

        let perms: libc::mode_t = 0o666; // S_IRUSR|S_IWUSR|S_IRGRP|S_IWGRP|S_IROTH|S_IWOTH

        let fd = unsafe { libc::shm_open(c_name.as_ptr(), flags, perms as libc::c_uint) };
        if fd == -1 {
            return Err(io::Error::last_os_error());
        }

        // Ensure permissions (mirrors fchmod in C++)
        unsafe { libc::fchmod(fd, perms) };

        let total_size;
        if need_truncate {
            total_size = calc_size(user_size);
            let ret = unsafe { libc::ftruncate(fd, total_size as libc::off_t) };
            if ret != 0 {
                let err = io::Error::last_os_error();
                // macOS workaround: EINVAL on already-sized shm object
                #[cfg(target_os = "macos")]
                if err.raw_os_error() == Some(libc::EINVAL) {
                    // Check if existing size is compatible
                    let mut st: libc::stat = unsafe { std::mem::zeroed() };
                    if unsafe { libc::fstat(fd, &mut st) } == 0
                        && (st.st_size as usize) >= total_size
                    {
                        // Existing object already has correct size — continue
                    } else {
                        // Stale object — unlink, recreate, retry
                        unsafe { libc::close(fd) };
                        unsafe { libc::shm_unlink(c_name.as_ptr()) };
                        let fd2 = unsafe {
                            libc::shm_open(
                                c_name.as_ptr(),
                                libc::O_RDWR | libc::O_CREAT,
                                perms as libc::c_uint,
                            )
                        };
                        if fd2 == -1 {
                            return Err(io::Error::last_os_error());
                        }
                        if unsafe { libc::ftruncate(fd2, total_size as libc::off_t) } != 0 {
                            let e = io::Error::last_os_error();
                            unsafe { libc::close(fd2) };
                            return Err(e);
                        }
                        return Self::mmap_and_finish(fd2, total_size, user_size, posix_name);
                    }
                }

                #[cfg(not(target_os = "macos"))]
                {
                    unsafe { libc::close(fd) };
                    return Err(err);
                }
            }
        } else {
            // Open-only mode: discover size from fstat
            // On macOS we keep user_size if provided (fstat returns page-rounded sizes)
            #[cfg(target_os = "macos")]
            {
                total_size = calc_size(user_size);
            }
            #[cfg(not(target_os = "macos"))]
            {
                let mut st: libc::stat = unsafe { std::mem::zeroed() };
                if unsafe { libc::fstat(fd, &mut st) } != 0 {
                    let e = io::Error::last_os_error();
                    unsafe { libc::close(fd) };
                    return Err(e);
                }
                total_size = st.st_size as usize;
                if total_size <= std::mem::size_of::<AtomicI32>()
                    || total_size % std::mem::size_of::<AtomicI32>() != 0
                {
                    unsafe { libc::close(fd) };
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("invalid shm size: {total_size}"),
                    ));
                }
            }
        }

        Self::mmap_and_finish(fd, total_size, user_size, posix_name)
    }

    fn mmap_and_finish(
        fd: i32,
        total_size: usize,
        user_size: usize,
        posix_name: String,
    ) -> io::Result<Self> {
        let mem = unsafe {
            libc::mmap(
                ptr::null_mut(),
                total_size,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                fd,
                0,
            )
        };
        unsafe { libc::close(fd) };

        if mem == libc::MAP_FAILED {
            return Err(io::Error::last_os_error());
        }

        // Increment the reference counter (mirrors C++ get_mem)
        unsafe { acc_of(mem as *mut u8, total_size).fetch_add(1, Ordering::Release) };

        Ok(Self {
            mem: mem as *mut u8,
            size: total_size,
            user_size,
            name: posix_name,
        })
    }

    /// Pointer to the user-visible region (excluding the trailing ref counter).
    pub fn as_ptr(&self) -> *const u8 {
        self.mem
    }

    /// Mutable pointer to the user-visible region.
    pub fn as_mut_ptr(&self) -> *mut u8 {
        self.mem
    }

    /// Total mapped size (including ref counter).
    pub fn mapped_size(&self) -> usize {
        self.size
    }

    /// User-requested size.
    pub fn user_size(&self) -> usize {
        self.user_size
    }

    /// POSIX name (with leading '/').
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Current reference count.
    pub fn ref_count(&self) -> i32 {
        if self.mem.is_null() || self.size == 0 {
            return 0;
        }
        unsafe { acc_of(self.mem, self.size).load(Ordering::Acquire) }
    }

    /// Force-remove the backing file (shm_unlink). Does NOT release the mapping.
    pub fn unlink(&self) {
        if let Ok(c_name) = CString::new(self.name.as_bytes()) {
            unsafe { libc::shm_unlink(c_name.as_ptr()) };
        }
    }

    /// Unlink a named shm segment by name (static helper).
    pub fn unlink_by_name(name: &str) {
        let posix_name = shm_name::make_shm_name(name);
        if let Ok(c_name) = CString::new(posix_name.as_bytes()) {
            unsafe { libc::shm_unlink(c_name.as_ptr()) };
        }
    }
}

impl Drop for PlatformShm {
    fn drop(&mut self) {
        if self.mem.is_null() {
            return;
        }
        // Decrement ref counter; if we're the last, also unlink.
        let prev = unsafe { acc_of(self.mem, self.size).fetch_sub(1, Ordering::AcqRel) };
        unsafe { libc::munmap(self.mem as *mut libc::c_void, self.size) };
        if prev <= 1 {
            self.unlink();
        }
    }
}

// ---------------------------------------------------------------------------
// PlatformMutex — POSIX inter-process mutex (pthread_mutex_t in shared memory)
// ---------------------------------------------------------------------------

pub struct PlatformMutex {
    shm: PlatformShm,
}

impl PlatformMutex {
    /// Open (or create) a named inter-process mutex.
    ///
    /// The mutex lives inside a shared memory segment named after the mutex.
    /// On first creation it is initialised with `PTHREAD_PROCESS_SHARED` and
    /// `PTHREAD_MUTEX_ROBUST` attributes — identical to the C++ implementation.
    pub fn open(name: &str) -> io::Result<Self> {
        let shm_size = std::mem::size_of::<libc::pthread_mutex_t>();
        let shm = PlatformShm::acquire(name, shm_size, ShmMode::CreateOrOpen)?;
        let is_creator = shm.ref_count() <= 1;

        if is_creator {
            let mtx_ptr = shm.as_mut_ptr() as *mut libc::pthread_mutex_t;

            unsafe {
                // Zero-initialize (matches C++ `*mutex_ = PTHREAD_MUTEX_INITIALIZER`)
                ptr::write_bytes(mtx_ptr, 0, 1);

                let mut attr: libc::pthread_mutexattr_t = std::mem::zeroed();
                let mut eno = libc::pthread_mutexattr_init(&mut attr);
                if eno != 0 {
                    return Err(io::Error::from_raw_os_error(eno));
                }

                eno = libc::pthread_mutexattr_setpshared(&mut attr, libc::PTHREAD_PROCESS_SHARED);
                if eno != 0 {
                    libc::pthread_mutexattr_destroy(&mut attr);
                    return Err(io::Error::from_raw_os_error(eno));
                }

                #[cfg(not(target_os = "macos"))]
                {
                    eno = pthread_mutexattr_setrobust(&mut attr, PTHREAD_MUTEX_ROBUST);
                    if eno != 0 {
                        libc::pthread_mutexattr_destroy(&mut attr);
                        return Err(io::Error::from_raw_os_error(eno));
                    }
                }

                eno = libc::pthread_mutex_init(mtx_ptr, &attr);
                libc::pthread_mutexattr_destroy(&mut attr);
                if eno != 0 {
                    return Err(io::Error::from_raw_os_error(eno));
                }
            }
        }

        Ok(Self { shm })
    }

    fn mtx_ptr(&self) -> *mut libc::pthread_mutex_t {
        self.shm.as_mut_ptr() as *mut libc::pthread_mutex_t
    }

    /// Lock the mutex (blocking). Returns `Ok(())` on success.
    /// Handles `EOWNERDEAD` from robust mutexes by calling `pthread_mutex_consistent`.
    pub fn lock(&self) -> io::Result<()> {
        loop {
            let eno = unsafe { libc::pthread_mutex_lock(self.mtx_ptr()) };
            match eno {
                0 => return Ok(()),
                #[cfg(not(target_os = "macos"))]
                EOWNERDEAD => {
                    let eno2 = unsafe { pthread_mutex_consistent(self.mtx_ptr()) };
                    if eno2 != 0 {
                        return Err(io::Error::from_raw_os_error(eno2));
                    }
                    return Ok(());
                }
                _ => return Err(io::Error::from_raw_os_error(eno)),
            }
        }
    }

    /// Try to lock the mutex without blocking.
    /// Returns `Ok(true)` if acquired, `Ok(false)` if contended.
    pub fn try_lock(&self) -> io::Result<bool> {
        let eno = unsafe { libc::pthread_mutex_trylock(self.mtx_ptr()) };
        match eno {
            0 => Ok(true),
            libc::EBUSY => Ok(false),
            #[cfg(not(target_os = "macos"))]
            EOWNERDEAD => {
                let eno2 = unsafe { pthread_mutex_consistent(self.mtx_ptr()) };
                if eno2 != 0 {
                    return Err(io::Error::from_raw_os_error(eno2));
                }
                Ok(true)
            }
            _ => Err(io::Error::from_raw_os_error(eno)),
        }
    }

    /// Unlock the mutex. Returns `Ok(())` on success.
    pub fn unlock(&self) -> io::Result<()> {
        let eno = unsafe { libc::pthread_mutex_unlock(self.mtx_ptr()) };
        if eno != 0 {
            return Err(io::Error::from_raw_os_error(eno));
        }
        Ok(())
    }

    /// Remove the shared memory backing this mutex (static helper).
    pub fn clear_storage(name: &str) {
        PlatformShm::unlink_by_name(name);
    }
}

impl Drop for PlatformMutex {
    fn drop(&mut self) {
        // If we're the last reference, destroy the mutex before the shm is unmapped.
        if self.shm.ref_count() <= 1 {
            unsafe {
                libc::pthread_mutex_unlock(self.mtx_ptr());
                libc::pthread_mutex_destroy(self.mtx_ptr());
            }
        }
        // PlatformShm::drop handles munmap + potential shm_unlink.
    }
}
