// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// ABI conformance dumper. Emits the ground-truth ABI values that the canonical
// C++ implementation actually compiles to (sizeof / enum masks / def.h
// constants) as JSON on stdout. The `tools/abi` Rust checker compiles+runs this
// and diffs the output against abi.json, so the language-neutral IDL can never
// silently drift from the deployed C++ wire format.
//
// Scope: the header-introspectable surface (ring element/total sizes, the rc_
// masks, the core def.h constants). msg_t lives in ipc.cpp (not a header) so its
// field offsets are matrix-verified rather than dumped here. Extend this as the
// IDL adopts more of the surface.
//
// Build (the Rust checker does this for you):
//   c++ -std=c++20 -I cpp/thoth-ipc/include -I cpp/thoth-ipc/src abi/dump_abi.cpp -o dump_abi

#include "thoth-ipc/def.h"
#include "thoth-ipc/prod_cons.h"
#include "thoth-ipc/circ/elem_array.h"

#include <cstdio>
#include <cstddef>

using namespace ipc;

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
