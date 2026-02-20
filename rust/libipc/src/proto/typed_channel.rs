// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Typed FlatBuffer wrapper around Channel.
// Port of cpp-ipc/include/libipc/proto/typed_channel.h.

use std::io;

use super::message::{Builder, Message};
use crate::channel::{Channel, Mode};

/// A typed wrapper around [`Channel`] for FlatBuffer messages.
///
/// `T` is the FlatBuffers-generated root table type.
///
/// Port of `ipc::proto::typed_channel<T>` from the C++ libipc library.
pub struct TypedChannel<T> {
    ch: Channel,
    _marker: std::marker::PhantomData<T>,
}

impl<T> TypedChannel<T> {
    /// Connect to a named channel as sender or receiver.
    pub fn connect(name: &str, mode: Mode) -> io::Result<Self> {
        Ok(Self {
            ch: Channel::connect(name, mode)?,
            _marker: std::marker::PhantomData,
        })
    }

    /// Connect with a prefix.
    pub fn connect_with_prefix(prefix: &str, name: &str, mode: Mode) -> io::Result<Self> {
        Ok(Self {
            ch: Channel::connect_with_prefix(prefix, name, mode)?,
            _marker: std::marker::PhantomData,
        })
    }

    pub fn disconnect(&mut self) {
        // Drop and replace with a disconnected state is not directly supported;
        // the channel disconnects on Drop. Exposed for API parity with C++.
    }

    /// Send a pre-built FlatBuffer message.
    pub fn send_builder(&mut self, b: &Builder, timeout_ms: u64) -> io::Result<bool> {
        self.ch.send(b.data(), timeout_ms)
    }

    /// Send raw bytes (already a finished FlatBuffer).
    pub fn send(&mut self, data: &[u8], timeout_ms: u64) -> io::Result<bool> {
        self.ch.send(data, timeout_ms)
    }

    /// Remove all backing storage for a named channel.
    pub fn clear_storage(name: &str) {
        Channel::clear_storage(name);
    }

    /// Access the underlying raw channel.
    pub fn raw(&mut self) -> &mut Channel {
        &mut self.ch
    }
}

impl<T> TypedChannel<T> {
    /// Receive a typed message. Returns an empty `Message` on timeout.
    pub fn recv(&mut self, timeout_ms: Option<u64>) -> io::Result<Message<T>> {
        let buf = self.ch.recv(timeout_ms)?;
        Ok(Message::new(buf))
    }

    /// Try receiving without blocking.
    pub fn try_recv(&mut self) -> io::Result<Message<T>> {
        let buf = self.ch.try_recv()?;
        Ok(Message::new(buf))
    }
}
