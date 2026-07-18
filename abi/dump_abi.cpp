// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// ABI conformance dumper. Emits the ground-truth ABI values that the canonical
// C++ implementation actually compiles to (sizeof / enum masks / def.h
// constants) as JSON on stdout. The `tools/abi` Rust checker compiles+runs this
// and diffs the output against abi.json, so the language-neutral IDL can never
// silently drift from the deployed C++ wire format.
//
// Scope: the header-reachable surface. The message/chunk wire types (msg_t,
// chunk_t, chunk_info_t) were moved out of ipc.cpp into the private header
// thoth-ipc/msg_layout.h precisely so this probe can measure them as ground
// truth; the ring header, liveness slot, and chunk sizes are dumped here too.
// Values still only reachable from heavier headers (syncabi_stamp, the SIPC
// envelope) stay compile-time static_assert'd against thoth::abi in their own
// TUs (sync_abi.h / secure_codec.h) — see the "abi drift:" asserts there.
// msg_t field offsets are not dumped: it is a non-standard-layout type, so
// offsetof is ill-formed (its size is checked here, offsets stay matrix-verified).
//
// Build (the Rust checker does this for you):
//   c++ -std=c++20 -I cpp/thoth-ipc/include -I cpp/thoth-ipc/src abi/dump_abi.cpp -o dump_abi

#include "thoth-ipc/def.h"
#include "thoth-ipc/prod_cons.h"
#include "thoth-ipc/circ/elem_array.h"
#include "thoth-ipc/msg_layout.h"   // detail::msg_t / chunk_t / chunk_info_t / chunk_header_size
#include "thoth-ipc/liveness.h"     // detail::slot_owner

#include <cstdio>
#include <cstddef>

using namespace thoth;

// DataSize/AlignSize of the ring element = sizeof/alignof(msg_t<64,8>) = 80/8.
using RouteP   = prod_cons_impl<wr<relat::single, relat::multi, trans::broadcast>>;
using ChanP    = prod_cons_impl<wr<relat::multi,  relat::multi, trans::broadcast>>;
using RouteArr = circ::elem_array<RouteP, 80, 8>;
using ChanArr  = circ::elem_array<ChanP, 80, 8>;

int main() {
    std::printf("{\n");
    std::printf("  \"data_length\": %zu,\n",       static_cast<std::size_t>(data_length));
    std::printf("  \"large_msg_align\": %zu,\n",   static_cast<std::size_t>(large_msg_align));
    std::printf("  \"large_msg_cache\": %zu,\n",   static_cast<std::size_t>(large_msg_cache));
    std::printf("  \"ring_size\": %zu,\n",         static_cast<std::size_t>(RouteArr::elem_max));

    std::printf("  \"route_elem.size\": %zu,\n",   sizeof(RouteP::elem_t<80, 8>));
    std::printf("  \"channel_elem.size\": %zu,\n", sizeof(ChanP::elem_t<80, 8>));
    std::printf("  \"route_ring.size\": %zu,\n",   sizeof(RouteArr));
    std::printf("  \"channel_ring.size\": %zu,\n", sizeof(ChanArr));

    std::printf("  \"ring_header.size\": %zu,\n",   static_cast<std::size_t>(RouteArr::head_size));
    std::printf("  \"msg_t.size\": %zu,\n",         sizeof(detail::msg_t<64, 8>));
    std::printf("  \"chunk_header_size\": %zu,\n",  detail::chunk_header_size);
    std::printf("  \"chunk_info_size\": %zu,\n",    sizeof(detail::chunk_info_t));
    std::printf("  \"liveness_slot.size\": %zu,\n", sizeof(detail::slot_owner));

    std::printf("  \"route_ep_mask\": \"0x%016llx\",\n", static_cast<unsigned long long>(RouteP::ep_mask));
    std::printf("  \"route_ep_incr\": \"0x%016llx\",\n", static_cast<unsigned long long>(RouteP::ep_incr));
    std::printf("  \"chan_rc_mask\": \"0x%016llx\",\n",  static_cast<unsigned long long>(ChanP::rc_mask));
    std::printf("  \"chan_ep_mask\": \"0x%016llx\",\n",  static_cast<unsigned long long>(ChanP::ep_mask));
    std::printf("  \"chan_ep_incr\": \"0x%016llx\",\n",  static_cast<unsigned long long>(ChanP::ep_incr));
    std::printf("  \"chan_ic_mask\": \"0x%016llx\",\n",  static_cast<unsigned long long>(ChanP::ic_mask));
    std::printf("  \"chan_ic_incr\": \"0x%016llx\"\n",   static_cast<unsigned long long>(ChanP::ic_incr));
    std::printf("}\n");
    return 0;
}
