// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
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
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let secure_crypto_root = manifest.join("../../secure-crypto-c");
    let source = secure_crypto_root.join("src/secure_crypto_c.c");
    let include_root = secure_crypto_root.join("include");
    let abi_header = include_root.join("libipc/proto/codecs/secure_crypto_c.h");
    let object = out_dir.join("secure_crypto_c.o");
    let static_lib = out_dir.join("libipc_secure_crypto_c.a");

    let compiler = cc::Build::new().get_compiler();
    let mut compile_cmd = compiler.to_command();
    compile_cmd.arg("-c");
    compile_cmd.arg(&source);
    compile_cmd.arg("-o");
    compile_cmd.arg(&object);

    if compiler.is_like_msvc() {
        compile_cmd.arg(format!("/I{}", include_root.display()));
    } else {
        compile_cmd.arg(format!("-I{}", include_root.display()));
    }

    println!("cargo:rerun-if-changed={}", source.display());
    println!("cargo:rerun-if-changed={}", abi_header.display());
    println!("cargo:rerun-if-env-changed=LIBIPC_OPENSSL_PREFIX");

    if secure_crypto_openssl_enabled() {
        if compiler.is_like_msvc() {
            compile_cmd.arg("/DLIBIPC_SECURE_OPENSSL");
        } else {
            compile_cmd.arg("-DLIBIPC_SECURE_OPENSSL");
        }
        let prefix = std::env::var("LIBIPC_OPENSSL_PREFIX")
            .unwrap_or_else(|_| "/opt/homebrew/opt/openssl@3".to_string());
        if compiler.is_like_msvc() {
            compile_cmd.arg(format!("/I{prefix}/include"));
        } else {
            compile_cmd.arg(format!("-I{prefix}/include"));
        }
        println!("cargo:rustc-link-search=native={prefix}/lib");
        println!("cargo:rustc-link-lib=crypto");
    }

    let compile_status = compile_cmd
        .status()
        .expect("failed to compile secure_crypto_c.c");
    assert!(compile_status.success(), "secure crypto C compile failed");

    let target = std::env::var("TARGET").unwrap_or_default();
    let archive_status = if target.contains("apple-darwin") {
        Command::new("libtool")
            .arg("-static")
            .arg("-o")
            .arg(&static_lib)
            .arg(&object)
            .status()
            .expect("failed to archive secure crypto C library with libtool")
    } else {
        Command::new("ar")
            .arg("crus")
            .arg(&static_lib)
            .arg(&object)
            .status()
            .expect("failed to archive secure crypto C library with ar")
    };
    assert!(archive_status.success(), "secure crypto C archive failed");

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=ipc_secure_crypto_c");
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
    //    the crate: rust/libipc → rust → cpp-ipc → inspiration → repo root).
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

    let schema = Path::new("src/bin/audio_protocol.fbs");
    println!("cargo:rerun-if-changed={}", schema.display());
    println!("cargo:rerun-if-env-changed=FLATC");

    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());

    let flatc = match find_flatc() {
        Some(p) => p,
        None => {
            // flatc not available — emit a placeholder that produces a
            // compile error only if a demo binary that needs it is built.
            let placeholder = out_dir.join("audio_protocol_generated.rs");
            std::fs::write(
                &placeholder,
                "compile_error!(\"flatc not found. Install flatbuffers or set the FLATC env var.\");\n",
            )
            .unwrap();
            println!("cargo:warning=flatc not found; audio_service demo will not compile");
            return;
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
