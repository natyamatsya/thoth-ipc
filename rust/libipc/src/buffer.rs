// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/include/libipc/buffer.h + buffer.cpp.
// An owning byte buffer used as the message type for IPC channels.
// In Rust this wraps a `Vec<u8>` instead of the C++ pimpl + custom destructor.

/// An owning byte buffer for IPC message data.
///
/// This is the Rust equivalent of `ipc::buffer`. Messages sent through
/// `Route` or `Channel` are serialised into `IpcBuffer` for transmission
/// and deserialised back on the receiver side.
#[derive(Clone)]
pub struct IpcBuffer {
    data: Vec<u8>,
}

impl IpcBuffer {
    /// Create an empty buffer.
    pub const fn new() -> Self {
        Self { data: Vec::new() }
    }

    /// Create a buffer from raw bytes (copies the data).
    pub fn from_slice(data: &[u8]) -> Self {
        Self { data: data.to_vec() }
    }

    /// Create a buffer taking ownership of a `Vec<u8>`.
    pub fn from_vec(data: Vec<u8>) -> Self {
        Self { data }
    }

    /// Create a buffer from a string (includes the null terminator for C++ compat).
    pub fn from_str(s: &str) -> Self {
        let mut v = Vec::with_capacity(s.len() + 1);
        v.extend_from_slice(s.as_bytes());
        v.push(0);
        Self { data: v }
    }

    /// Whether the buffer is empty.
    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }

    /// Number of bytes in the buffer.
    pub fn len(&self) -> usize {
        self.data.len()
    }

    /// Pointer to the data.
    pub fn data(&self) -> &[u8] {
        &self.data
    }

    /// Mutable pointer to the data.
    pub fn data_mut(&mut self) -> &mut [u8] {
        &mut self.data
    }

    /// Consume into the underlying `Vec<u8>`.
    pub fn into_vec(self) -> Vec<u8> {
        self.data
    }

    /// Convert to a `Vec<u8>` (clone).
    pub fn to_vec(&self) -> Vec<u8> {
        self.data.clone()
    }

    /// Swap contents with another buffer.
    pub fn swap(&mut self, other: &mut IpcBuffer) {
        std::mem::swap(&mut self.data, &mut other.data);
    }
}

impl Default for IpcBuffer {
    fn default() -> Self {
        Self::new()
    }
}

impl PartialEq for IpcBuffer {
    fn eq(&self, other: &Self) -> bool {
        self.data == other.data
    }
}

impl Eq for IpcBuffer {}

impl std::fmt::Debug for IpcBuffer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("IpcBuffer")
            .field("len", &self.data.len())
            .finish()
    }
}

impl From<Vec<u8>> for IpcBuffer {
    fn from(v: Vec<u8>) -> Self {
        Self::from_vec(v)
    }
}

impl From<&[u8]> for IpcBuffer {
    fn from(s: &[u8]) -> Self {
        Self::from_slice(s)
    }
}

impl From<&str> for IpcBuffer {
    fn from(s: &str) -> Self {
        Self::from_str(s)
    }
}

impl From<String> for IpcBuffer {
    fn from(s: String) -> Self {
        Self::from_str(&s)
    }
}
