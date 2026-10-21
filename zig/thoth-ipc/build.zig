// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Builds the Zig `xlang` cross-language ABI harness. Point the matrix runner at
// zig-out/bin/xlang via XLANG_ZIG_BIN (see tools/xlang-ci.toml).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Importable module surface (`@import("thoth-ipc")`) for consumers such as
    // sourcetrail_zig_indexer: ShmHandle / Mutex / makeShmName. See src/root.zig.
    _ = b.addModule("thoth-ipc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

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

    // The demos (see cpp/thoth-ipc/demo and tools/demos.toml): each role is
    // wire-identical with the C++, Rust and Swift ports, so they mix across
    // languages. Built into zig-out/bin; their unit tests join `zig build test`.
    const demos = [_][]const u8{
        "demo_channel_aggregator", // multi-writer thoth::channel fan-in
        "demo_pipeline", // thoth::route hops, one process per stage
        "demo_bounded_buffer", // shm ring + named mutex + two semaphores
        "demo_secure_pos", // AEAD-sealed broadcast bus
        "demo_msg_que", // thoth::route, 128 B - 16 KB messages (fragmented)
    };
    var demo_tests: [demos.len]*std.Build.Step.Compile = undefined;
    for (demos, &demo_tests) |name, *t| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        b.installArtifact(b.addExecutable(.{ .name = name, .root_module = module }));
        t.* = b.addTest(.{ .root_module = module });
    }

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
    const test_step = b.step("test", "Run the unit tests");
    test_step.dependOn(&run_tests.step);
    for (demo_tests) |t| test_step.dependOn(&b.addRunArtifact(t).step);
}
