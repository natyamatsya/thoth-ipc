// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Cross-language round-trip harness (C++ endpoint). One binary, a uniform CLI
// contract shared by the Rust and Swift harnesses so the matrix driver
// (tools/xlang-runner) can pair any writer language with any reader language
// on the same ipc::route wire ABI.
//
// Verbs (see tools/xlang-runner/README.md for the scenario each serves):
//   write/read (route), cwrite/cread (multi-writer channel), twrite/tread
//   (typed codec), swrite[-tamper]/sread[-reject|-badkey|-badkeyid] (AEAD
//   envelope), hold/count/probe (reaping), mhold/mtry/mlock + spost/swait +
//   cvwait/cvnotify (sync primitives), caps, clear.
//
// Payload pattern: byte[i] = 'A' + (i % 26). The reader checks length + bytes.
// Secure verbs are compiled unconditionally (the crypto C ABI is always
// linked) and gated at runtime on libipc_secure_crypto_available(), which the
// `caps` verb reports so the matrix driver can plan around it.

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "libipc/ipc.h"
#include "libipc/condition.h"
#include "libipc/mutex.h"
#include "libipc/proto/codecs/protobuf_codec.h"
#include "libipc/proto/codecs/secure_codec.h"
#include "libipc/proto/codecs/secure_openssl_evp_cipher.h"
#include "libipc/proto/typed_route_codec.h"
#include "libipc/semaphore.h"

namespace {

std::vector<char> pattern(std::size_t n) {
    std::vector<char> v(n);
    for (std::size_t i = 0; i < n; ++i) v[i] = char('A' + (i % 26));
    return v;
}

int do_write(const char* name, int count, std::size_t size, std::size_t minrecv) {
    ipc::route w{name, ipc::sender};
    if (!w.valid()) { std::fprintf(stderr, "[cpp] connect(sender) failed\n"); return 3; }
    if (!w.wait_for_recv(minrecv, 5000)) {
        std::fprintf(stderr, "[cpp] fewer than %zu receivers within 5s\n", minrecv);
        return 2;
    }
    auto msg = pattern(size);
    for (int i = 0; i < count; ++i) {
        if (!w.send(msg.data(), msg.size())) { std::fprintf(stderr, "[cpp] send %d failed\n", i); return 4; }
    }
    std::fprintf(stderr, "[cpp] wrote %d x %zuB on '%s'\n", count, size, name);
    return 0;
}

// Multi-writer endpoints on ipc::channel (N writers, N readers) — same wire
// ABI as route, but exercises the multi-producer claim/CAS paths and cc_id
// self-filtering with concurrent senders of different languages.
int do_cwrite(const char* name, int count, std::size_t size) {
    ipc::channel w{name, ipc::sender};
    if (!w.valid()) { std::fprintf(stderr, "[cpp-chan] connect(sender) failed\n"); return 3; }
    if (!w.wait_for_recv(1, 5000)) { std::fprintf(stderr, "[cpp-chan] no receiver within 5s\n"); return 2; }
    auto msg = pattern(size);
    for (int i = 0; i < count; ++i) {
        if (!w.send(msg.data(), msg.size())) { std::fprintf(stderr, "[cpp-chan] send %d failed\n", i); return 4; }
    }
    std::fprintf(stderr, "[cpp-chan] wrote %d x %zuB on '%s'\n", count, size, name);
    return 0;
}

int do_cread(const char* name, int count, std::size_t size) {
    ipc::channel r{name, ipc::receiver};
    if (!r.valid()) { std::fprintf(stderr, "[cpp-chan] connect(receiver) failed\n"); return 3; }
    auto want = pattern(size);
    for (int i = 0; i < count; ++i) {
        ipc::buff_t b = r.recv(8000);
        if (b.empty()) { std::fprintf(stderr, "[cpp-chan] recv %d timed out\n", i); return 5; }
        if (b.size() != size) {
            std::fprintf(stderr, "[cpp-chan] recv %d wrong size: got %zu want %zu\n", i, b.size(), size);
            return 6;
        }
        if (std::memcmp(b.data(), want.data(), size) != 0) {
            std::fprintf(stderr, "[cpp-chan] recv %d payload mismatch\n", i);
            return 7;
        }
    }
    std::fprintf(stderr, "[cpp-chan] read %d x %zuB on '%s' OK\n", count, size, name);
    return 0;
}

int do_read(const char* name, int count, std::size_t size) {
    ipc::route r{name, ipc::receiver};
    if (!r.valid()) { std::fprintf(stderr, "[cpp] connect(receiver) failed\n"); return 3; }
    auto want = pattern(size);
    for (int i = 0; i < count; ++i) {
        ipc::buff_t b = r.recv(8000);
        if (b.empty()) { std::fprintf(stderr, "[cpp] recv %d timed out\n", i); return 5; }
        if (b.size() != size) {
            std::fprintf(stderr, "[cpp] recv %d wrong size: got %zu want %zu\n", i, b.size(), size);
            return 6;
        }
        if (std::memcmp(b.data(), want.data(), size) != 0) {
            std::fprintf(stderr, "[cpp] recv %d payload mismatch\n", i);
            return 7;
        }
    }
    std::fprintf(stderr, "[cpp] read %d x %zuB on '%s' OK\n", count, size, name);
    return 0;
}

// --- Secure (AEAD envelope v1) endpoints -----------------------------------
// The writer seals each pattern payload with the shared xlang test key and
// sends the SIPC envelope; the reader parses/opens it and verifies the
// plaintext. A raw identity inner codec keeps the plaintext byte-exact with
// the other harnesses, so the pairing proves envelope framing + AEAD interop
// and nothing else.

struct raw_builder {
    std::vector<std::uint8_t> bytes_;
};

struct raw_message {
    std::vector<std::uint8_t> bytes_;
};

struct raw_codec {
    // Metadata only: these bytes never travel through the typed layer.
    static constexpr ipc::proto::codec_id id = ipc::proto::codec_id::protobuf;

