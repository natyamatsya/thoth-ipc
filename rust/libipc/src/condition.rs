// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Cross-platform named inter-process condition variable.
// POSIX: pthread_cond_t in shared memory with PTHREAD_PROCESS_SHARED.
// Windows: emulated via semaphore + mutex + shared counter (matches C++ impl).

use std::io;

use crate::IpcMutex;

/// A named, inter-process condition variable.
///
/// On POSIX (macOS, Linux, FreeBSD) this is a `pthread_cond_t` stored in
/// shared memory with `PTHREAD_PROCESS_SHARED` attribute.
/// On Windows this is emulated using a semaphore, a lock, and a shared counter.
pub struct IpcCondition {
    #[cfg(unix)]
    inner: PosixCondition,
    #[cfg(windows)]
    inner: WindowsCondition,
}

impl IpcCondition {
    /// Open (or create) a named condition variable.
    pub fn open(name: &str) -> io::Result<Self> {
        #[cfg(unix)]
        let inner = PosixCondition::open(name)?;
        #[cfg(windows)]
        let inner = WindowsCondition::open(name)?;
        Ok(Self { inner })
    }

    /// Wait on the condition variable. The caller must hold `mtx` locked.
    /// The mutex is atomically released and re-acquired around the wait.
    /// If `timeout_ms` is `None`, blocks indefinitely.
    /// Returns `Ok(true)` if signalled, `Ok(false)` on timeout.
    pub fn wait(&self, mtx: &IpcMutex, timeout_ms: Option<u64>) -> io::Result<bool> {
        self.inner.wait(mtx, timeout_ms)
    }

    /// Wake one waiter.
    pub fn notify(&self) -> io::Result<()> {
        self.inner.notify()
    }

    /// Wake all waiters.
    pub fn broadcast(&self) -> io::Result<()> {
        self.inner.broadcast()
    }

    /// Remove the backing storage for a named condition variable.
    pub fn clear_storage(name: &str) {
        #[cfg(unix)]
        PosixCondition::clear_storage(name);
        #[cfg(windows)]
        {
            let _ = name;
        }
    }
}

// ---------------------------------------------------------------------------
// POSIX implementation — pthread_cond_t in shared memory
// ---------------------------------------------------------------------------

#[cfg(unix)]
use std::sync::Arc;

#[cfg(unix)]
use crate::platform::posix::{self, CachedShm};

#[cfg(unix)]
struct PosixCondition {
    cached: Arc<CachedShm>,
    name: String,
}

#[cfg(unix)]
impl PosixCondition {
    fn open(name: &str) -> io::Result<Self> {
        let shm_size = std::mem::size_of::<libc::pthread_cond_t>();
        let cached = posix::cached_shm_acquire(posix::cond_cache(), name, shm_size, |base| {
            let cond_ptr = base as *mut libc::pthread_cond_t;
            unsafe {
                std::ptr::write_bytes(cond_ptr, 0, 1);

                let mut attr: libc::pthread_condattr_t = std::mem::zeroed();
                let mut eno = libc::pthread_condattr_init(&mut attr);
                if eno != 0 {
                    return Err(io::Error::from_raw_os_error(eno));
                }

                eno = libc::pthread_condattr_setpshared(&mut attr, libc::PTHREAD_PROCESS_SHARED);
                if eno != 0 {
                    libc::pthread_condattr_destroy(&mut attr);
                    return Err(io::Error::from_raw_os_error(eno));
                }

                eno = libc::pthread_cond_init(cond_ptr, &attr);
                libc::pthread_condattr_destroy(&mut attr);
                if eno != 0 {
                    return Err(io::Error::from_raw_os_error(eno));
                }
            }
            Ok(())
        })?;

        Ok(Self {
            cached,
            name: name.to_string(),
        })
    }

    fn cond_ptr(&self) -> *mut libc::pthread_cond_t {
        self.cached.shm.as_mut_ptr() as *mut libc::pthread_cond_t
    }

