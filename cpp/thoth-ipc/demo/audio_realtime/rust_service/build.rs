// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Build script: uses bindgen to generate Rust FFI bindings from
// rt_audio_ffi.h, then links the FFI and ipc libraries.
// CMake sets RT_AUDIO_FFI_LIB_DIR and IPC_LIB_DIR env vars.

fn main() {
    // --- bindgen: generate bindings from the C FFI header ---
    let header = "../rt_audio_ffi.h";
    println!("cargo:rerun-if-changed={header}");

    let bindings = bindgen::Builder::default()
        .header(header)
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .derive_default(true)
        .derive_copy(true)
        .allowlist_function("rt_ffi_.*")
        .allowlist_type("rt_ffi_.*")
        .allowlist_var("RT_FFI_.*")
        .generate()
        .expect("bindgen failed to generate bindings from rt_audio_ffi.h");

    let out_dir = std::env::var("OUT_DIR").unwrap();
    bindings
        .write_to_file(format!("{out_dir}/ffi_bindings.rs"))
        .expect("failed to write ffi_bindings.rs");

    // --- Linking ---

    // Library search paths (set by CMake). Cargo does not see the static
    // libraries change, so relink whenever CMake rebuilt one of them.
    let lib_file = |name: &str| {
        if cfg!(target_os = "windows") { format!("{name}.lib") } else { format!("lib{name}.a") }
    };
    println!("cargo:rerun-if-env-changed=RT_AUDIO_FFI_LIB_DIR");
    println!("cargo:rerun-if-env-changed=IPC_LIB_DIR");
    if let Ok(ffi_dir) = std::env::var("RT_AUDIO_FFI_LIB_DIR") {
        println!("cargo:rustc-link-search=native={ffi_dir}");
        println!("cargo:rerun-if-changed={ffi_dir}/{}", lib_file("rt_audio_ffi"));
    }
    if let Ok(ipc_dir) = std::env::var("IPC_LIB_DIR") {
        println!("cargo:rustc-link-search=native={ipc_dir}");
        println!("cargo:rerun-if-changed={ipc_dir}/{}", lib_file("thoth_ipc"));
    }

    // Link the FFI wrapper and the thoth_ipc library
    println!("cargo:rustc-link-lib=static=rt_audio_ffi");
    println!("cargo:rustc-link-lib=static=thoth_ipc");

    // Windows system libraries needed by thoth_ipc
    if cfg!(target_os = "windows") {
        println!("cargo:rustc-link-lib=dylib=advapi32");
        println!("cargo:rustc-link-lib=dylib=user32");
        println!("cargo:rustc-link-lib=dylib=kernel32");
    }

    // C++ standard library
    if cfg!(target_os = "windows") {
        // MSVC links the C++ runtime automatically
    } else if cfg!(target_os = "macos") {
        println!("cargo:rustc-link-lib=dylib=c++");
    } else {
        println!("cargo:rustc-link-lib=dylib=stdc++");
    }
}
