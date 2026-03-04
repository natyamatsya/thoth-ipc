// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Cap'n Proto codec scaffolding for typed protocol wrappers.

use std::marker::PhantomData;

use crate::buffer::IpcBuffer;

use super::super::codec::{Codec, CodecId};

/// Minimal wire contract for Cap'n Proto-like message types.
///
/// This keeps Phase C scaffolding independent from any specific Rust Cap'n
/// Proto runtime. Callers can implement this for generated message adapters.
pub trait CapnpWireMessage: Sized {
    fn encode(&self) -> Vec<u8>;
    fn decode(bytes: &[u8]) -> Option<Self>;
}

/// Encoded Cap'n Proto payload for transport.
pub struct CapnpBuilder<T> {
    bytes: Vec<u8>,
    _marker: PhantomData<T>,
}

impl<T> CapnpBuilder<T> {
    pub fn from_bytes(bytes: Vec<u8>) -> Self {
        Self {
            bytes,
            _marker: PhantomData,
        }
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
}

impl<T> Default for CapnpBuilder<T> {
    fn default() -> Self {
        Self::from_bytes(Vec::new())
    }
}

impl<T> From<Vec<u8>> for CapnpBuilder<T> {
    fn from(value: Vec<u8>) -> Self {
        Self::from_bytes(value)
    }
}

impl<T> From<&[u8]> for CapnpBuilder<T> {
    fn from(value: &[u8]) -> Self {
        Self::from_bytes(value.to_vec())
    }
}

impl<T> CapnpBuilder<T>
where
    T: CapnpWireMessage,
{
    pub fn from_message(message: &T) -> Self {
        Self::from_bytes(message.encode())
    }
}

/// Decoded Cap'n Proto message wrapper with access to the raw transport buffer.
pub struct CapnpMessage<T> {
    buffer: IpcBuffer,
    value: Option<T>,
}

impl<T> CapnpMessage<T> {
    pub fn new(buffer: IpcBuffer, value: Option<T>) -> Self {
        Self { buffer, value }
    }

    pub fn empty() -> Self {
        Self::new(IpcBuffer::new(), None)
    }

    pub fn is_empty(&self) -> bool {
        self.buffer.is_empty()
    }

    pub fn is_valid(&self) -> bool {
        self.value.is_some()
    }

    pub fn data(&self) -> &[u8] {
        self.buffer.data()
    }

    pub fn size(&self) -> usize {
        self.buffer.len()
    }

    pub fn root(&self) -> Option<&T> {
        self.value.as_ref()
    }

    pub fn into_root(self) -> Option<T> {
        self.value
    }

    pub fn into_buffer(self) -> IpcBuffer {
        self.buffer
    }
}

impl<T> Default for CapnpMessage<T> {
    fn default() -> Self {
        Self::empty()
    }
}

pub struct CapnpCodec;

impl<T> Codec<T> for CapnpCodec
where
    T: CapnpWireMessage,
{
    type Message = CapnpMessage<T>;
    type Builder = CapnpBuilder<T>;

    const CODEC_ID: CodecId = CodecId::Capnp;

    fn encode(builder: &Self::Builder) -> &[u8] {
        builder.bytes()
    }

    fn decode(buf: IpcBuffer) -> Self::Message {
        let value = T::decode(buf.data());
        CapnpMessage::new(buf, value)
    }

    fn verify(message: &Self::Message) -> bool {
        message.is_valid()
    }
}