    fn wait(&self, mtx: &IpcMutex, timeout_ms: Option<u64>) -> io::Result<bool> {
        // The IpcMutex wraps a PlatformMutex which wraps a PlatformShm whose
        // first bytes are the pthread_mutex_t. We need the raw pthread_mutex_t*.
        // Access it through the inner field chain.
        let mtx_ptr = mtx.native_mutex_ptr() as *mut libc::pthread_mutex_t;

        match timeout_ms {
            None => {
                let eno = unsafe { libc::pthread_cond_wait(self.cond_ptr(), mtx_ptr) };
                if eno != 0 {
                    return Err(io::Error::from_raw_os_error(eno));
                }
                Ok(true)
            }
            Some(ms) => {
                use std::time::{SystemTime, UNIX_EPOCH};
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default();
                let deadline = now + std::time::Duration::from_millis(ms);
                let ts = libc::timespec {
                    tv_sec: deadline.as_secs() as libc::time_t,
                    tv_nsec: deadline.subsec_nanos() as libc::c_long,
                };
                let eno = unsafe { libc::pthread_cond_timedwait(self.cond_ptr(), mtx_ptr, &ts) };
                if eno == 0 {
                    return Ok(true);
                }
                if eno == libc::ETIMEDOUT {
                    return Ok(false);
                }
                Err(io::Error::from_raw_os_error(eno))
            }
        }
    }

    fn notify(&self) -> io::Result<()> {
        let eno = unsafe { libc::pthread_cond_signal(self.cond_ptr()) };
        if eno != 0 {
            return Err(io::Error::from_raw_os_error(eno));
        }
        Ok(())
    }

    fn broadcast(&self) -> io::Result<()> {
        let eno = unsafe { libc::pthread_cond_broadcast(self.cond_ptr()) };
        if eno != 0 {
            return Err(io::Error::from_raw_os_error(eno));
        }
        Ok(())
    }

    fn clear_storage(name: &str) {
        posix::cached_shm_purge(posix::cond_cache(), name);
        posix::PlatformShm::unlink_by_name(name);
    }
}

#[cfg(unix)]
impl Drop for PosixCondition {
    fn drop(&mut self) {
        // Don't call pthread_cond_destroy here. On macOS, the virtual
        // address may be recycled to a different shm segment after munmap,
        // and destroy would zero the __sig field of whatever condition now
        // lives at that address. The shm munmap + unlink in
        // PlatformShm::Drop is sufficient to reclaim the memory.
        posix::cached_shm_release(posix::cond_cache(), &self.name);
    }
}

// ---------------------------------------------------------------------------
// Windows implementation — semaphore + mutex + shared counter
// ---------------------------------------------------------------------------

#[cfg(windows)]
struct WindowsCondition {
    sem: crate::IpcSemaphore,
    lock: IpcMutex,
    // For simplicity, use an atomic counter in local memory.
    // In the full C++ impl this is in shared memory for cross-process,
    // but for initial port we keep it in-process.
    counter: std::sync::atomic::AtomicI32,
}

#[cfg(windows)]
impl WindowsCondition {
    fn open(name: &str) -> io::Result<Self> {
        let sem = crate::IpcSemaphore::open(&format!("{name}_COND_SEM_"), 0)?;
        let lock = IpcMutex::open(&format!("{name}_COND_LOCK_"))?;
        Ok(Self {
            sem,
            lock,
            counter: std::sync::atomic::AtomicI32::new(0),
        })
    }

    fn wait(&self, mtx: &IpcMutex, timeout_ms: Option<u64>) -> io::Result<bool> {
        {
            self.lock.lock()?;
            let c = self.counter.load(std::sync::atomic::Ordering::Relaxed);
            self.counter.store(
                if c < 0 { 1 } else { c + 1 },
                std::sync::atomic::Ordering::Relaxed,
            );
            self.lock.unlock()?;
        }
        mtx.unlock()?;
        let result = self.sem.wait(timeout_ms)?;
        mtx.lock()?;
        if !result {
            self.lock.lock()?;
            self.counter
                .fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
            self.lock.unlock()?;
        }
        Ok(result)
    }

    fn notify(&self) -> io::Result<()> {
        self.lock.lock()?;
        let c = self.counter.load(std::sync::atomic::Ordering::Relaxed);
        if c > 0 {
            self.sem.post(1)?;
            self.counter
                .fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
        }
        self.lock.unlock()?;
        Ok(())
    }

    fn broadcast(&self) -> io::Result<()> {
        self.lock.lock()?;
        let c = self.counter.load(std::sync::atomic::Ordering::Relaxed);
        if c > 0 {
            self.sem.post(c as u32)?;
            self.counter.store(0, std::sync::atomic::Ordering::Relaxed);
        }
        self.lock.unlock()?;
        Ok(())
    }
}
