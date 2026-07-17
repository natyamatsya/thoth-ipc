// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Secure codec demo: a point-of-sale card pipeline (C++ endpoint).
//
// Domain: PCI-DSS P2PE mandates that cardholder data is encrypted at the
// point of capture and that intermediary software (the merchant's POS app)
// is cryptographically unable to read it — that is what keeps the POS out of
// PCI audit scope. On a BROADCAST route every receiver sees every message,
// so application-layer AEAD is the only way to separate privileges on a
// shared bus: the pinpad seals each card event, the POS app sees only opaque
// envelopes (fail-closed), and only the payment gateway holds the key.
//
// Roles are wire-identical with the Rust counterpart
// (rust/libipc/src/bin/demo_secure_pos.rs) — mix languages freely:
//   secure_pos gateway [count]    payment gateway: opens sealed events
//   secure_pos pos     [count]    merchant POS: has NO key, must reject
//   secure_pos pinpad  [count]    card reader: seals + broadcasts events
//
// Start the receivers first; the pinpad waits for both. The AEAD backend is
// compiled in with -DLIBIPC_SECURE_OPENSSL=ON (runtime-checked below).
//
// DEMO KEY ONLY: real deployments provision the key into the pinpad's secure
// element and the gateway's HSM/KMS — it never appears in source.

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "libipc/ipc.h"
#include "libipc/proto/codecs/protobuf_codec.h"
#include "libipc/proto/codecs/secure_codec.h"
#include "libipc/proto/codecs/secure_openssl_evp_cipher.h"
#include "libipc/proto/typed_route_codec.h"

namespace {

constexpr char const bus_name[] = "pos-bus";

// Payment-processor key (DEMO ONLY — see header).
struct processor_key {
    static constexpr std::uint32_t key_id() { return 0x504F5301u; } // "POS",1
    static const std::uint8_t *key_data() {
        static constexpr std::uint8_t bytes[32] = {
            0x8f, 0x3a, 0x11, 0xc4, 0x5e, 0x92, 0x07, 0x6b, 0xd0, 0x24, 0xa9,
            0x71, 0x3c, 0xe8, 0x55, 0x1f, 0x60, 0xbb, 0x2d, 0x94, 0x48, 0x0e,
            0xf3, 0x87, 0x19, 0xc2, 0x6d, 0xaa, 0x35, 0x7e, 0x01, 0xd8,
        };
        return bytes;
    }
    static std::size_t key_size() { return 32; }
};

// What the merchant POS app holds: not the processor key. Same key id (it
// knows WHICH key sealed the event) but no key material — every open must
// fail closed.
struct merchant_no_key {
    static constexpr std::uint32_t key_id() { return processor_key::key_id(); }
    static const std::uint8_t *key_data() {
        static constexpr std::uint8_t bytes[32] = {};
        return bytes;
    }
    static std::size_t key_size() { return 32; }
};

// One card capture. Canonical protobuf wire (field 1 bytes pan, field 2
// varint amount_cents, field 3 varint seq) — byte-identical with Rust.
struct card_event {
    std::string pan_;
    std::uint64_t amount_cents_ {0};
    std::uint32_t seq_ {0};

    static std::size_t varint_size(std::uint64_t v) {
        std::size_t n = 1;
        while (v >= 0x80) { v >>= 7; ++n; }
        return n;
    }

    std::size_t ByteSizeLong() const {
        return 1 + varint_size(pan_.size()) + pan_.size()
             + 1 + varint_size(amount_cents_)
             + 1 + varint_size(seq_);
    }

    bool SerializeToArray(void *dst, int size) const {
        if (static_cast<std::size_t>(size) != ByteSizeLong()) return false;
        auto *p = static_cast<std::uint8_t *>(dst);
        auto put_varint = [&p](std::uint64_t v) {
            while (v >= 0x80) { *p++ = static_cast<std::uint8_t>(v) | 0x80; v >>= 7; }
            *p++ = static_cast<std::uint8_t>(v);
        };
        *p++ = 0x0A; // field 1, length-delimited
        put_varint(pan_.size());
        std::memcpy(p, pan_.data(), pan_.size());
        p += pan_.size();
        *p++ = 0x10; // field 2, varint
        put_varint(amount_cents_);
        *p++ = 0x18; // field 3, varint
        put_varint(seq_);
        return true;
    }

