// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Higher-level protocol layer built on top of the core IPC transport.
// Port of cpp-ipc/include/libipc/proto/.

pub mod codec;
pub mod codecs;
pub mod message;
pub mod process_manager;
pub mod rt_prio;
pub mod service_group;
pub mod service_registry;
pub mod shm_ring;
pub mod typed_channel;
#[cfg(feature = "codec-capnp")]
pub mod typed_channel_capnp;
pub mod typed_channel_codec;
pub mod typed_route;
#[cfg(feature = "codec-capnp")]
pub mod typed_route_capnp;
pub mod typed_route_codec;

#[cfg(feature = "secure-crypto-c")]
pub mod secure_crypto_c;

pub use message::{Builder, Message};
pub use process_manager::{
    force_kill, request_shutdown, shutdown, spawn, spawn_simple, wait_for_exit, ProcessHandle,
    WaitResult,
};
pub use rt_prio::{audio_period_ns, set_realtime_priority};
pub use service_group::{InstanceRole, ManagedInstance, ServiceGroup, ServiceGroupConfig};
pub use service_registry::{ServiceEntry, ServiceRegistry, MAX_NAME_LEN, MAX_SERVICES};
pub use shm_ring::ShmRing;
pub use typed_channel::TypedChannel;
#[cfg(feature = "codec-capnp")]
pub use typed_channel_capnp::TypedChannelCapnp;
pub use typed_channel_codec::TypedChannelCodec;
pub use typed_route::TypedRoute;
#[cfg(feature = "codec-capnp")]
pub use typed_route_capnp::TypedRouteCapnp;
pub use typed_route_codec::TypedRouteCodec;

pub use codecs::secure_codec::{
    SecureBuilder, SecureCipher, SecureCodec, TypedChannelSecure, TypedRouteSecure,
};

#[cfg(feature = "codec-protobuf")]
pub use codecs::protobuf::{ProtobufBuilder, ProtobufCodec, ProtobufMessage, ProtobufWireMessage};

#[cfg(feature = "codec-protobuf-prost")]
pub use codecs::protobuf_prost::ProstProtobufMessage;

#[cfg(feature = "codec-capnp")]
pub use codecs::capnp::{CapnpBuilder, CapnpCodec, CapnpMessage, CapnpWireMessage};

#[cfg(feature = "secure-crypto-c")]
pub use codecs::secure_openssl_evp_cipher::{
    OpenSslEvpKeyProvider, SecureOpenSslEvpBackend, SecureOpenSslEvpCipherAes256Gcm,
    SecureOpenSslEvpCipherChacha20Poly1305,
};
