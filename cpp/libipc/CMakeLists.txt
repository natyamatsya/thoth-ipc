# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2018 mutouyun (http://orzz.org)
# SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

cmake_minimum_required(VERSION 3.30)
project(thoth-ipc VERSION 0.1.0)

option(LIBIPC_BUILD_TESTS       "Build all of libipc's own tests."                      OFF)
option(LIBIPC_BUILD_DEMOS       "Build all of libipc's own demos."                      OFF)
option(LIBIPC_BUILD_BENCHMARKS  "Build IPC benchmarks."                                 OFF)
option(LIBIPC_BUILD_SHARED_LIBS "Build shared libraries (DLLs)."                        OFF)
option(LIBIPC_USE_STATIC_CRT    "Set to ON to build with static CRT on Windows (/MT)."  OFF)
option(LIBIPC_CODECOV           "Build with unit test coverage."                        OFF)

# Shorten POSIX shm/semaphore names via hashing when they exceed this limit.
# Set to 0 to disable (zero cost). Auto-enabled on macOS (PSHMNAMLEN = 31).
if(NOT DEFINED LIBIPC_SHM_NAME_MAX)
    if(APPLE)
        set(LIBIPC_SHM_NAME_MAX 31 CACHE STRING "Max POSIX shm name length (0 = no limit).")
    else()
        set(LIBIPC_SHM_NAME_MAX 0  CACHE STRING "Max POSIX shm name length (0 = no limit).")
    endif()
endif()

option(LIBIPC_USE_FILE_SHM      "Use file-backed mmap instead of shm_open (avoids PSHMNAMLEN)." OFF)
option(LIBIPC_BUILD_PROTO       "Build the FlatBuffers-based typed protocol layer and demos." OFF)
option(LIBIPC_CODEC_PROTOBUF    "Enable Protocol Buffers codec scaffolding (Phase B)." OFF)
option(LIBIPC_CODEC_CAPNP       "Enable Cap'n Proto codec scaffolding (Phase C)." OFF)
option(LIBIPC_SECURE_OPENSSL
    "Enable OpenSSL EVP backend for secure codec profile v1 (optional, opt-in)."
    OFF)
option(LIBIPC_APPLE_APP_STORE_SAFE
    "Use only public Mach APIs instead of private __ulock_wait/__ulock_wake (App Store safe, slightly higher latency)."
    OFF)
option(LIBIPC_NOTIFY_FD
    "Opt-in Layer 1: expose a per-receiver readiness handle (native_wait_handle) signalled on enqueue, so channels can be multiplexed on a reactor (epoll/kqueue) instead of one blocking thread each. Zero cost when OFF. macOS uses libnotify; other POSIX uses named FIFOs."
    OFF)
option(LIBIPC_NOTIFY_FIFO
    "Force the portable POSIX FIFO notify backend even on macOS (default there is libnotify). No effect off Apple."
    OFF)
option(LIBIPC_STDEXEC
    "Opt-in Layer 2: ipc::async_recv() senders/receivers (P2300) receive API + a process-global reactor. Requires C++23 and stdexec (provided via find_package, else fetched). Implies LIBIPC_NOTIFY_FD."
    OFF)
# Windows only: the named-object namespace for all shared kernel objects (shm,
# mutexes, semaphores, notify events). Default "Local" (session-local
# BaseNamedObjects); set to "Global" for services / cross-session (session 0),
# or "" for verbatim unqualified names. Must match the Rust `win-global` feature
# at build time. No effect off Windows.
set(LIBIPC_WIN_OBJ_NAMESPACE "Local" CACHE STRING
    "Windows named-object namespace prefix: Local (default), Global, or empty.")

if(LIBIPC_SECURE_OPENSSL)
    set(SECURE_CRYPTO_C_OPENSSL ON CACHE BOOL
        "Enable OpenSSL EVP backend for secure crypto C ABI."
        FORCE)
else()
    set(SECURE_CRYPTO_C_OPENSSL OFF CACHE BOOL
        "Enable OpenSSL EVP backend for secure crypto C ABI."
        FORCE)
endif()
set(SECURE_CRYPTO_C_EXPORT_SET thoth-ipc-targets)
add_subdirectory(${CMAKE_CURRENT_LIST_DIR}/../../secure-crypto-c
                 ${CMAKE_CURRENT_BINARY_DIR}/secure-crypto-c)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -DNDEBUG")
if(NOT MSVC)
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O2")
endif()

# Code coverage support
if (LIBIPC_CODECOV AND NOT MSVC)
    add_compile_options(--coverage)
    add_link_options(-lgcov --coverage)
endif()

