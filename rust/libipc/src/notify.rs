// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Layer 1 of the optional async-receive work (opt-in `notify` feature), a port of
// cpp/libipc/src/libipc/notify.h. It turns a channel's readiness into a waitable,
// multiplexable kernel object so a consumer can select/epoll/kqueue on it instead
// of dedicating a blocking thread per channel.
//
// **Byte-exact with the C++ notify layer** so a Rust `send()` wakes a C++
// `async_recv` reactor (and, once the sink lands, vice versa). The naming and
// backends match notify.h exactly:
//
//   * macOS  -> libnotify: `notify_post(key)` wakes an fd obtained from
//     `notify_register_file_descriptor(key, ...)` in ANY process. Multicast — one
//     post wakes every registered reader — so a single key per channel honours
//     broadcast. This is the default on Apple.
//   * POSIX  -> named FIFO `<dir>/ipcntf_<hash>.<slot>`: point-to-point, so
//     broadcast is honoured by poking every connected reader slot's FIFO.
//
// This module currently implements only the SOURCE (writer) side; the sink
// (reader) side + native_wait_handle() follow.

use crate::shm_name::fnv1a_64;

/// Short, service-/filesystem-safe channel identity: 16-hex FNV-1a-64 of
/// `make_prefix(prefix, "NOTIFY__", name)` = `"{prefix}__IPC_SHM__NOTIFY__{name}"`.
/// Byte-exact with C++ `ipc::detail::notify_hash`.
fn notify_hash(prefix: &str, name: &str) -> String {
    let id = format!("{prefix}__IPC_SHM__NOTIFY__{name}");
    let hash = fnv1a_64(id.as_bytes());
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut buf = [0u8; 16];
    let mut v = hash;
    for i in (0..16).rev() {
        buf[i] = DIGITS[(v & 0xf) as usize];
        v >>= 4;
    }
    // Always valid ASCII hex.
    String::from_utf8(buf.to_vec()).unwrap()
}

// =============================================================================
// macOS — libnotify (default on Apple)
// =============================================================================
#[cfg(all(target_vendor = "apple", not(feature = "notify_fifo")))]
mod backend {
    use super::notify_hash;
    use std::ffi::CString;
    use std::os::raw::c_char;

    // libsystem_notify (part of libSystem, linked by default on Apple).
    extern "C" {
        fn notify_post(name: *const c_char) -> u32;
    }

    /// libnotify service key for a channel (one per channel — posts are multicast).
    /// Byte-exact with C++ `notify_key`.
    fn notify_key(prefix: &str, name: &str) -> String {
        format!("ipc.ntf.{}", notify_hash(prefix, name))
    }

    /// Writer side: post the channel's key; libnotify multicasts to all readers.
    pub struct NotifySource {
        key: Option<CString>,
    }

    impl NotifySource {
        pub fn new() -> Self {
            Self { key: None }
        }

        /// Signal readiness. `conns`/`self_bit` are unused for libnotify (multicast).
        pub fn signal(&mut self, prefix: &str, name: &str, _conns: u32, _self_bit: u32) {
            if self.key.is_none() {
                self.key = CString::new(notify_key(prefix, name)).ok();
            }
            if let Some(k) = &self.key {
                // SAFETY: k is a valid NUL-terminated C string; notify_post is
                // thread-safe and a no-op when no fd is registered for the key.
                unsafe {
                    notify_post(k.as_ptr());
                }
            }
        }

        pub fn close(&mut self) {}
    }

    /// No filesystem node to reclaim for libnotify.
    pub fn clear_storage(_prefix: &str, _name: &str) {}
}

// =============================================================================
// Other POSIX (and Apple with `notify_fifo`) — named FIFOs
// =============================================================================
#[cfg(all(unix, any(not(target_vendor = "apple"), feature = "notify_fifo")))]
mod backend {
    use super::notify_hash;
    use std::fs::File;
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    use std::os::unix::io::AsRawFd;

    /// Max reader connection slots in broadcast mode (C++ `notify_max_slots`).
    const MAX_SLOTS: usize = 32;

