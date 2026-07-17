// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Builds the Zig `xlang` cross-language ABI harness. Point the matrix runner at
// zig-out/bin/xlang via XLANG_ZIG_BIN (see tools/xlang-ci.toml).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "xlang",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/xlang.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    // `zig build test` runs the byte-exact ABI unit tests (name shortening,
    // calc_size, calc_chunk_size, FNV-1a golden vectors).
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run ABI unit tests").dependOn(&run_tests.step);
}