    using builder_type = raw_builder;

    template <typename T>
    using message_type = raw_message;

    template <typename T>
    static raw_message decode(ipc::buff_t buf) {
        if (buf.empty()) return {};
        auto *d = static_cast<const std::uint8_t *>(buf.data());
        return raw_message{std::vector<std::uint8_t>(d, d + buf.size())};
    }

    static const std::uint8_t *data(const raw_builder &b) noexcept { return b.bytes_.data(); }
    static std::size_t size(const raw_builder &b) noexcept { return b.bytes_.size(); }
};

// Shared xlang test key — must stay byte-identical across the C++, Rust and
// Swift harnesses (same values as the per-language secure codec tests).
struct xlang_test_key {
    static constexpr std::uint32_t key_id() { return 0x0A0B0C0Du; }
    static const std::uint8_t *key_data() {
        static constexpr std::uint8_t bytes[32] = {
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
            0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15,
            0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
        };
        return bytes;
    }
    static std::size_t key_size() { return 32; }
};

// Same key id, different key material: the envelope's key_id check passes and
// the AEAD open itself must fail (fail-closed path).
struct xlang_wrong_key {
    static constexpr std::uint32_t key_id() { return xlang_test_key::key_id(); }
    static const std::uint8_t *key_data() {
        static constexpr std::uint8_t bytes[32] = {
            0xF0, 0xE1, 0xD2, 0xC3, 0xB4, 0xA5, 0x96, 0x87, 0x78, 0x69, 0x5A,
            0x4B, 0x3C, 0x2D, 0x1E, 0x0F, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
            0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        };
        return bytes;
    }
    static std::size_t key_size() { return 32; }
};

// Same key material, different key id: the envelope's key_id check itself must
// reject the message before any AEAD work.
struct xlang_wrongid_key {
    static constexpr std::uint32_t key_id() { return xlang_test_key::key_id() + 1; }
    static const std::uint8_t *key_data() { return xlang_test_key::key_data(); }
    static std::size_t key_size() { return xlang_test_key::key_size(); }
};

template <typename Key>
using aes256gcm_cipher =
    ipc::proto::secure_openssl_evp_cipher<LIBIPC_SECURE_ALG_AES_256_GCM, Key>;
template <typename Key>
using chacha20poly1305_cipher =
    ipc::proto::secure_openssl_evp_cipher<LIBIPC_SECURE_ALG_CHACHA20_POLY1305, Key>;

template <typename Cipher>
int do_swrite(const char* name, int count, std::size_t size, bool tamper) {
    ipc::route w{name, ipc::sender};
    if (!w.valid()) { std::fprintf(stderr, "[cpp-secure] connect(sender) failed\n"); return 3; }
    if (!w.wait_for_recv(1, 5000)) { std::fprintf(stderr, "[cpp-secure] no receiver within 5s\n"); return 2; }
    auto pat = pattern(size);
    raw_builder plain{std::vector<std::uint8_t>(pat.begin(), pat.end())};
    for (int i = 0; i < count; ++i) {
        // Seal per message so every envelope carries a fresh nonce.
        ipc::proto::secure_builder<raw_codec, Cipher> sealed{plain};
        if (sealed.size() == 0) { std::fprintf(stderr, "[cpp-secure] seal %d failed\n", i); return 9; }
        std::vector<std::uint8_t> bytes = sealed.bytes();
        if (tamper) {
            // Flip a bit in the trailing AEAD tag: a correctly keyed reader
            // must still reject every message.
            bytes.back() ^= 0x7F;
        }
        if (!w.send(bytes.data(), bytes.size())) {
            std::fprintf(stderr, "[cpp-secure] send %d failed\n", i);
            return 4;
        }
    }
    std::fprintf(stderr, "[cpp-secure] wrote %d x %zuB %s on '%s'\n",
                 count, size, tamper ? "tamper-sealed" : "sealed", name);
    return 0;
}

template <typename Cipher>
int do_sread(const char* name, int count, std::size_t size, bool expect_open) {
    ipc::route r{name, ipc::receiver};
    if (!r.valid()) { std::fprintf(stderr, "[cpp-secure] connect(receiver) failed\n"); return 3; }
    auto want = pattern(size);
    for (int i = 0; i < count; ++i) {
        ipc::buff_t b = r.recv(8000);
        if (b.empty()) { std::fprintf(stderr, "[cpp-secure] recv %d timed out\n", i); return 5; }
        if (b.size() == size && std::memcmp(b.data(), want.data(), size) == 0) {
            std::fprintf(stderr, "[cpp-secure] recv %d arrived as plaintext\n", i);
            return 10;
        }
        auto msg = ipc::proto::secure_codec<raw_codec, Cipher>::template decode<raw_message>(std::move(b));
        if (!expect_open) {
            if (!msg.bytes_.empty()) {
                std::fprintf(stderr, "[cpp-secure] recv %d opened under the WRONG key\n", i);
                return 11;
            }
            continue;
        }
        if (msg.bytes_.empty()) { std::fprintf(stderr, "[cpp-secure] recv %d open failed\n", i); return 8; }
        if (msg.bytes_.size() != size) {
            std::fprintf(stderr, "[cpp-secure] recv %d wrong size: got %zu want %zu\n", i, msg.bytes_.size(), size);
            return 6;
        }
        if (std::memcmp(msg.bytes_.data(), want.data(), size) != 0) {
            std::fprintf(stderr, "[cpp-secure] recv %d plaintext mismatch\n", i);
            return 7;
        }
    }
    std::fprintf(stderr, "[cpp-secure] %s %d x %zuB on '%s' OK\n",
                 expect_open ? "opened+verified" : "rejected (wrong key)", count, size, name);
    return 0;
}

// --- Typed protocol endpoints (scenario: typed) ----------------------------
// The real typed_route_codec + protobuf_codec path with a hand-rolled
// canonical wire message (field 1 varint seq, field 2 bytes payload — no
// protobuf library needed), verified field-by-field on the reader.

struct xlang_proto_msg {
    std::uint32_t seq_ {0};
    std::vector<std::uint8_t> payload_;

