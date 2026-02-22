// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Deeper proto tests — port of rust/libipc/tests/test_proto.rs (missing cases)

import Testing
@testable import LibIPC
import Atomics

@Suite("ShmRing depth")
struct TestShmRingDepth {

    // Port of shm_ring_spsc_cross_thread — producer Task writes 20 items, consumer reads all
    @Test("SPSC cross-task — producer writes 20 items, consumer reads all in order")
    func spscCrossTask() async throws {
        let name = "swift_ring_spsc_\(UInt32.random(in: 0..<UInt32.max))"

        let producer = Task.detached {
            var ring = ShmRing<UInt64>(name: name, capacity: 32)
            try ring.openOrCreate()
            for i: UInt64 in 0..<20 {
                while !ring.write(i) { await Task.yield() }
            }
        }

        var ring = ShmRing<UInt64>(name: name, capacity: 32)
        try ring.openOrCreate()
        defer { ring.destroy() }

        var received: [UInt64] = []
        while received.count < 20 {
            var v: UInt64 = 0
            if ring.read(into: &v) { received.append(v) }
            else { await Task.yield() }
        }

        try await producer.value
        #expect(received == Array(0..<20))
    }
}

@Suite("ServiceRegistry depth")
struct TestServiceRegistryDepth {

    // Port of service_registry_shared_across_threads
    @Test("registry shared across tasks — registration visible from another task")
    func sharedAcrossTasks() async throws {
        let domain = "swift_reg_tasks_\(UInt32.random(in: 0..<UInt32.max))"
        let reg = try ServiceRegistry.open(domain: domain)

        await Task.detached {
            _ = reg.register(name: "thread_svc", controlChannel: "ct", replyChannel: "rt")
        }.value

        #expect(reg.find(name: "thread_svc") != nil)
    }
}

@Suite("RtPrio")
struct TestRtPrio {

    // Port of audio_period_ns_48k_256
    @Test("audioPeriodNs — 256 frames at 48 kHz = 5_333_333 ns")
    func audioPeriodNs48k256() {
        #expect(audioPeriodNs(sampleRate: 48_000, framesPerBuffer: 256) == 5_333_333)
    }

    // Port of audio_period_ns_44k_512
    @Test("audioPeriodNs — 512 frames at 44.1 kHz ≈ 11_609_977 ns")
    func audioPeriodNs44k512() {
        #expect(audioPeriodNs(sampleRate: 44_100, framesPerBuffer: 512) == 11_609_977)
    }

    // Port of set_realtime_priority_runs_without_panic
    @Test("setRealtimePriority does not crash")
    func setRealtimePriorityNoCrash() {
        let period = audioPeriodNs(sampleRate: 48_000, framesPerBuffer: 256)
        setRealtimePriority(periodNs: period)
    }
}
