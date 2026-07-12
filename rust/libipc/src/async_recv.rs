// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Layer 2 (opt-in `async-tokio` feature): an ergonomic `AsyncRoute::recv().await`
// on top of the Layer-1 readiness fd (native_wait_handle). Unlike the C++ side —
// which builds a bespoke kqueue/epoll reactor because stdexec has none — Rust
// runtimes already have a reactor, so this just hands the fd to tokio's via
// `AsyncFd` and does a fast-path `try_recv` around each readiness wait. No extra
// thread, no bespoke reactor.
//
// Runtime-agnostic users who don't want tokio can drive `native_wait_handle()`
// directly (poll/epoll/kqueue/async-io) + `try_recv()` + `drain_wait_handle()`.

use std::io;
use std::os::unix::io::{AsRawFd, RawFd};

use tokio::io::unix::AsyncFd;
use tokio::io::Interest;

use crate::buffer::IpcBuffer;
use crate::channel::{Mode, Route};

/// A `RawFd` wrapper that hands the descriptor to `AsyncFd` for readiness polling
/// **without owning it** — the fd's lifetime belongs to the `Route`'s notify sink,
/// which closes it on drop. `AsyncFd` only deregisters (never closes) on drop.
struct SinkFd(RawFd);

impl AsRawFd for SinkFd {
    fn as_raw_fd(&self) -> RawFd {
        self.0
    }
}

/// An async broadcast receiver: awaits messages on a tokio runtime, woken by the
/// Layer-1 readiness fd (which any-language sender pokes via the notify layer).
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
    // `afd` is declared first so it drops (deregisters from the reactor) before
    // `route` drops (closes the underlying fd) — never the reverse.
    afd: AsyncFd<SinkFd>,
    route: Route,
}

impl AsyncRoute {
    /// Wrap an existing receiver `Route`. Fails if the route has no readiness
    /// handle (not a receiver, or the crate/peer lacks the notify layer).
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

    /// Unwrap back into the blocking `Route` (deregisters the fd from the reactor).
    pub fn into_route(self) -> Route {
        self.route
    }

    /// Await the next message. Cancel-safe: dropping the returned future before it
    /// completes leaves the channel state untouched (nothing is consumed until a
    /// full message is returned).
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
}
