// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// macOS ulock-based inter-process mutex — binary-compatible with the C++
// `apple/mutex.h` implementation in cpp-ipc.
//
// Shared-memory layout (8 bytes):
//   offset 0: atomic<u32>  state   — 0=UNLOCKED, 1=LOCKED, 2=LOCKED+waiters
//   offset 4: atomic<u32>  holder  — PID of current owner, 0 if unlocked
//
// This mirrors `ulock_mutex_t` in the C++ header exactly so both sides can
// share the same named SHM region and interoperate correctly.

use std::collections::HashMap;
use std::io;
use std::sync::atomic::{AtomicI32, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::shm_name;

// ---------------------------------------------------------------------------
// __ulock_wait / __ulock_wake syscall bindings (private Apple API, stable
// since macOS 10.12 and used extensively by the OS runtime).
// ---------------------------------------------------------------------------

const UL_COMPARE_AND_WAIT_SHARED: u32 = 3;
const ULF_WAKE_ALL: u32 = 0x0000_0100;

extern "C" {
    fn __ulock_wait(operation: u32, addr: *mut u32, value: u64, timeout_us: u32) -> libc::c_int;

    fn __ulock_wake(operation: u32, addr: *mut u32, wake_value: u64) -> libc::c_int;
}

// ---------------------------------------------------------------------------
// Spin budget before sleeping in __ulock_wait (matches C++ kMutexSpinCount).
// ---------------------------------------------------------------------------
const SPIN_COUNT: i32 = 40;

// ---------------------------------------------------------------------------
// Process-local SHM cache — every thread that opens the same named mutex
// shares one mmap, identical to the C++ `curr_prog` pattern.
// ---------------------------------------------------------------------------

struct CachedShm {
    mem: *mut u8,
    size: usize,
    ref_count: AtomicI32,
}

unsafe impl Send for CachedShm {}
unsafe impl Sync for CachedShm {}

impl Drop for CachedShm {
    fn drop(&mut self) {
        if !self.mem.is_null() {
            unsafe { libc::munmap(self.mem as *mut libc::c_void, self.size) };
        }
    }
}

struct ShmCache {
    map: HashMap<String, Arc<CachedShm>>,
}

fn mutex_cache() -> &'static Mutex<ShmCache> {
    static CACHE: OnceLock<Mutex<ShmCache>> = OnceLock::new();
    CACHE.get_or_init(|| {
        Mutex::new(ShmCache {
            map: HashMap::new(),
        })
    })
}

fn acquire_mutex_shm(logical_name: &str) -> io::Result<Arc<CachedShm>> {
    let posix_name = shm_name::make_shm_name(logical_name);
    let size = 8usize; // sizeof(ulock_mutex_t): u32 state + u32 holder

    let mut cache = mutex_cache().lock().unwrap();

    if let Some(entry) = cache.map.get(logical_name) {
        entry.ref_count.fetch_add(1, Ordering::Relaxed);
        return Ok(Arc::clone(entry));
    }

    // Open or create the shared memory segment.
    let c_name = std::ffi::CString::new(posix_name.as_bytes())
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;

    let perms: libc::mode_t = 0o666;

    // Try exclusive create first; fall through to plain open if it exists.
    let (fd, is_new) = {
        let f = unsafe {
            libc::shm_open(
                c_name.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL,
                perms as libc::c_uint,
            )
        };
        if f != -1 {
            (f, true)
        } else {
            let err = io::Error::last_os_error();
            if err.raw_os_error() != Some(libc::EEXIST) {
                return Err(err);
            }
            let f2 =
                unsafe { libc::shm_open(c_name.as_ptr(), libc::O_RDWR, perms as libc::c_uint) };
            if f2 == -1 {
                return Err(io::Error::last_os_error());
            }
            (f2, false)
        }
    };

    unsafe { libc::fchmod(fd, perms) };

    if is_new {
        let ret = unsafe { libc::ftruncate(fd, size as libc::off_t) };
        if ret != 0 {
            let err = io::Error::last_os_error();
            unsafe { libc::close(fd) };
            return Err(err);
        }
    }

    let mem = unsafe {
        libc::mmap(
            std::ptr::null_mut(),
            size,
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

    let mem = mem as *mut u8;

    // First opener: initialise state=0, holder=0.
    if is_new {
        unsafe {
            (mem as *mut AtomicU32).write(AtomicU32::new(0));
            (mem.add(4) as *mut AtomicU32).write(AtomicU32::new(0));
        }
    }

    let entry = Arc::new(CachedShm {
        mem,
        size,
        ref_count: AtomicI32::new(1),
    });
    cache
        .map
        .insert(logical_name.to_owned(), Arc::clone(&entry));
    Ok(entry)
}

fn release_mutex_shm(logical_name: &str) {
    let mut cache = mutex_cache().lock().unwrap();
    if let Some(entry) = cache.map.get(logical_name) {
        let prev = entry.ref_count.fetch_sub(1, Ordering::Relaxed);
        if prev <= 1 {
            cache.map.remove(logical_name);
        }
    }
}

// ---------------------------------------------------------------------------
// Helper accessors into the 8-byte SHM block.
// ---------------------------------------------------------------------------

#[inline]
unsafe fn state_ptr(mem: *mut u8) -> *mut u32 {
    mem as *mut u32
}

#[inline]
unsafe fn holder_ptr(mem: *mut u8) -> *mut u32 {
    mem.add(4) as *mut u32
}

#[inline]
unsafe fn state_atomic(mem: *mut u8) -> &'static AtomicU32 {
    &*(state_ptr(mem) as *const AtomicU32)
}

#[inline]
unsafe fn holder_atomic(mem: *mut u8) -> &'static AtomicU32 {
    &*(holder_ptr(mem) as *const AtomicU32)
}

