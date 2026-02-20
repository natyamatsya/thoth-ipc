// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Typed FlatBuffer wrapper around Route.
// Port of cpp-ipc/include/libipc/proto/typed_route.h.

use std::io;

use crate::channel::{Mode, Route};
use super::message::{Builder, Message};

/// A typed wrapper around [`Route`] for FlatBuffer messages.
///
/// `T` is the FlatBuffers-generated root table type.
/// `Route` is single-writer, multiple-reader (broadcast).
///
/// Port of `ipc::proto::typed_route<T>` from the C++ libipc library.
pub struct TypedRoute<T> {
    rt: Route,
    _marker: std::marker::PhantomData<T>,
}

impl<T> TypedRoute<T> {
    /// Connect to a named route as sender or receiver.
    pub fn connect(name: &str, mode: Mode) -> io::Result<Self> {
        Ok(Self { rt: Route::connect(name, mode)?, _marker: std::marker::PhantomData })
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

    /// Send a pre-built FlatBuffer message.
    pub fn send_builder(&mut self, b: &Builder, timeout_ms: u64) -> io::Result<bool> {
        self.rt.send(b.data(), timeout_ms)
    }

    /// Send raw bytes (already a finished FlatBuffer).
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
}

impl<T> TypedRoute<T>
where
    T: for<'a> flatbuffers::Follow<'a, Inner = &'a T>,
{
    /// Receive a typed message. Returns an empty `Message` on timeout.
    pub fn recv(&mut self, timeout_ms: Option<u64>) -> io::Result<Message<T>> {
        let buf = self.rt.recv(timeout_ms)?;
        Ok(Message::new(buf))
    }

    /// Try receiving without blocking.
    pub fn try_recv(&mut self) -> io::Result<Message<T>> {
        let buf = self.rt.try_recv()?;
        Ok(Message::new(buf))
    }
}
