// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// POSIX implementation of shared memory and named mutex primitives.
// Binary-compatible with cpp-ipc/src/libipc/platform/posix/shm_posix.cpp
// and cpp-ipc/src/libipc/platform/posix/mutex.h.

use std::collections::HashMap;
use std::ffi::CString;
use std::io;
use std::ptr;
use std::sync::atomic::{AtomicI32, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use crate::shm_name;

// ---------------------------------------------------------------------------
// Process-local shm cache — mirrors C++ `curr_prog` in posix/mutex.h.
// All threads within the same process that open the same named mutex or
// condition variable MUST use the same mmap.  macOS's pthread implementation
// stores internal pointers relative to the virtual address used for
// pthread_mutex_init, so a second mmap of the same physical page at a
// different address causes EINVAL on pthread_mutex_lock.
// ---------------------------------------------------------------------------

pub(crate) struct CachedShm {
    pub(crate) shm: PlatformShm,
    pub(crate) local_ref: AtomicUsize,
}

pub(crate) struct ShmCache {
    map: HashMap<String, Arc<CachedShm>>,
}

impl ShmCache {
    fn new() -> Self {
        Self {
            map: HashMap::new(),
        }
    }
}

fn mutex_cache() -> &'static Mutex<ShmCache> {
    static CACHE: OnceLock<Mutex<ShmCache>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(ShmCache::new()))
}

pub(crate) fn cond_cache() -> &'static Mutex<ShmCache> {
    static CACHE: OnceLock<Mutex<ShmCache>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(ShmCache::new()))
}

/// Acquire or reuse a cached shm handle.
///
/// If this is the first local open for `name`, `init_fn` is called with the
/// shm pointer **while the cache lock is still held**, ensuring that no other
/// thread can use the handle before initialisation completes.
pub(crate) fn cached_shm_acquire<F>(
    cache: &Mutex<ShmCache>,
    name: &str,
    size: usize,
    init_fn: F,
) -> io::Result<Arc<CachedShm>>
where
    F: FnOnce(*mut u8) -> io::Result<()>,
{
    let mut c = cache.lock().unwrap();
    if let Some(entry) = c.map.get(name) {
        entry.local_ref.fetch_add(1, Ordering::Relaxed);
        return Ok(Arc::clone(entry));
    }
    let shm = PlatformShm::acquire(name, size, ShmMode::CreateOrOpen)?;
    let is_creator = shm.prev_ref_count() == 0;
    if is_creator {
        init_fn(shm.as_mut_ptr())?;
    }
    let entry = Arc::new(CachedShm {
        shm,
        local_ref: AtomicUsize::new(1),
    });
    c.map.insert(name.to_string(), Arc::clone(&entry));
    Ok(entry)
}

/// Release one local reference.  When the last local ref drops, remove from cache.
pub(crate) fn cached_shm_release(cache: &Mutex<ShmCache>, name: &str) {
    let mut c = cache.lock().unwrap();
    if let Some(entry) = c.map.get(name) {
        let prev = entry.local_ref.fetch_sub(1, Ordering::AcqRel);
        if prev <= 1 {
            c.map.remove(name);
        }
    }
}

