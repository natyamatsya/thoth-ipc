// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Generic codec abstraction for typed protocol wrappers.

use crate::buffer::IpcBuffer;

/// Wire-level codec identifiers used by typed protocol wrappers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum CodecId {
    FlatBuffers = 1,
    Protobuf = 2,
    Capnp = 3,
}

/// Codec contract for typed protocol wrappers.
///
/// `T` is the schema root type used by the wrapper.
pub trait Codec<T> {
    type Message;
    type Builder;

    const CODEC_ID: CodecId;

    /// Encode a pre-built message into raw bytes for transport.
    fn encode(builder: &Self::Builder) -> &[u8];

    /// Decode transport bytes into a typed message view/value.
    fn decode(buf: IpcBuffer) -> Self::Message;

    /// Optional validation hook for codec-specific checks.
    fn verify(_message: &Self::Message) -> bool {
        true
    }
}
