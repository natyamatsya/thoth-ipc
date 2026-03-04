// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

pub mod flatbuffers;

#[cfg(feature = "codec-protobuf")]
pub mod protobuf;

#[cfg(feature = "codec-protobuf-prost")]
pub mod protobuf_prost;
