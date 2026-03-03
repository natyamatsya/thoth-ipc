// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// FlatBuffers codec adapter for typed protocol wrappers.

use crate::buffer::IpcBuffer;

use super::super::codec::{Codec, CodecId};
use super::super::message::{Builder, Message};

pub struct FlatBuffersCodec;

impl<T> Codec<T> for FlatBuffersCodec {
    type Message = Message<T>;
    type Builder = Builder;

    const CODEC_ID: CodecId = CodecId::FlatBuffers;

    fn encode(builder: &Self::Builder) -> &[u8] {
        builder.data()
    }

    fn decode(buf: IpcBuffer) -> Self::Message {
        Message::new(buf)
    }
}
