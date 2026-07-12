// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Layer 2 (opt-in `async-tokio` feature): an ergonomic `AsyncRoute::recv().await`
// on top of the Layer-1 readiness handle (native_wait_handle).
//
//   * unix: the readiness handle is a pollable fd, so it is handed straight to
//     tokio's reactor via `AsyncFd` with a fast-path `try_recv` around each wait.
//     No extra thread, no bespoke reactor.
//   * Windows: the readiness handle is a waitable auto-reset Event; tokio has no
//     `AsyncFd` there, so the Event is registered with the Win32 thread pool
//     (RegisterWaitForSingleObject). Each SetEvent wakes a `tokio::sync::Notify`
//     the task awaits, then `recv()` re-polls `try_recv` — the HANDLE-based
//     analogue of the unix `AsyncFd` loop, still no per-recv thread.
//
// Runtime-agnostic users who don't want tokio can drive `native_wait_handle()`
// directly (poll/epoll/kqueue/async-io on unix; a wait registration on Windows)
// + `try_recv()` + `drain_wait_handle()`.

use std::io;

use crate::buffer::IpcBuffer;
use crate::channel::{Mode, Route};

#[cfg(unix)]
use std::os::unix::io::{AsRawFd, RawFd};
#[cfg(unix)]
use tokio::io::unix::AsyncFd;
#[cfg(unix)]
use tokio::io::Interest;

/// A `RawFd` wrapper that hands the descriptor to `AsyncFd` for readiness polling
/// **without owning it** — the fd's lifetime belongs to the `Route`'s notify sink,
/// which closes it on drop. `AsyncFd` only deregisters (never closes) on drop.
#[cfg(unix)]
struct SinkFd(RawFd);

#[cfg(unix)]
impl AsRawFd for SinkFd {
    fn as_raw_fd(&self) -> RawFd {
        self.0
    }
}

// ---------------------------------------------------------------------------
// Windows readiness: a thread-pool wait on the channel's Event -> tokio Notify
// ---------------------------------------------------------------------------
#[cfg(windows)]
mod win {
    use std::io;
    use std::sync::Arc;