// ---------------------------------------------------------------------------
// Dead-holder recovery (mirrors C++ try_recover_dead_holder).
// ---------------------------------------------------------------------------

fn is_process_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    let ret = unsafe { libc::kill(pid as libc::pid_t, 0) };
    ret == 0 || unsafe { *libc::__error() } != libc::ESRCH
}

unsafe fn try_recover_dead_holder(mem: *mut u8) -> bool {
    let holder = holder_atomic(mem).load(Ordering::Acquire);
    if holder == 0 {
        return false;
    }
    if is_process_alive(holder) {
        return false;
    }
    // Reset state to UNLOCKED.
    let old = state_atomic(mem).swap(0, Ordering::AcqRel);
    holder_atomic(mem).store(0, Ordering::Release);
    if old == 2 {
        __ulock_wake(UL_COMPARE_AND_WAIT_SHARED | ULF_WAKE_ALL, state_ptr(mem), 0);
    }
    true
}

// ---------------------------------------------------------------------------
// PlatformMutex — public API consumed by IpcMutex.
// ---------------------------------------------------------------------------

pub struct PlatformMutex {
    cached: Arc<CachedShm>,
    name: String,
}

unsafe impl Send for PlatformMutex {}
unsafe impl Sync for PlatformMutex {}

impl PlatformMutex {
    pub fn open(name: &str) -> io::Result<Self> {
        let cached = acquire_mutex_shm(name)?;
        Ok(Self {
            cached,
            name: name.to_owned(),
        })
    }

    fn mem(&self) -> *mut u8 {
        self.cached.mem
    }

    pub fn lock(&self) -> io::Result<()> {
        // Infinite-wait variant — loop until acquired.
        unsafe {
            let mem = self.mem();
            let mut contended = false;
            loop {
                // Optimistic spin phase.
                for _ in 0..SPIN_COUNT {
                    let expected_val = if contended { 0u32 } else { 0u32 };
                    let new_val = if contended { 2u32 } else { 1u32 };
                    let result = state_atomic(mem).compare_exchange(
                        expected_val,
                        new_val,
                        Ordering::Acquire,
                        Ordering::Relaxed,
                    );
                    if result.is_ok() {
                        holder_atomic(mem).store(std::process::id(), Ordering::Release);
                        return Ok(());
                    }
                    #[cfg(target_arch = "aarch64")]
                    std::arch::asm!("isb sy", options(nostack, nomem));
                    #[cfg(not(target_arch = "aarch64"))]
                    std::hint::spin_loop();
                }

                // Transition to "locked with waiters".
                let mut s = state_atomic(mem).load(Ordering::Relaxed);
                if s == 0 {
                    continue; // unlocked between spin and here — retry
                }
                if s == 1 {
                    match state_atomic(mem).compare_exchange(
                        1,
                        2,
                        Ordering::Relaxed,
                        Ordering::Relaxed,
                    ) {
                        Err(_) => continue,
                        Ok(_) => {}
                    }
                }
                s = 2;

                // Sleep until state != 2.
                __ulock_wait(UL_COMPARE_AND_WAIT_SHARED, state_ptr(mem), s as u64, 0);
                contended = true;
            }
        }
    }

