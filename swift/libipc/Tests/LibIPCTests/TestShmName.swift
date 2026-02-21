// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Tests for ShmName — mirrors rust/libipc/src/shm_name.rs inline tests
// and rust/libipc/tests/test_shm.rs name-related cases.

import Testing
@testable import LibIPC

@Suite("ShmName")
struct TestShmName {

    @Test("FNV-1a of empty string matches known value")
    func fnv1aEmptyString() {
        #expect(fnv1a64([]) == 0xcbf2_9ce4_8422_2325)
    }

    @Test("FNV-1a of known input matches Rust/C++ output")
    func fnv1aKnownInput() {
        // "hello" — verified against C++ and Rust implementations
        let result = fnv1a64("hello".utf8)
        #expect(result == 0xa430_d846_80aa_bd0b)
    }

    @Test("makeShmName prepends slash when missing")
    func prependsSlash() {
        let name = makeShmName("foo")
        #expect(name.hasPrefix("/"))
        #expect(name.contains("foo"))
    }

    @Test("makeShmName keeps existing leading slash")
    func keepsSlash() {
        let name = makeShmName("/bar")
        #expect(name.hasPrefix("/bar"))
    }

    @Test("makeShmName with already-slash input is idempotent")
    func idempotentSlash() {
        let a = makeShmName("/baz")
        let b = makeShmName("/baz")
        #expect(a == b)
    }

    #if os(macOS)
    @Test("makeShmName truncates long names on macOS (PSHMNAMLEN = 31)")
    func truncatesLongName() {
        let long = String(repeating: "x", count: 64)
        let name = makeShmName(long)
        #expect(name.utf8.count <= 31)
        #expect(name.hasPrefix("/"))
    }

    @Test("makeShmName produces same hash for same input")
    func deterministicHash() {
        let long = String(repeating: "a", count: 64)
        let a = makeShmName(long)
        let b = makeShmName(long)
        #expect(a == b)
    }

    @Test("makeShmName produces different hashes for different inputs")
    func differentInputsDifferentHash() {
        let a = makeShmName(String(repeating: "a", count: 64))
        let b = makeShmName(String(repeating: "b", count: 64))
        #expect(a != b)
    }
    #endif
}
