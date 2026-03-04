// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Protocol Buffers codec scaffolding for typed protocol wrappers.

use std::marker::PhantomData;

use crate::buffer::IpcBuffer;

use super::super::codec::{Codec, CodecId};

/// Minimal wire contract for protobuf-like message types.
///
/// This keeps the Phase B scaffolding independent from any specific Rust
/// protobuf runtime. Callers can implement this for `prost` or other message
/// types.
pub trait ProtobufWireMessage: Sized {
    fn encode(&self) -> Vec<u8>;
    fn decode(bytes: &[u8]) -> Option<Self>;
}

/// Encoded protobuf payload for transport.
pub struct ProtobufBuilder<T> {
    bytes: Vec<u8>,
    _marker: PhantomData<T>,
}

impl<T> ProtobufBuilder<T> {
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

impl<T> Default for ProtobufBuilder<T> {
    fn default() -> Self {
        Self::from_bytes(Vec::new())
    }
}

impl<T> From<Vec<u8>> for ProtobufBuilder<T> {
    fn from(value: Vec<u8>) -> Self {
        Self::from_bytes(value)
    }
}

impl<T> From<&[u8]> for ProtobufBuilder<T> {
    fn from(value: &[u8]) -> Self {
        Self::from_bytes(value.to_vec())
    }
}

impl<T> ProtobufBuilder<T>
where
    T: ProtobufWireMessage,
{
    pub fn from_message(message: &T) -> Self {
        Self::from_bytes(message.encode())
    }
}

/// Decoded protobuf message wrapper with access to the raw transport buffer.
pub struct ProtobufMessage<T> {
    buffer: IpcBuffer,
    value: Option<T>,
}

impl<T> ProtobufMessage<T> {
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

impl<T> Default for ProtobufMessage<T> {
    fn default() -> Self {
        Self::empty()
    }
}

pub struct ProtobufCodec;

impl<T> Codec<T> for ProtobufCodec
where
    T: ProtobufWireMessage,
{
    type Message = ProtobufMessage<T>;
    type Builder = ProtobufBuilder<T>;

    const CODEC_ID: CodecId = CodecId::Protobuf;

    fn encode(builder: &Self::Builder) -> &[u8] {
        builder.bytes()
    }

    fn decode(buf: IpcBuffer) -> Self::Message {
        let value = T::decode(buf.data());
        ProtobufMessage::new(buf, value)
    }

    fn verify(message: &Self::Message) -> bool {
        message.is_valid()
    }
}
