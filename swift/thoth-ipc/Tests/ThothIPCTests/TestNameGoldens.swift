// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors

import Testing
@testable import ThothIPC

@Suite("NameGoldens")
struct TestNameGoldens {
    /// The shm object names this port builds must be byte-exact with the generated
    /// goldens (canonical binding prefix="", name="xchan"), and thus with every
    /// port — making Swift a checked peer for the shm-name contract.
    @Test func shmNamesMatchGeneratedGoldens() {
        #expect(ringName("", "xchan") == ABI.name_golden_ring)
        #expect(ccIdName("") == ABI.name_golden_cc_id)
        #expect(msgIdName("", "xchan") == ABI.name_golden_msg_id)
        #expect(chunkShmName(prefix: "", chunkSize: 1024) == ABI.name_golden_chunk)
        #expect(livenessName("", "xchan") == ABI.name_golden_liveness)
        // POSIX shortening: the 35-char ring name shortens on macOS (shmNameMax=31).
        #expect(makeShmName(ABI.name_golden_ring) == ABI.name_golden_ring_posix)
    }
}
