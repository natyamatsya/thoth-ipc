// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
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

    // Library search paths (set by CMake)
    if let Ok(ffi_dir) = std::env::var("RT_AUDIO_FFI_LIB_DIR") {
        println!("cargo:rustc-link-search=native={ffi_dir}");
    }
    if let Ok(ipc_dir) = std::env::var("IPC_LIB_DIR") {
        println!("cargo:rustc-link-search=native={ipc_dir}");
    }

    // Link the FFI wrapper and the ipc library
    println!("cargo:rustc-link-lib=static=rt_audio_ffi");
    println!("cargo:rustc-link-lib=static=ipc");

    // Windows system libraries needed by ipc
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