    static std::size_t varint_size(std::uint64_t v) {
        std::size_t n = 1;
        while (v >= 0x80) { v >>= 7; ++n; }
        return n;
    }

    std::size_t ByteSizeLong() const {
        return 1 + varint_size(seq_) + 1 + varint_size(payload_.size()) + payload_.size();
    }

    bool SerializeToArray(void *dst, int size) const {
        if (static_cast<std::size_t>(size) != ByteSizeLong()) return false;
        auto *p = static_cast<std::uint8_t *>(dst);
        auto put_varint = [&p](std::uint64_t v) {
            while (v >= 0x80) { *p++ = static_cast<std::uint8_t>(v) | 0x80; v >>= 7; }
            *p++ = static_cast<std::uint8_t>(v);
        };
        *p++ = 0x08; // field 1, varint
        put_varint(seq_);
        *p++ = 0x12; // field 2, length-delimited
        put_varint(payload_.size());
        std::memcpy(p, payload_.data(), payload_.size());
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
        if (p >= end || *p++ != 0x08) return false;
        if (!get_varint(v)) return false;
        seq_ = static_cast<std::uint32_t>(v);
        if (p >= end || *p++ != 0x12) return false;
        if (!get_varint(v)) return false;
        if (static_cast<std::uint64_t>(end - p) != v) return false;
        payload_.assign(p, end);
        return true;
    }
};

using xlang_typed_route = ipc::proto::typed_route_codec<xlang_proto_msg, ipc::proto::protobuf_codec>;

int do_twrite(const char* name, int count, std::size_t size) {
    xlang_typed_route w{name, ipc::sender};
    if (!w.valid()) { std::fprintf(stderr, "[cpp-typed] connect(sender) failed\n"); return 3; }
    if (!w.raw().wait_for_recv(1, 5000)) { std::fprintf(stderr, "[cpp-typed] no receiver within 5s\n"); return 2; }
    auto pat = pattern(size);
    for (int i = 0; i < count; ++i) {
        xlang_proto_msg m;
        m.seq_ = static_cast<std::uint32_t>(i);
        m.payload_.assign(pat.begin(), pat.end());
        auto b = ipc::proto::protobuf_builder::from_message(m);
        if (b.size() == 0) { std::fprintf(stderr, "[cpp-typed] encode %d failed\n", i); return 9; }
        if (!w.send(b)) { std::fprintf(stderr, "[cpp-typed] send %d failed\n", i); return 4; }
    }
    std::fprintf(stderr, "[cpp-typed] wrote %d x %zuB typed on '%s'\n", count, size, name);
    return 0;
}

int do_tread(const char* name, int count, std::size_t size) {
    xlang_typed_route r{name, ipc::receiver};
    if (!r.valid()) { std::fprintf(stderr, "[cpp-typed] connect(receiver) failed\n"); return 3; }
    auto pat = pattern(size);
    for (int i = 0; i < count; ++i) {
        auto msg = r.recv(8000);
        if (msg.empty()) { std::fprintf(stderr, "[cpp-typed] recv %d timed out\n", i); return 5; }
        if (!msg.verify()) { std::fprintf(stderr, "[cpp-typed] recv %d undecodable\n", i); return 8; }
        if (msg->seq_ != static_cast<std::uint32_t>(i)) {
            std::fprintf(stderr, "[cpp-typed] recv %d wrong seq %u\n", i, msg->seq_);
            return 6;
        }
        if (msg->payload_.size() != size ||
            std::memcmp(msg->payload_.data(), pat.data(), size) != 0) {
            std::fprintf(stderr, "[cpp-typed] recv %d payload mismatch\n", i);
            return 7;
        }
    }
    std::fprintf(stderr, "[cpp-typed] read %d x %zuB typed on '%s' OK\n", count, size, name);
    return 0;
}

bool secure_backend_ready() {
    if (libipc_secure_crypto_available() != 0) return true;
    std::fprintf(stderr, "[cpp-secure] crypto backend unavailable (build with -DLIBIPC_SECURE_OPENSSL=ON)\n");
    return false;
}

// Verb dispatch over key provider x expectation:
//   swrite / swrite-tamper — seal (and optionally corrupt the tag)
//   sread                  — correct key, every open must succeed
//   sread-reject           — correct key, every open must FAIL (tampered or
//                            algorithm-mismatched envelopes)
//   sread-badkey           — wrong key material (same id), must fail in AEAD open
//   sread-badkeyid         — wrong key id, must fail the envelope key_id check
template <template <typename> class Cipher>
int run_secure_alg(const std::string& verb, const char* name, int count, std::size_t size) {
    if (verb == "swrite") return do_swrite<Cipher<xlang_test_key>>(name, count, size, false);
    if (verb == "swrite-tamper") return do_swrite<Cipher<xlang_test_key>>(name, count, size, true);
    if (verb == "sread") return do_sread<Cipher<xlang_test_key>>(name, count, size, true);
    if (verb == "sread-reject") return do_sread<Cipher<xlang_test_key>>(name, count, size, false);
    if (verb == "sread-badkey") return do_sread<Cipher<xlang_wrong_key>>(name, count, size, false);
    if (verb == "sread-badkeyid") return do_sread<Cipher<xlang_wrongid_key>>(name, count, size, false);
    std::fprintf(stderr, "[cpp-secure] unknown verb '%s'\n", verb.c_str());
    return 1;
}

int run_secure(const std::string& verb, const char* name, int count, std::size_t size,
               const std::string& alg) {
    if (!secure_backend_ready()) return 12;
    if (alg == "aes256gcm")
        return run_secure_alg<aes256gcm_cipher>(verb, name, count, size);
    if (alg == "chacha20poly1305")
        return run_secure_alg<chacha20poly1305_cipher>(verb, name, count, size);
    std::fprintf(stderr, "[cpp-secure] unknown algorithm '%s'\n", alg.c_str());
    return 1;
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: %s <write|read|clear> <name> [count] [size]\n", argv[0]);
        return 1;
    }
    std::string verb = argv[1];
    const char* name = argv[2];
    if (verb == "clear") {
        // One clearer for everything a case may have created under <name>:
        // the ring (route and channel share storage) plus the primitives'
        // derived objects (mutex <name>_m, semaphore <name>_s, cond <name>_c).
        ipc::route::clear_storage(name);
        ipc::sync::mutex::clear_storage((std::string(name) + "_m").c_str());
        ipc::sync::semaphore::clear_storage((std::string(name) + "_s").c_str());
        ipc::sync::condition::clear_storage((std::string(name) + "_c").c_str());
        return 0;
    }
    // --- Cross-language sync primitive endpoints (scenario: primitives) ----
    // Lock the mutex and hold it (READY once held), so a peer can probe
    // contention (mtry) or, after SIGKILL, robust dead-holder recovery (mlock).
    if (verb == "mhold") {
        int secs = (argc > 3) ? std::atoi(argv[3]) : 20;
        ipc::sync::mutex m{(std::string(name) + "_m").c_str()};
        if (!m.lock()) { std::fprintf(stderr, "[cpp-prim] lock failed\n"); return 3; }
        std::printf("READY\n");
        std::fflush(stdout);
        std::this_thread::sleep_for(std::chrono::seconds(secs));
        m.unlock();
        return 0;
    }
    if (verb == "mtry") {
        ipc::sync::mutex m{(std::string(name) + "_m").c_str()};
        bool got = false;
        try { got = m.try_lock(); } catch (...) { std::printf("error\n"); return 0; }
        if (got) { m.unlock(); std::printf("acquired\n"); }
        else     { std::printf("busy\n"); }
        return 0;
    }
    if (verb == "mlock") {
        std::uint64_t ms = (argc > 3) ? static_cast<std::uint64_t>(std::atoll(argv[3])) : 5000;
        ipc::sync::mutex m{(std::string(name) + "_m").c_str()};
        if (m.lock(ms)) { m.unlock(); std::printf("acquired\n"); }
        else            { std::printf("timeout\n"); }
        return 0;
    }
    if (verb == "spost") {
        std::uint32_t n = (argc > 3) ? static_cast<std::uint32_t>(std::atoi(argv[3])) : 1;
        ipc::sync::semaphore s{(std::string(name) + "_s").c_str()};
        if (!s.post(n)) { std::fprintf(stderr, "[cpp-prim] post failed\n"); return 3; }
        std::fprintf(stderr, "[cpp-prim] posted %u on '%s_s'\n", n, name);
        return 0;
    }
    // Wait for exactly <n> posts: all must arrive within the timeout, and no
    // surplus token may remain afterwards (count exactness cross-language).
    if (verb == "swait") {
        int n = (argc > 3) ? std::atoi(argv[3]) : 1;
        std::uint64_t ms = (argc > 4) ? static_cast<std::uint64_t>(std::atoll(argv[4])) : 8000;
        ipc::sync::semaphore s{(std::string(name) + "_s").c_str()};
        for (int i = 0; i < n; ++i) {
            if (!s.wait(ms)) { std::fprintf(stderr, "[cpp-prim] sem wait %d timed out\n", i); return 5; }
        }
        if (s.wait(500)) { std::fprintf(stderr, "[cpp-prim] sem had a surplus token after %d waits\n", n); return 6; }
        std::fprintf(stderr, "[cpp-prim] waited %d posts on '%s_s' OK\n", n, name);
        return 0;
    }
    if (verb == "cvwait") {
        std::uint64_t ms = (argc > 3) ? static_cast<std::uint64_t>(std::atoll(argv[3])) : 8000;
        ipc::sync::mutex m{(std::string(name) + "_m").c_str()};
        ipc::sync::condition c{(std::string(name) + "_c").c_str()};
        if (!m.lock()) { std::fprintf(stderr, "[cpp-prim] lock failed\n"); return 3; }
        bool woke = c.wait(m, ms);
        m.unlock();
        if (woke) { std::fprintf(stderr, "[cpp-prim] condition woke on '%s_c'\n", name); return 0; }
        std::fprintf(stderr, "[cpp-prim] condition wait timed out\n");
        return 5;
    }
    // Broadcast repeatedly (the waiter needs only one wake; looping avoids a
    // notify-before-wait race without a side channel).
    if (verb == "cvnotify") {
        ipc::sync::mutex m{(std::string(name) + "_m").c_str()};
        ipc::sync::condition c{(std::string(name) + "_c").c_str()};
        for (int i = 0; i < 30; ++i) {
            if (m.lock()) {
                c.broadcast(m);
                m.unlock();
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        return 0;
    }
    // Report build/runtime capabilities so the matrix driver can plan around a
    // harness lacking a feature instead of hanging on it.
    if (verb == "caps") {
        // "prim" = the sync-primitive verbs (mhold/mtry/mlock/spost/swait/
        // cvwait/cvnotify) are available.
        std::printf("prim typed:protobuf");
        if (libipc_secure_crypto_available() != 0)
            std::printf(" secure secure:aes256gcm secure:chacha20poly1305");
        std::printf("\n");
        return 0;
    }
    // Observe the receiver count WITHOUT side effects (a sender neither claims a
    // receiver slot nor reaps).
    if (verb == "probe") {
        ipc::route s{name, ipc::sender};
        std::printf("%zu\n", s.recv_count());
        return 0;
    }
    // Connect a RECEIVER (reap-on-connect runs), then report the count. Used to
    // check that a dead cross-language receiver was reaped (and a live one wasn't).
    if (verb == "count") {
        ipc::route r{name, ipc::receiver};
        std::printf("%zu\n", r.recv_count());
        return 0;
    }
    // Connect a receiver and hold it (populating the owner table), so a test can
    // SIGKILL this process and check a reaper reclaims the slot.
    if (verb == "hold") {
        int secs = (argc > 3) ? std::atoi(argv[3]) : 30;
        ipc::route r{name, ipc::receiver};
        std::printf("READY\n");
        std::fflush(stdout);
        std::this_thread::sleep_for(std::chrono::seconds(secs));
        return 0;
    }
    if (argc < 5) { std::fprintf(stderr, "write/read need <count> <size>\n"); return 1; }
    int count = std::atoi(argv[3]);
    std::size_t size = static_cast<std::size_t>(std::atoll(argv[4]));
    if (verb == "write") {
        // Optional 6th arg: wait for that many receivers before sending
        // (fanout cases start N readers of mixed languages).
        std::size_t minrecv = (argc > 5) ? static_cast<std::size_t>(std::atoll(argv[5])) : 1;
        return do_write(name, count, size, minrecv ? minrecv : 1);
    }
    if (verb == "read")   return do_read(name, count, size);
    if (verb == "cwrite") return do_cwrite(name, count, size);
    if (verb == "cread")  return do_cread(name, count, size);
    if (verb == "twrite") return do_twrite(name, count, size);
    if (verb == "tread")  return do_tread(name, count, size);
    if (verb == "swrite" || verb == "swrite-tamper" || verb == "sread" ||
        verb == "sread-reject" || verb == "sread-badkey" || verb == "sread-badkeyid") {
        std::string alg = (argc > 5) ? argv[5] : "aes256gcm";
        return run_secure(verb, name, count, size, alg);
    }
    std::fprintf(stderr, "unknown verb '%s'\n", verb.c_str());
    return 1;
}