if (MSVC)
    add_compile_options(/permissive-)
    set(CompilerFlags
        CMAKE_CXX_FLAGS
        CMAKE_CXX_FLAGS_DEBUG
        CMAKE_CXX_FLAGS_RELEASE
        CMAKE_C_FLAGS
        CMAKE_C_FLAGS_DEBUG
        CMAKE_C_FLAGS_RELEASE
        )
    if (LIBIPC_USE_STATIC_CRT)
        foreach(CompilerFlag ${CompilerFlags})
            string(REPLACE "/MD" "/MT" ${CompilerFlag} "${${CompilerFlag}}")
            string(REPLACE "/MDd" "/MTd" ${CompilerFlag} "${${CompilerFlag}}")
        endforeach()
    else()
        foreach(CompilerFlag ${CompilerFlags})
            string(REPLACE "/MT" "/MD" ${CompilerFlag} "${${CompilerFlag}}")
            string(REPLACE "/MTd" "/MDd" ${CompilerFlag} "${${CompilerFlag}}")
        endforeach()
    endif()
endif()

set(LIBRARY_OUTPUT_PATH    ${CMAKE_BINARY_DIR}/bin)
set(EXECUTABLE_OUTPUT_PATH ${CMAKE_BINARY_DIR}/bin)
set(LIBIPC_PROJECT_DIR     ${PROJECT_SOURCE_DIR})

# Unicode Support
add_definitions(-DUNICODE -D_UNICODE)

# Layer 2 (ipc::async_recv) needs Layer 1's readiness fd and the stdexec library.
# Dependency is injectable: an ambient stdexec (e.g. from vcpkg/Conan/a parent
# build) is used if find_package locates it; otherwise it is fetched at the ref
# Sourcetrail pins. Either way the consumer never has to hard-vendor it.
if(LIBIPC_STDEXEC)
    if(NOT LIBIPC_NOTIFY_FD)
        message(STATUS "LIBIPC_STDEXEC: enabling LIBIPC_NOTIFY_FD (Layer 2 builds on Layer 1).")
        set(LIBIPC_NOTIFY_FD ON CACHE BOOL "" FORCE)
    endif()
    find_package(stdexec CONFIG QUIET)
    if(stdexec_FOUND)
        message(STATUS "LIBIPC_STDEXEC: using stdexec found via find_package.")
    else()
        message(STATUS "LIBIPC_STDEXEC: stdexec not found; fetching NVIDIA/stdexec.")
        include(FetchContent)
        set(STDEXEC_BUILD_TESTS OFF CACHE BOOL "" FORCE)
        set(STDEXEC_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
        FetchContent_Declare(
            stdexec
            GIT_REPOSITORY https://github.com/NVIDIA/stdexec.git
            GIT_TAG 8cfc3f1983d3521b341864074123281011f998c1 # keep in sync with the vcpkg overlay port
        )
        FetchContent_MakeAvailable(stdexec)
    endif()
endif()

add_subdirectory(src)

if (LIBIPC_BUILD_TESTS)
    include(FetchContent)
    FetchContent_Declare(
        googletest
        SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/3rdparty/googletest
    )
    if (LIBIPC_USE_STATIC_CRT)
        set(gtest_force_shared_crt OFF CACHE BOOL "" FORCE)
    else()
        set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
    endif()
    FetchContent_MakeAvailable(googletest)
    add_subdirectory(test)
endif()

if (LIBIPC_BUILD_DEMOS)
    add_subdirectory(demo/chat)
    add_subdirectory(demo/msg_que)
    add_subdirectory(demo/send_recv)
    # Secure codec demo (PCI-style card pipeline); the AEAD backend needs
    # -DLIBIPC_SECURE_OPENSSL=ON, checked at runtime.
    add_subdirectory(demo/secure_pos)
    if (MSVC)
        add_subdirectory(demo/win_service/service)
        add_subdirectory(demo/win_service/client)
    else()
        add_subdirectory(demo/linux_service/service)
        add_subdirectory(demo/linux_service/client)
    endif()
endif()

if (LIBIPC_BUILD_BENCHMARKS)
    add_subdirectory(bench)
endif()

if (LIBIPC_BUILD_PROTO)
    include(FetchContent)
    set(FLATBUFFERS_BUILD_TESTS OFF CACHE BOOL "" FORCE)
    set(FLATBUFFERS_BUILD_FLATC ON CACHE BOOL "" FORCE)
    FetchContent_Declare(
        flatbuffers
        SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/3rdparty/flatbuffers
    )
    FetchContent_MakeAvailable(flatbuffers)

    # The audio demo services are written in C++23 with std::print, which
    # needs GCC >= 14 / recent Clang/MSVC. Probe once here; the demo
    # CMakeLists skip just their service binaries when it is unavailable.
    include(CheckCXXSourceCompiles)
    if(MSVC)
        set(CMAKE_REQUIRED_FLAGS "/std:c++latest")
    else()
        set(CMAKE_REQUIRED_FLAGS "-std=c++23")
    endif()
    check_cxx_source_compiles("
        #include <print>
        int main() { std::println(\"probe\"); }
    " LIBIPC_HAS_STD_PRINT)
    unset(CMAKE_REQUIRED_FLAGS)

    add_subdirectory(demo/audio_service)
    add_subdirectory(demo/audio_realtime)
endif()

install(
    DIRECTORY "include/"
    DESTINATION "include"
)
