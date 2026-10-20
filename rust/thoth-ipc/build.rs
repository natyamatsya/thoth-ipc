// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Build script: runs `flatc --rust` on the audio_protocol.fbs schema and
// writes the generated code to $OUT_DIR.  The demo binaries include! it from
// there.  The generated file is never checked in — it lives only in target/.
//
// flatc search order:
//   1. FLATC env var (explicit override)
//   2. PATH
//   3. Known vcpkg build-tree location relative to CARGO_MANIFEST_DIR

use std::path::{Path, PathBuf};
use std::process::Command;

fn secure_crypto_enabled() -> bool {
    std::env::var_os("CARGO_FEATURE_SECURE_CRYPTO_C").is_some()
}

fn secure_crypto_openssl_enabled() -> bool {
    std::env::var_os("CARGO_FEATURE_SECURE_CRYPTO_OPENSSL").is_some()
}

fn compile_secure_crypto_c() {
    if !secure_crypto_enabled() {
        return;
    }

    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let secure_crypto_root = manifest.join("../../secure-crypto-c");
    let source = secure_crypto_root.join("src/secure_crypto_c.c");
    let include_root = secure_crypto_root.join("include");
    let abi_header = include_root.join("thoth-ipc/proto/codecs/secure_crypto_c.h");

    println!("cargo:rerun-if-changed={}", source.display());
    println!("cargo:rerun-if-changed={}", abi_header.display());
    println!("cargo:rerun-if-env-changed=THOTH_IPC_OPENSSL_PREFIX");

    // cc::Build compiles and archives with the target's own toolchain --
    // cl.exe + lib.exe for MSVC, which the hand-rolled `-c ... -o` and
    // `ar`/`libtool` invocations this replaced did not speak -- and emits the
    // link-search / link-lib directives for the archive itself.
    let mut build = cc::Build::new();
    build.file(&source).include(&include_root);
    // Apple's ld rejects archives from GNU ar ("not 8-byte aligned"), which cc
    // would pick up from PATH where binutils is installed; this used to call
    // libtool for the same reason. An explicit AR still wins.
    let target = std::env::var("TARGET").unwrap_or_default();
    if target.contains("apple") && std::env::var_os("AR").is_none() {
        build.archiver("/usr/bin/ar");
    }

    if secure_crypto_openssl_enabled() {
        build.define("THOTH_IPC_SECURE_OPENSSL", None);
        let prefix = std::env::var("THOTH_IPC_OPENSSL_PREFIX")
            .unwrap_or_else(|_| "/opt/homebrew/opt/openssl@3".to_string());
        build.include(format!("{prefix}/include"));
        println!("cargo:rustc-link-search=native={prefix}/lib");
        if build.get_compiler().is_like_msvc() {
            // Win64 OpenSSL 3 ships import libs as libcrypto.lib, in either
            // lib/ or lib/VC/x64/MD depending on the installer.
            println!("cargo:rustc-link-search=native={prefix}/lib/VC/x64/MD");
            println!("cargo:rustc-link-lib=libcrypto");
        } else {
            println!("cargo:rustc-link-lib=crypto");
        }
    }

    build.compile("thoth_ipc_secure_crypto_c");
}

fn find_flatc() -> Option<PathBuf> {
    // 1. Explicit override.
    if let Ok(p) = std::env::var("FLATC") {
        let p = PathBuf::from(p);
        if p.is_file() {
            return Some(p);
        }
    }

    // 2. PATH.
    if let Ok(output) = Command::new("flatc").arg("--version").output() {
        if output.status.success() {
            return Some(PathBuf::from("flatc"));
        }
    }

    // 3. vcpkg build tree relative to the workspace root (two levels up from
    //    the crate: rust/thoth-ipc → rust → cpp-ipc → inspiration → repo root).
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let candidates = [
        // vcpkg installed tools
        manifest.join("../../../../vcpkg/packages/flatbuffers_arm64-osx/tools/flatbuffers/flatc"),
        manifest.join("../../../../vcpkg/packages/flatbuffers_x64-osx/tools/flatbuffers/flatc"),
        manifest.join("../../../../vcpkg/packages/flatbuffers_x64-linux/tools/flatbuffers/flatc"),
        manifest
            .join("../../../../vcpkg/packages/flatbuffers_x64-windows/tools/flatbuffers/flatc.exe"),
        // vcpkg build tree (release build)
        manifest.join("../../../../vcpkg/buildtrees/flatbuffers/arm64-osx-rel/flatc"),
        manifest.join("../../../../vcpkg/buildtrees/flatbuffers/x64-linux-rel/flatc"),
    ];
    for c in &candidates {
        if c.is_file() {
            return Some(c.clone());
        }
    }

    None
}

fn main() {
    compile_secure_crypto_c();

    // The FlatBuffers codegen is only needed by the audio demo bins, which
    // are gated behind the `audio-demos` feature (required-features), so a
    // feature-less `cargo build --bins` never touches flatc.
    if std::env::var_os("CARGO_FEATURE_AUDIO_DEMOS").is_none() {
        return;
    }

    let schema = Path::new("src/bin/audio_protocol.fbs");
    println!("cargo:rerun-if-changed={}", schema.display());
    println!("cargo:rerun-if-env-changed=FLATC");

    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());

    let flatc = match find_flatc() {
        Some(p) => p,
        None => {
            // The feature was requested explicitly, so a missing flatc is a
            // hard, immediately-actionable error.
            panic!(
                "feature `audio-demos` needs the FlatBuffers compiler: \
                 install flatbuffers or set the FLATC env var"
            );
        }
    };

    let status = Command::new(&flatc)
        .args(["--rust", "--gen-all", "-o"])
        .arg(&out_dir)
        .arg(schema)
        .status()
        .expect("failed to run flatc");

    assert!(status.success(), "flatc failed with status {status}");

    // flatc writes `audio_protocol_generated.rs` directly into OUT_DIR.
    // Verify it exists.
    let generated = out_dir.join("audio_protocol_generated.rs");
    assert!(
        generated.exists(),
        "flatc ran but did not produce {generated:?}"
    );
}