    use tokio::sync::Notify;
    use windows_sys::Win32::Foundation::{HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Threading::{
        RegisterWaitForSingleObject, UnregisterWaitEx, WT_EXECUTEDEFAULT,
    };

    /// Owns a Win32 thread-pool wait registration on the channel's readiness Event.
    /// On each SetEvent the callback wakes the shared `Notify`; `recv()` then
    /// re-polls `try_recv`. On drop it unregisters (blocking until any in-flight
    /// callback returns) before freeing the callback context.
    pub(super) struct WinWait {
        wait: HANDLE,
        ctx: *const Notify, // a leaked Arc<Notify> clone, reclaimed on drop
    }

    // The registration is only ever touched from register()/drop() on the owning
    // task; the raw HANDLE/context are not shared mutably across threads.
    unsafe impl Send for WinWait {}
    unsafe impl Sync for WinWait {}

    // Signature must match windows-sys WAITORTIMERCALLBACK (second arg is `bool`).
    unsafe extern "system" fn wake_cb(ctx: *mut core::ffi::c_void, _timer_or_wait: bool) {
        // `ctx` borrows the Arc<Notify> kept alive by WinWait::ctx; UnregisterWaitEx
        // in Drop guarantees this borrow ends before the Arc is freed.
        let n = &*(ctx as *const Notify);
        n.notify_one();
    }

    impl WinWait {
        pub(super) fn register(event: isize, notify: &Arc<Notify>) -> io::Result<Self> {
            let ctx = Arc::into_raw(notify.clone());
            let mut wait: HANDLE = std::ptr::null_mut();
            // No WT_EXECUTEONLYONCE: the pool auto-re-arms after each callback, so
            // the registration persists for the AsyncRoute's lifetime and fires on
            // every signal of the (auto-reset) Event.
            let ok = unsafe {
                RegisterWaitForSingleObject(
                    &mut wait,
                    event as HANDLE,
                    Some(wake_cb),
                    ctx as *const core::ffi::c_void,
                    u32::MAX, // INFINITE
                    WT_EXECUTEDEFAULT,
                )
            };
            if ok == 0 {
                unsafe { drop(Arc::from_raw(ctx)) };
                return Err(io::Error::last_os_error());
            }
            Ok(Self { wait, ctx })
        }
    }

    impl Drop for WinWait {
        fn drop(&mut self) {
            unsafe {
                // Blocks until any in-flight callback returns, so wake_cb's borrow
                // of the Notify is over before we drop the backing Arc.
                UnregisterWaitEx(self.wait, INVALID_HANDLE_VALUE);
                drop(Arc::from_raw(self.ctx));
            }
        }
    }
}

/// An async broadcast receiver: awaits messages on a tokio runtime, woken by the
/// Layer-1 readiness handle (which any-language sender pokes via the notify layer).
///
/// ```no_run
/// # async fn ex() -> std::io::Result<()> {
/// use libipc::async_recv::AsyncRoute;
/// let mut r = AsyncRoute::connect("st.agent.cmd")?;
/// loop {
///     let msg = r.recv().await?;
///     // dispatch msg.data() ...
/// }
/// # }
/// ```
pub struct AsyncRoute {
    // The readiness registration is declared before `route` so it drops
    // (deregisters/unregisters) before `route` drops (closes the underlying
    // handle) — never the reverse.
    #[cfg(unix)]
    afd: AsyncFd<SinkFd>,
    #[cfg(windows)]
    wait: win::WinWait,
    #[cfg(windows)]
    notify: std::sync::Arc<tokio::sync::Notify>,
    route: Route,
}

impl AsyncRoute {
    /// Wrap an existing receiver `Route`. Fails if the route has no readiness
    /// handle (not a receiver, or the crate/peer lacks the notify layer).
    #[cfg(unix)]
    pub fn new(mut route: Route) -> io::Result<Self> {
        if route.mode() != Mode::Receiver {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "AsyncRoute requires a receiver",
            ));
        }
        let fd = route.native_wait_handle();
        if fd < 0 {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "no readiness handle (build the crate and peer with the notify feature)",
            ));
        }
        let afd = AsyncFd::with_interest(SinkFd(fd), Interest::READABLE)?;
        Ok(Self { afd, route })
    }

    /// Wrap an existing receiver `Route` (Windows: register its Event with the
    /// thread pool so a sender's SetEvent wakes the awaiting task).
    #[cfg(windows)]
    pub fn new(mut route: Route) -> io::Result<Self> {
        if route.mode() != Mode::Receiver {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "AsyncRoute requires a receiver",
            ));
        }
        let h = route.native_wait_handle();
        if h == crate::notify::INVALID_WAIT_HANDLE {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "no readiness handle (build the crate and peer with the notify feature)",
            ));
        }
        let notify = std::sync::Arc::new(tokio::sync::Notify::new());
        let wait = win::WinWait::register(h, &notify)?;
        Ok(Self { wait, notify, route })
    }

    /// Connect as a receiver on `name` and wrap it for async receive.
    pub fn connect(name: &str) -> io::Result<Self> {
        Self::new(Route::connect(name, Mode::Receiver)?)
    }

    /// Connect as a receiver on `name` under `prefix`.
    pub fn connect_with_prefix(prefix: &str, name: &str) -> io::Result<Self> {
        Self::new(Route::connect_with_prefix(prefix, name, Mode::Receiver)?)
    }

    /// Number of connected senders+receivers on this channel.
    pub fn recv_count(&self) -> usize {
        self.route.recv_count()
    }

    /// Borrow the underlying `Route` (e.g. to send on a bidirectional channel).
    pub fn route(&mut self) -> &mut Route {
        &mut self.route
    }

    /// Unwrap back into the blocking `Route` (deregisters/unregisters the handle).
    pub fn into_route(self) -> Route {
        self.route
    }

    /// Await the next message. Cancel-safe: dropping the returned future before it
    /// completes leaves the channel state untouched (nothing is consumed until a
    /// full message is returned).
    #[cfg(unix)]
    pub async fn recv(&mut self) -> io::Result<IpcBuffer> {
        loop {
            // Fast path: drain anything already queued (also covers messages that
            // landed before we registered, and coalesced notifications).
            let buf = self.route.try_recv()?;
            if !buf.is_empty() {
                return Ok(buf);
            }
            // Park until the readiness fd signals (a sender's notify post).
            let mut guard = self.afd.readable().await?;
            // The notify fd is level-triggered: drain its tokens, then re-check.
            self.route.drain_wait_handle();
            match self.route.try_recv() {
                Ok(buf) if !buf.is_empty() => return Ok(buf),
                Ok(_) => {
                    // Woken with nothing ready yet — clear readiness and re-park.
                    guard.clear_ready();
                }
                Err(e) => return Err(e),
            }
        }
    }

    /// Await the next message (Windows: parked on a `Notify` woken by the Event's
    /// thread-pool callback). Cancel-safe for the same reason as the unix path.
    #[cfg(windows)]
    pub async fn recv(&mut self) -> io::Result<IpcBuffer> {
        loop {
            let buf = self.route.try_recv()?;
            if !buf.is_empty() {
                return Ok(buf);
            }
            // Arm the wait BEFORE re-checking so a SetEvent that races in between
            // the try_recv above and parking is not lost (tokio Notify permit).
            let notified = self.notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            let buf = self.route.try_recv()?;
            if !buf.is_empty() {
                return Ok(buf);
            }
            notified.await;
        }
    }
}