    bool ParseFromArray(const void *src, int size) {
        auto *p = static_cast<const std::uint8_t *>(src);
        auto *end = p + size;
        auto get_varint = [&p, end](std::uint64_t &v) -> bool {
            v = 0;
            int shift = 0;
            while (p < end) {
                std::uint8_t b = *p++;
                v |= static_cast<std::uint64_t>(b & 0x7F) << shift;
                if (!(b & 0x80)) return true;
                shift += 7;
                if (shift > 63) return false;
            }
            return false;
        };
        std::uint64_t v = 0;
        if (p >= end || *p++ != 0x0A) return false;
        if (!get_varint(v)) return false;
        if (static_cast<std::uint64_t>(end - p) < v) return false;
        pan_.assign(reinterpret_cast<const char *>(p), static_cast<std::size_t>(v));
        p += v;
        if (p >= end || *p++ != 0x10) return false;
        if (!get_varint(amount_cents_)) return false;
        if (p >= end || *p++ != 0x18) return false;
        if (!get_varint(v)) return false;
        seq_ = static_cast<std::uint32_t>(v);
        return true;
    }
};

template <typename Key>
using sealed_codec = ipc::proto::secure_codec<
    ipc::proto::protobuf_codec,
    ipc::proto::secure_openssl_evp_cipher<LIBIPC_SECURE_ALG_AES_256_GCM, Key>>;

template <typename Key>
using sealed_bus = ipc::proto::typed_route_codec<card_event, sealed_codec<Key>>;

std::string mask(const std::string &pan) {
    if (pan.size() < 4) return "****";
    return "****-****-****-" + pan.substr(pan.size() - 4);
}

// Card reader: seals every event at the point of capture, then broadcasts.
int pinpad(int count) {
    sealed_bus<processor_key> bus {bus_name, ipc::sender};
    std::printf("[pinpad] waiting for POS + gateway to subscribe...\n");
    if (!bus.raw().wait_for_recv(2, 30000)) return 1;
    for (int seq = 0; seq < count; ++seq) {
        card_event ev;
        ev.pan_ = "4111111111111111";
        ev.amount_cents_ = 1250 + static_cast<std::uint64_t>(seq) * 100;
        ev.seq_ = static_cast<std::uint32_t>(seq);
        // Seal per event: fresh nonce, AEAD tag, envelope v1 framing.
        typename sealed_bus<processor_key>::builder_type sealed {
            ipc::proto::protobuf_builder::from_message(ev)};
        if (sealed.size() == 0) { std::fprintf(stderr, "[pinpad] seal failed\n"); return 1; }
        if (!bus.send(sealed)) { std::fprintf(stderr, "[pinpad] send failed\n"); return 1; }
        std::printf("[pinpad] captured %s for %lluc -> sealed event #%d (%zuB on the bus)\n",
                    mask(ev.pan_).c_str(),
                    static_cast<unsigned long long>(ev.amount_cents_), seq, sealed.size());
        std::this_thread::sleep_for(std::chrono::milliseconds(400));
    }
    std::printf("[pinpad] done.\n");
    return 0;
}

// Payment gateway: the only key holder — opens and processes each event.
int gateway(int count) {
    sealed_bus<processor_key> bus {bus_name, ipc::receiver};
    std::printf("[gateway] subscribed (holds the processor key).\n");
    for (int i = 0; i < count; ++i) {
        auto msg = bus.recv(30000);
        const card_event *ev = msg.root();
        if (ev == nullptr) {
            std::fprintf(stderr, "[gateway] REJECTED an event (bad envelope?)\n");
            return 1;
        }
        std::printf("[gateway] authorised %s for %lluc (event #%u)\n",
                    mask(ev->pan_).c_str(),
                    static_cast<unsigned long long>(ev->amount_cents_), ev->seq_);
    }
    std::printf("[gateway] done.\n");
    return 0;
}

// Merchant POS app: subscribed to the same bus, but with no key material —
// AEAD must fail closed on every event. It can meter/route the opaque
// envelopes, which is exactly what keeps it out of PCI scope.
int pos(int count) {
    sealed_bus<merchant_no_key> bus {bus_name, ipc::receiver};
    std::printf("[pos] subscribed (no processor key).\n");
    for (int i = 0; i < count; ++i) {
        auto msg = bus.recv(30000);
        if (msg.root() != nullptr) {
            std::fprintf(stderr, "[pos] SECURITY FAILURE: opened a sealed event without the key!\n");
            return 1;
        }
        std::printf("[pos] event #%d: sealed envelope observed — cannot decrypt (as required)\n", i);
    }
    std::printf("[pos] done.\n");
    return 0;
}

} // namespace

int main(int argc, char **argv) {
    if (libipc_secure_crypto_available() == 0) {
        std::fprintf(stderr, "crypto backend unavailable — build with -DLIBIPC_SECURE_OPENSSL=ON\n");
        return 2;
    }
    std::string role = (argc > 1) ? argv[1] : "";
    int count = (argc > 2) ? std::atoi(argv[2]) : 5;
    if (role == "pinpad") return pinpad(count);
    if (role == "gateway") return gateway(count);
    if (role == "pos") return pos(count);
    std::fprintf(stderr, "usage: secure_pos <pinpad|gateway|pos> [count]\n");
    return 2;
}
