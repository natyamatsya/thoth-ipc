# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

project(audio_realtime_demo)

add_executable(rt_audio_host host.cpp)
target_include_directories(rt_audio_host PRIVATE
    ${LIBIPC_PROJECT_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(rt_audio_host PRIVATE ipc)

add_executable(rt_audio_service service.cpp)
target_include_directories(rt_audio_service PRIVATE
    ${LIBIPC_PROJECT_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(rt_audio_service PRIVATE ipc)

# The service process is compiled as C++23 to demonstrate that process
# separation allows each component to use a different language standard.
# The host remains at the project default (C++17).
set_target_properties(rt_audio_service PROPERTIES
    CXX_STANDARD 23
    CXX_STANDARD_REQUIRED ON)

set_target_properties(rt_audio_host rt_audio_service PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

# --- C FFI wrapper (static lib for Rust and other languages) ---

add_library(rt_audio_ffi STATIC rt_audio_ffi.cpp)
target_include_directories(rt_audio_ffi PRIVATE
    ${LIBIPC_PROJECT_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(rt_audio_ffi PRIVATE ipc)
set_target_properties(rt_audio_ffi PROPERTIES
    ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)

# --- Rust service (built when cargo is detected) ---

find_program(CARGO_EXECUTABLE cargo)
if(CARGO_EXECUTABLE)
    message(STATUS "Found cargo: ${CARGO_EXECUTABLE} — Rust service will be built")

    if(CMAKE_BUILD_TYPE STREQUAL "Debug" OR CMAKE_CFG_INTDIR STREQUAL "Debug")
        set(RUST_PROFILE "debug")
        set(CARGO_BUILD_FLAGS "")
    else()
        set(RUST_PROFILE "release")
        set(CARGO_BUILD_FLAGS "--release")
    endif()

    set(RUST_SRC_DIR  ${CMAKE_CURRENT_SOURCE_DIR}/rust_service)
    set(RUST_OUT_DIR  ${CMAKE_BINARY_DIR}/rust)
    if(WIN32)
        set(RUST_EXE ${RUST_OUT_DIR}/${RUST_PROFILE}/rt_audio_service_rs.exe)
    else()
        set(RUST_EXE ${RUST_OUT_DIR}/${RUST_PROFILE}/rt_audio_service_rs)
    endif()

    add_custom_command(
        OUTPUT  ${RUST_EXE}
        COMMAND ${CMAKE_COMMAND} -E env
            "RT_AUDIO_FFI_LIB_DIR=$<TARGET_FILE_DIR:rt_audio_ffi>"
            "IPC_LIB_DIR=$<TARGET_FILE_DIR:ipc>"
            ${CARGO_EXECUTABLE} build ${CARGO_BUILD_FLAGS}
                --target-dir ${RUST_OUT_DIR}
                --manifest-path ${RUST_SRC_DIR}/Cargo.toml
        DEPENDS rt_audio_ffi ipc
                ${RUST_SRC_DIR}/Cargo.toml
                ${RUST_SRC_DIR}/build.rs
                ${RUST_SRC_DIR}/src/main.rs
        COMMENT "Building Rust rt_audio_service_rs"
        VERBATIM
    )
    add_custom_target(rt_audio_service_rs ALL DEPENDS ${RUST_EXE})

    # Copy the Rust binary next to the C++ binaries
    add_custom_command(TARGET rt_audio_service_rs POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${RUST_EXE}
            ${CMAKE_BINARY_DIR}/bin/$<CONFIG>/
        COMMENT "Copying rt_audio_service_rs to bin/"
    )
else()
    message(STATUS "cargo not found — Rust service will not be built")
endif()