/// Forcibly remove a cache entry (used by `clear_storage` to avoid stale
/// entries after the underlying shm has been unlinked).
pub(crate) fn cached_shm_purge(cache: &Mutex<ShmCache>, name: &str) {
    let mut c = cache.lock().unwrap();
    c.map.remove(name);
}

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
    prev_ref: i32,    // ref count *before* our fetch_add (0 means we were first)
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

        let perms: libc::mode_t = 0o666; // S_IRUSR|S_IWUSR|S_IRGRP|S_IWGRP|S_IROTH|S_IWOTH
        let total_size = calc_size(user_size);

        // For CreateOrOpen: try exclusive create first so we only call ftruncate
        // when we actually own the new object.  On macOS, calling ftruncate on an
        // already-sized shm object can zero its contents before returning EINVAL.
        let (fd, need_truncate) = match mode {
            ShmMode::Create => {
                let f = unsafe {
                    libc::shm_open(
                        c_name.as_ptr(),
                        libc::O_RDWR | libc::O_CREAT | libc::O_EXCL,
                        perms as libc::c_uint,
                    )
                };
                if f == -1 {
                    return Err(io::Error::last_os_error());
                }
                (f, true)
            }
            ShmMode::Open => {
                let f =
                    unsafe { libc::shm_open(c_name.as_ptr(), libc::O_RDWR, perms as libc::c_uint) };
                if f == -1 {
                    return Err(io::Error::last_os_error());
                }
                (f, false)
            }
            ShmMode::CreateOrOpen => {
                // Try exclusive create first.
                let f = unsafe {
                    libc::shm_open(
                        c_name.as_ptr(),
                        libc::O_RDWR | libc::O_CREAT | libc::O_EXCL,
                        perms as libc::c_uint,
                    )
                };
                if f != -1 {
                    // We created it — must truncate to set the size.
                    (f, true)
                } else {
                    let e = io::Error::last_os_error();
                    if e.raw_os_error() != Some(libc::EEXIST) {
                        return Err(e);
                    }
                    // Already exists — open without truncation.
                    let f2 = unsafe {
                        libc::shm_open(c_name.as_ptr(), libc::O_RDWR, perms as libc::c_uint)
                    };
                    if f2 == -1 {
                        return Err(io::Error::last_os_error());
                    }
                    (f2, false)
                }
            }
        };

        // Ensure permissions (mirrors fchmod in C++)
        unsafe { libc::fchmod(fd, perms) };

        if need_truncate {
            let ret = unsafe { libc::ftruncate(fd, total_size as libc::off_t) };
            if ret != 0 {
                let err = io::Error::last_os_error();
                unsafe { libc::close(fd) };
                return Err(err);
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
        let prev = unsafe { acc_of(mem as *mut u8, total_size).fetch_add(1, Ordering::AcqRel) };

        Ok(Self {
            mem: mem as *mut u8,
            size: total_size,
            user_size,
            name: posix_name,
            prev_ref: prev,
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

    /// The ref count value *before* our own increment during acquire.
    /// Returns 0 if this handle was the first to map the segment.
    pub fn prev_ref_count(&self) -> i32 {
        self.prev_ref
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
    cached: Arc<CachedShm>,
    name: String,
}

impl PlatformMutex {
    /// Open (or create) a named inter-process mutex.
    ///
    /// The mutex lives inside a shared memory segment named after the mutex.
    /// On first creation it is initialised with `PTHREAD_PROCESS_SHARED` and
    /// `PTHREAD_MUTEX_ROBUST` attributes — identical to the C++ implementation.
    ///
    /// All threads within the same process that open the same name share a
    /// single mmap (via `mutex_cache`), matching the C++ `curr_prog` pattern.
    pub fn open(name: &str) -> io::Result<Self> {
        let shm_size = std::mem::size_of::<libc::pthread_mutex_t>();
        let cached = cached_shm_acquire(mutex_cache(), name, shm_size, |base| {
            let mtx_ptr = base as *mut libc::pthread_mutex_t;
            unsafe {
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
            Ok(())
        })?;

        Ok(Self {
            cached,
            name: name.to_string(),
        })
    }

    fn mtx_ptr(&self) -> *mut libc::pthread_mutex_t {
        self.cached.shm.as_mut_ptr() as *mut libc::pthread_mutex_t
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

    /// Lock the mutex with a timeout in milliseconds.
    /// Returns `Ok(true)` if acquired, `Ok(false)` on timeout.
    pub fn lock_timeout(&self, timeout_ms: u64) -> io::Result<bool> {
        #[cfg(target_os = "macos")]
        {
            // macOS lacks pthread_mutex_timedlock — emulate via try_lock polling.
            let deadline = std::time::Instant::now() + std::time::Duration::from_millis(timeout_ms);
            let mut k = 0u32;
            loop {
                let eno = unsafe { libc::pthread_mutex_trylock(self.mtx_ptr()) };
                match eno {
                    0 => return Ok(true),
                    libc::EBUSY => {}
                    _ => return Err(io::Error::from_raw_os_error(eno)),
                }
                if std::time::Instant::now() >= deadline {
                    return Ok(false);
                }
                crate::spin_lock::adaptive_yield_pub(&mut k);
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            extern "C" {
                fn pthread_mutex_timedlock(
                    mutex: *mut libc::pthread_mutex_t,
                    abstime: *const libc::timespec,
                ) -> libc::c_int;
            }
            let mut ts: libc::timespec = unsafe { std::mem::zeroed() };
            unsafe { libc::clock_gettime(libc::CLOCK_REALTIME, &mut ts) };
            let ns_total = ts.tv_nsec as u64 + (timeout_ms % 1000) * 1_000_000;
            ts.tv_sec +=
                (timeout_ms / 1000) as libc::time_t + (ns_total / 1_000_000_000) as libc::time_t;
            ts.tv_nsec = (ns_total % 1_000_000_000) as libc::c_long;
            loop {
                let eno = unsafe { pthread_mutex_timedlock(self.mtx_ptr(), &ts) };
                match eno {
                    0 => return Ok(true),
                    libc::ETIMEDOUT => return Ok(false),
                    EOWNERDEAD => {
                        let eno2 = unsafe { pthread_mutex_consistent(self.mtx_ptr()) };
                        if eno2 != 0 {
                            return Err(io::Error::from_raw_os_error(eno2));
                        }
                        return Ok(true);
                    }
                    libc::EINTR => continue,
                    _ => return Err(io::Error::from_raw_os_error(eno)),
                }
            }
        }
    }

    /// Try to lock the mutex without blocking.
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

    /// Raw pointer to the underlying `pthread_mutex_t`.
    pub(crate) fn native_ptr(&self) -> *mut u8 {
        self.cached.shm.as_mut_ptr()
    }

    /// Remove the shared memory backing this mutex (static helper).
    /// Also purges any cached entry so a subsequent `open` creates fresh state.
    pub fn clear_storage(name: &str) {
        cached_shm_purge(mutex_cache(), name);
        PlatformShm::unlink_by_name(name);
    }
}

impl Drop for PlatformMutex {
    fn drop(&mut self) {
        // Don't call pthread_mutex_destroy here. On macOS, the virtual
        // address may be recycled to a different shm segment after munmap,
        // and destroy would zero the __sig field of whatever mutex now
        // lives at that address. The shm munmap + unlink in
        // PlatformShm::Drop is sufficient to reclaim the memory.
        cached_shm_release(mutex_cache(), &self.name);
    }
}