    pub fn lock_timeout(&self, timeout_ms: u64) -> io::Result<bool> {
        unsafe {
            let mem = self.mem();
            let deadline = Instant::now() + Duration::from_millis(timeout_ms);
            let mut tried_recovery = false;
            let mut contended = false;

            loop {
                // Optimistic spin phase.
                for _ in 0..SPIN_COUNT {
                    let expected_val = 0u32;
                    let new_val = if contended { 2u32 } else { 1u32 };
                    let result = state_atomic(mem).compare_exchange(
                        expected_val,
                        new_val,
                        Ordering::Acquire,
                        Ordering::Relaxed,
                    );
                    if result.is_ok() {
                        holder_atomic(mem).store(std::process::id(), Ordering::Release);
                        return Ok(true);
                    }
                    #[cfg(target_arch = "aarch64")]
                    std::arch::asm!("isb sy", options(nostack, nomem));
                    #[cfg(not(target_arch = "aarch64"))]
                    std::hint::spin_loop();
                }

                // Transition to "locked with waiters".
                let mut s = state_atomic(mem).load(Ordering::Relaxed);
                if s == 0 {
                    continue;
                }
                if s == 1 {
                    match state_atomic(mem).compare_exchange(
                        1,
                        2,
                        Ordering::Relaxed,
                        Ordering::Relaxed,
                    ) {
                        Err(_) => continue,
                        Ok(_) => {}
                    }
                }
                s = 2;

                // Check deadline before sleeping.
                let now = Instant::now();
                if now >= deadline {
                    if !tried_recovery {
                        tried_recovery = true;
                        if try_recover_dead_holder(mem) {
                            continue;
                        }
                    }
                    return Ok(false);
                }
                let remaining_us = {
                    let rem = deadline - now;
                    let us = rem.as_micros();
                    if us > u32::MAX as u128 {
                        u32::MAX
                    } else {
                        us as u32
                    }
                };

                let ret = __ulock_wait(
                    UL_COMPARE_AND_WAIT_SHARED,
                    state_ptr(mem),
                    s as u64,
                    remaining_us,
                );
                contended = true;

                if ret < 0 {
                    let err = *libc::__error();
                    if err == libc::ETIMEDOUT {
                        if !tried_recovery {
                            tried_recovery = true;
                            if try_recover_dead_holder(mem) {
                                continue;
                            }
                        }
                        return Ok(false);
                    }
                    // EINTR → spurious wakeup, retry
                }
            }
        }
    }

    pub fn try_lock(&self) -> io::Result<bool> {
        unsafe {
            let mem = self.mem();
            let result =
                state_atomic(mem).compare_exchange(0, 1, Ordering::Acquire, Ordering::Relaxed);
            if result.is_ok() {
                holder_atomic(mem).store(std::process::id(), Ordering::Release);
                return Ok(true);
            }
            // Try dead-holder recovery once.
            if try_recover_dead_holder(mem) {
                let result2 =
                    state_atomic(mem).compare_exchange(0, 1, Ordering::Acquire, Ordering::Relaxed);
                if result2.is_ok() {
                    holder_atomic(mem).store(std::process::id(), Ordering::Release);
                    return Ok(true);
                }
            }
            Ok(false)
        }
    }

    pub fn unlock(&self) -> io::Result<()> {
        unsafe {
            let mem = self.mem();
            holder_atomic(mem).store(0, Ordering::Release);
            let prev = state_atomic(mem).swap(0, Ordering::Release);
            if prev == 2 {
                __ulock_wake(UL_COMPARE_AND_WAIT_SHARED, state_ptr(mem), 0);
            }
        }
        Ok(())
    }

    pub fn clear_storage(name: &str) {
        release_mutex_shm(name);
        let posix_name = shm_name::make_shm_name(name);
        if let Ok(c_name) = std::ffi::CString::new(posix_name.as_bytes()) {
            unsafe { libc::shm_unlink(c_name.as_ptr()) };
        }
    }

    #[allow(dead_code)]
    pub(crate) fn native_ptr(&self) -> *mut u8 {
        self.cached.mem
    }
}

impl Drop for PlatformMutex {
    fn drop(&mut self) {
        release_mutex_shm(&self.name);
    }
}
