// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Secure codec decorator with envelope v1 framing.

use std::marker::PhantomData;
use std::mem::size_of;

use crate::buffer::IpcBuffer;

use super::super::codec::{Codec, CodecId};
use super::super::typed_channel_codec::TypedChannelCodec;
use super::super::typed_route_codec::TypedRouteCodec;

pub trait SecureCipher {
    fn algorithm_id() -> u16 {
        0
    }

    fn key_id() -> u32 {
        0
    }

    fn seal(plain: &[u8], nonce: &mut Vec<u8>, ciphertext: &mut Vec<u8>, tag: &mut Vec<u8>)
        -> bool;

    fn open(nonce: &[u8], ciphertext: &[u8], tag: &[u8], plain: &mut Vec<u8>) -> bool;
}

const SECURE_ENVELOPE_MAGIC: &[u8; 4] = b"SIPC";
const SECURE_ENVELOPE_VERSION: u8 = 1;
const SECURE_ENVELOPE_OFFSET_VERSION: usize = 4;
const SECURE_ENVELOPE_OFFSET_ALGORITHM_ID: usize = 5;
const SECURE_ENVELOPE_OFFSET_KEY_ID: usize = 7;
const SECURE_ENVELOPE_OFFSET_NONCE_SIZE: usize = 11;
const SECURE_ENVELOPE_OFFSET_TAG_SIZE: usize = 13;
const SECURE_ENVELOPE_OFFSET_CIPHERTEXT_SIZE: usize = 15;
const SECURE_ENVELOPE_FIXED_HEADER_SIZE: usize = 19;

struct SecureEnvelopeView<'a> {
    algorithm_id: u16,
    key_id: u32,
    nonce: &'a [u8],
    ciphertext: &'a [u8],
    tag: &'a [u8],
}

fn append_u16_le(out: &mut Vec<u8>, value: u16) {
    out.push((value & 0x00FF) as u8);
    out.push(((value >> 8) & 0x00FF) as u8);
}

fn append_u32_le(out: &mut Vec<u8>, value: u32) {
    out.push((value & 0x0000_00FF) as u8);
    out.push(((value >> 8) & 0x0000_00FF) as u8);
    out.push(((value >> 16) & 0x0000_00FF) as u8);
    out.push(((value >> 24) & 0x0000_00FF) as u8);
}

fn read_u16_le(data: &[u8], offset: usize) -> Option<u16> {
    if offset > data.len() {
        return None;
    }
    if data.len() - offset < size_of::<u16>() {
        return None;
    }
    Some(u16::from(data[offset]) | (u16::from(data[offset + 1]) << 8))
}

fn read_u32_le(data: &[u8], offset: usize) -> Option<u32> {
    if offset > data.len() {
        return None;
    }
    if data.len() - offset < size_of::<u32>() {
        return None;
    }
    Some(
        u32::from(data[offset])
            | (u32::from(data[offset + 1]) << 8)
            | (u32::from(data[offset + 2]) << 16)
            | (u32::from(data[offset + 3]) << 24),
    )
}

fn build_secure_envelope(
    algorithm_id: u16,
    key_id: u32,
    nonce: &[u8],
    ciphertext: &[u8],
    tag: &[u8],
) -> Option<Vec<u8>> {
    if nonce.len() > usize::from(u16::MAX) {
        return None;
    }
    if tag.len() > usize::from(u16::MAX) {
        return None;
    }
    if ciphertext.len() > u32::MAX as usize {
        return None;
    }

    let payload_size = nonce
        .len()
        .checked_add(ciphertext.len())?
        .checked_add(tag.len())?;
    let total_size = SECURE_ENVELOPE_FIXED_HEADER_SIZE.checked_add(payload_size)?;

    let mut out = Vec::with_capacity(total_size);
    out.extend_from_slice(SECURE_ENVELOPE_MAGIC);
    out.push(SECURE_ENVELOPE_VERSION);
    append_u16_le(&mut out, algorithm_id);
    append_u32_le(&mut out, key_id);
    append_u16_le(&mut out, nonce.len() as u16);
    append_u16_le(&mut out, tag.len() as u16);
    append_u32_le(&mut out, ciphertext.len() as u32);
    out.extend_from_slice(nonce);
    out.extend_from_slice(ciphertext);
    out.extend_from_slice(tag);
    Some(out)
}