    /// Deterministic FIFO path shared by both processes: `<dir>/ipcntf_<hash>.<slot>`.
    /// Directory is `/tmp` by default, overridable via `LIBIPC_NOTIFY_DIR`. Byte-exact
    /// with C++ `notify_fifo_path`.
    fn fifo_path(prefix: &str, name: &str, slot: usize) -> String {
        let dir = std::env::var("LIBIPC_NOTIFY_DIR")
            .ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "/tmp".to_string());
        format!("{dir}/ipcntf_{}.{slot}", notify_hash(prefix, name))
    }

    #[cfg(target_vendor = "apple")]
    fn set_nosigpipe(f: &File) {
        unsafe { libc::fcntl(f.as_raw_fd(), libc::F_SETNOSIGPIPE, 1) };
    }
    #[cfg(not(target_vendor = "apple"))]
    fn set_nosigpipe(_f: &File) {}

    /// Block SIGPIPE for the duration of a FIFO write whose reader may have vanished
    /// (Linux has no per-fd F_SETNOSIGPIPE). Mirrors C++ `notify_sigpipe_guard`.
    #[cfg(not(target_vendor = "apple"))]
    struct SigpipeGuard {
        old: libc::sigset_t,
        blocked: bool,
    }
    #[cfg(not(target_vendor = "apple"))]
    impl SigpipeGuard {
        fn new() -> Self {
            unsafe {
                let mut s: libc::sigset_t = std::mem::zeroed();
                libc::sigemptyset(&mut s);
                libc::sigaddset(&mut s, libc::SIGPIPE);
                let mut old: libc::sigset_t = std::mem::zeroed();
                let blocked = libc::pthread_sigmask(libc::SIG_BLOCK, &s, &mut old) == 0;
                Self { old, blocked }
            }
        }
    }
    #[cfg(not(target_vendor = "apple"))]
    impl Drop for SigpipeGuard {
        fn drop(&mut self) {
            unsafe {
                // Consume any SIGPIPE we generated before restoring the mask.
                let mut pend: libc::sigset_t = std::mem::zeroed();
                if libc::sigpending(&mut pend) == 0 && libc::sigismember(&pend, libc::SIGPIPE) == 1 {
                    let mut only: libc::sigset_t = std::mem::zeroed();
                    libc::sigemptyset(&mut only);
                    libc::sigaddset(&mut only, libc::SIGPIPE);
                    let mut sig = 0;
                    let zero = libc::timespec { tv_sec: 0, tv_nsec: 0 };
                    libc::sigtimedwait(&only, &mut sig, &zero);
                }
                if self.blocked {
                    libc::pthread_sigmask(libc::SIG_SETMASK, &self.old, std::ptr::null_mut());
                }
            }
        }
    }
    #[cfg(target_vendor = "apple")]
    struct SigpipeGuard;
    #[cfg(target_vendor = "apple")]
    impl SigpipeGuard {
        fn new() -> Self {
            Self
        }
    }

    /// Writer side: on enqueue, poke every connected reader slot's FIFO.
    pub struct NotifySource {
        wfd: [Option<File>; MAX_SLOTS],
    }

    impl NotifySource {
        pub fn new() -> Self {
            Self {
                wfd: std::array::from_fn(|_| None),
            }
        }

        pub fn signal(&mut self, prefix: &str, name: &str, conns: u32, self_bit: u32) {
            for i in 0..MAX_SLOTS {
                let bit = 1u32 << i;
                let want = (conns & bit) != 0 && (self_bit & bit) == 0;
                if !want {
                    self.wfd[i] = None; // drop stale slot fd
                    continue;
                }
                if self.wfd[i].is_none() {
                    // O_WRONLY | O_NONBLOCK: ENXIO if no reader has the FIFO open yet.
                    match std::fs::OpenOptions::new()
                        .write(true)
                        .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
                        .open(fifo_path(prefix, name, i))
                    {
                        Ok(f) => {
                            set_nosigpipe(&f);
                            self.wfd[i] = Some(f);
                        }
                        Err(_) => continue, // reader not ready yet; try next time
                    }
                }
                if let Some(f) = self.wfd[i].as_mut() {
                    let _guard = SigpipeGuard::new();
                    match f.write(&[1u8]) {
                        Ok(_) => {}
                        Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            // EAGAIN: an unconsumed wake byte remains → readiness holds.
                        }
                        Err(_) => {
                            self.wfd[i] = None; // EPIPE/ENXIO: reader gone → reopen later
                        }
                    }
                }
            }
        }

        pub fn close(&mut self) {
            for slot in self.wfd.iter_mut() {
                *slot = None;
            }
        }
    }

    /// Best-effort removal of every slot FIFO for a channel (C++ `notify_clear_storage`).
    pub fn clear_storage(prefix: &str, name: &str) {
        for i in 0..MAX_SLOTS {
            let _ = std::fs::remove_file(fifo_path(prefix, name, i));
        }
    }
}

pub use backend::{clear_storage, NotifySource};
