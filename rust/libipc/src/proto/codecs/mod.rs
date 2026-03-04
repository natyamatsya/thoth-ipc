// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

pub mod flatbuffers;
pub mod secure_codec;

#[cfg(feature = "codec-protobuf")]
pub mod protobuf;

#[cfg(feature = "codec-protobuf-prost")]
pub mod protobuf_prost;

#[cfg(feature = "codec-capnp")]
pub mod capnp;

#[cfg(feature = "secure-crypto-c")]
pub mod secure_openssl_evp_cipher;