fn parse_secure_envelope(data: &[u8]) -> Option<SecureEnvelopeView<'_>> {
    if data.len() < SECURE_ENVELOPE_FIXED_HEADER_SIZE {
        return None;
    }
    if &data[..SECURE_ENVELOPE_MAGIC.len()] != SECURE_ENVELOPE_MAGIC {
        return None;
    }
    if data[SECURE_ENVELOPE_OFFSET_VERSION] != SECURE_ENVELOPE_VERSION {
        return None;
    }

    let algorithm_id = read_u16_le(data, SECURE_ENVELOPE_OFFSET_ALGORITHM_ID)?;
    let key_id = read_u32_le(data, SECURE_ENVELOPE_OFFSET_KEY_ID)?;
    let nonce_size = usize::from(read_u16_le(data, SECURE_ENVELOPE_OFFSET_NONCE_SIZE)?);
    let tag_size = usize::from(read_u16_le(data, SECURE_ENVELOPE_OFFSET_TAG_SIZE)?);
    let ciphertext_size = read_u32_le(data, SECURE_ENVELOPE_OFFSET_CIPHERTEXT_SIZE)? as usize;

    let payload_size = nonce_size
        .checked_add(ciphertext_size)?
        .checked_add(tag_size)?;
    let actual_payload_size = data.len().checked_sub(SECURE_ENVELOPE_FIXED_HEADER_SIZE)?;
    if payload_size != actual_payload_size {
        return None;
    }

    let payload = &data[SECURE_ENVELOPE_FIXED_HEADER_SIZE..];
    let nonce_end = nonce_size;
    let ciphertext_end = nonce_end.checked_add(ciphertext_size)?;
    let tag_end = ciphertext_end.checked_add(tag_size)?;
    if tag_end != payload.len() {
        return None;
    }

    Some(SecureEnvelopeView {
        algorithm_id,
        key_id,
        nonce: &payload[..nonce_end],
        ciphertext: &payload[nonce_end..ciphertext_end],
        tag: &payload[ciphertext_end..tag_end],
    })
}

pub struct SecureBuilder<InnerCodec, Cipher, T> {
    bytes: Vec<u8>,
    _marker: PhantomData<(InnerCodec, Cipher, T)>,
}

impl<InnerCodec, Cipher, T> SecureBuilder<InnerCodec, Cipher, T> {
    pub fn new() -> Self {
        Self {
            bytes: Vec::new(),
            _marker: PhantomData,
        }
    }

    pub fn from_bytes(bytes: Vec<u8>) -> Self {
        Self {
            bytes,
            _marker: PhantomData,
        }
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn is_empty(&self) -> bool {
        self.bytes.is_empty()
    }
}

impl<InnerCodec, Cipher, T> SecureBuilder<InnerCodec, Cipher, T>
where
    InnerCodec: Codec<T>,
    Cipher: SecureCipher,
{
    pub fn from_inner(inner: &InnerCodec::Builder) -> Self {
        let plain = InnerCodec::encode(inner);
        if plain.is_empty() {
            return Self::new();
        }

        let mut nonce = Vec::new();
        let mut ciphertext = Vec::new();
        let mut tag = Vec::new();
        if !Cipher::seal(plain, &mut nonce, &mut ciphertext, &mut tag) {
            return Self::new();
        }

        let Some(bytes) = build_secure_envelope(
            Cipher::algorithm_id(),
            Cipher::key_id(),
            &nonce,
            &ciphertext,
            &tag,
        ) else {
            return Self::new();
        };

        Self::from_bytes(bytes)
    }
}

impl<InnerCodec, Cipher, T> Default for SecureBuilder<InnerCodec, Cipher, T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<InnerCodec, Cipher, T> From<Vec<u8>> for SecureBuilder<InnerCodec, Cipher, T> {
    fn from(value: Vec<u8>) -> Self {
        Self::from_bytes(value)
    }
}

impl<InnerCodec, Cipher, T> From<&[u8]> for SecureBuilder<InnerCodec, Cipher, T> {
    fn from(value: &[u8]) -> Self {
        Self::from_bytes(value.to_vec())
    }
}

pub struct SecureCodec<InnerCodec, Cipher>(PhantomData<(InnerCodec, Cipher)>);

impl<T, InnerCodec, Cipher> Codec<T> for SecureCodec<InnerCodec, Cipher>
where
    InnerCodec: Codec<T>,
    Cipher: SecureCipher,
{
    type Message = InnerCodec::Message;
    type Builder = SecureBuilder<InnerCodec, Cipher, T>;

    const CODEC_ID: CodecId = InnerCodec::CODEC_ID;

    fn encode(builder: &Self::Builder) -> &[u8] {
        builder.bytes()
    }

    fn decode(buf: IpcBuffer) -> Self::Message {
        let fail_closed = || InnerCodec::decode(IpcBuffer::new());
        if buf.is_empty() {
            return fail_closed();
        }

        let Some(envelope) = parse_secure_envelope(buf.data()) else {
            return fail_closed();
        };

        if envelope.algorithm_id != Cipher::algorithm_id() {
            return fail_closed();
        }
        if envelope.key_id != Cipher::key_id() {
            return fail_closed();
        }

        let mut plain = Vec::new();
        if !Cipher::open(
            envelope.nonce,
            envelope.ciphertext,
            envelope.tag,
            &mut plain,
        ) {
            return fail_closed();
        }

        InnerCodec::decode(IpcBuffer::from_vec(plain))
    }

    fn verify(message: &Self::Message) -> bool {
        InnerCodec::verify(message)
    }
}

pub type TypedChannelSecure<T, InnerCodec, Cipher> =
    TypedChannelCodec<T, SecureCodec<InnerCodec, Cipher>>;
pub type TypedRouteSecure<T, InnerCodec, Cipher> =
    TypedRouteCodec<T, SecureCodec<InnerCodec, Cipher>>;
