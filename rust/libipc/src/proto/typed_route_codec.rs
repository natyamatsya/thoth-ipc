// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Generic typed wrapper around Route using a pluggable codec.

use std::io;

use crate::channel::{Mode, Route};

use super::codec::Codec;

pub struct TypedRouteCodec<T, C> {
    rt: Route,
    _marker: std::marker::PhantomData<(T, C)>,
}

impl<T, C> TypedRouteCodec<T, C>
where
    C: Codec<T>,
{
    /// Connect to a named route as sender or receiver.
    pub fn connect(name: &str, mode: Mode) -> io::Result<Self> {
        Ok(Self {
            rt: Route::connect(name, mode)?,
            _marker: std::marker::PhantomData,
        })
    }

    /// Connect with a prefix.
    pub fn connect_with_prefix(prefix: &str, name: &str, mode: Mode) -> io::Result<Self> {
        Ok(Self {
            rt: Route::connect_with_prefix(prefix, name, mode)?,
            _marker: std::marker::PhantomData,
        })
    }

    pub fn disconnect(&mut self) {
        // Drop and replace with a disconnected state is not directly supported;
        // the route disconnects on Drop. Exposed for API parity with C++.
    }

    /// Send a pre-built typed message.
    pub fn send_builder(&mut self, b: &C::Builder, timeout_ms: u64) -> io::Result<bool> {
        self.rt.send(C::encode(b), timeout_ms)
    }

    /// Send raw bytes (already encoded by the caller).
    pub fn send(&mut self, data: &[u8], timeout_ms: u64) -> io::Result<bool> {
        self.rt.send(data, timeout_ms)
    }

    /// Remove all backing storage for a named route.
    pub fn clear_storage(name: &str) {
        Route::clear_storage(name);
    }

    /// Access the underlying raw route.
    pub fn raw(&mut self) -> &mut Route {
        &mut self.rt
    }

    /// Receive a typed message. Returns an empty message on timeout.
    pub fn recv(&mut self, timeout_ms: Option<u64>) -> io::Result<C::Message> {
        let buf = self.rt.recv(timeout_ms)?;
        Ok(C::decode(buf))
    }

    /// Try receiving without blocking.
    pub fn try_recv(&mut self) -> io::Result<C::Message> {
        let buf = self.rt.try_recv()?;
        Ok(C::decode(buf))
    }
}
