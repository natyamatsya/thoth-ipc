# thoth-ipc — Cross-Language IPC Library

[![MIT licensed](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Build Status](https://github.com/natyamatsya/thoth-ipc/actions/workflows/c-cpp.yml/badge.svg)](https://github.com/natyamatsya/thoth-ipc/actions)

A high-performance inter-process communication library using shared memory on Linux/Windows/macOS/FreeBSD.
Binary-compatible primitives implemented in multiple languages — all sharing the same wire format and shm layout.

> **Fork notice:** thoth-ipc is a fork of [cpp-ipc](https://github.com/mutouyun/cpp-ipc) by mutouyun,
> branched at upstream v1.4.1. thoth-ipc versioning starts independently at 0.1.0.
> The original C++ transport core is preserved unmodified; this fork adds a pure Rust port,
> a Swift package, a pluggable typed protocol layer (FlatBuffers/Cap'n Proto/Protobuf),
> an opt-in secure codec, cross-language sync ABI alignment, and macOS-specific optimisations.

## Repository layout

```
cpp/libipc/    — C++ library (upstream core, extended)
rust/libipc/   — Pure Rust port (feature-complete, 242 tests)
swift/libipc/  — Swift package (work in progress)
```

## Language implementations

### C++ — [`cpp/libipc/`](cpp/libipc/)

[![Build Status](https://github.com/natyamatsya/thoth-ipc/actions/workflows/c-cpp.yml/badge.svg)](https://github.com/natyamatsya/thoth-ipc/actions)

Based on the original [cpp-ipc](https://github.com/mutouyun/cpp-ipc) library. See [`cpp/libipc/README.md`](cpp/libipc/README.md) for full documentation.

- Compilers with C++17 support (msvc-2017/gcc-7/clang-4)
- No dependencies except STL
- Lock-free or lightweight spin-lock only
- `ipc::route` (1 writer, N readers) and `ipc::channel` (N writers, N readers)

### Rust — [`rust/libipc/`](rust/libipc/)

Pure Rust crate, binary-compatible with the C++ library. All primitives ported: shm, mutex, semaphore, condition, buffer, channel, waiter, circ, plus a typed protocol layer (FlatBuffers), service registry, process manager, and real-time audio demos.

```sh
cd rust/libipc && cargo test
```

### Swift — [`swift/libipc/`](swift/libipc/)

Swift Package Manager package — work in progress.

```sh
cd swift/libipc && swift build
```

## License

MIT. Original library © 2018 mutouyun. macOS port, Rust/Swift implementations, protocol layer, and orchestration utilities © 2025–2026 natyamatsya contributors.

## A high-performance inter-process communication library using shared memory on Linux/Windows/macOS/FreeBSD

- Compilers with C++17 support are recommended (msvc-2017/gcc-7/clang-4)
- No other dependencies except STL.
- Only lock-free or lightweight spin-lock is used.
- Circular array is used as the underline data structure.
- `ipc::route` supports single write and multiple read. `ipc::channel` supports multiple read and write. (**Note: currently, a channel supports up to 32 receivers, but there is no such a limit for the sender.**)
- Broadcasting is used by default, but user can choose any read/ write combinations.
- No long time blind wait. (Semaphore will be used after a certain number of retries.)
- [Vcpkg](https://github.com/microsoft/vcpkg/blob/master/README.md) way of installation is supported. E.g. `vcpkg install cpp-ipc`

> **⚠️ Prototype status** — The following components are unreleased prototypes
> under active development and are **not yet used in production**. APIs,
> protocols, and data layouts may change without notice.
>
> - `libipc/proto/` — typed protocol layer, service registry, process manager, shm_ring, RT priority
> - `demo/audio_service/` — FlatBuffers audio service demo with orchestration
> - `demo/audio_realtime/` — real-time audio demo with lock-free ring buffer and warm standby failover
> - `demo/audio_realtime/rust_service/` — Rust 2024 edition service via C FFI / bindgen
>
> The core transport library (`ipc::route`, `ipc::channel`, shared memory
> primitives) is stable.

## Usage

See: [Wiki](https://github.com/mutouyun/cpp-ipc/wiki)

## Performance

### Windows

 Environment | Value
 ------ | ------
 CPU | AMD Ryzen 9 7950X3D 16-Core (32 threads)
 RAM | 64 GB
 OS | Windows 11 Pro x64
 Compiler | MSVC 19.50 (Visual Studio 18 2026), Release build

All values in **µs/datum** (lower is better).

#### `ipc::route` — 1 sender, N receivers (random 2–256 bytes × 100 000)

 Receivers | µs/datum
 ------ | ------
 1 | **1.80**
 2 | 25.79
 4 | 48.23
 8 | 94.88

#### `ipc::channel` — multiple patterns (random 2–256 bytes × 100 000)

 Threads | 1→N | N→1 | N→N
 ------ | ------ | ------ | ------
 1 | **2.59** | **2.60** | **2.58**
 2 | 26.47 | 10.00 | 31.67
 4 | 51.16 | 10.59 | 65.29
 8 | 93.04 | 10.75 | 127.06

### macOS

 Environment | Value
 ------ | ------
 CPU | Apple Silicon (arm64), 12 threads
 OS | macOS (Darwin)
 Compiler | Apple Clang (C++17), Release build
 Peak throughput | **~7.2 GB/s** (128 B – 16 KB messages, `msg_que` demo)

All values in **µs/datum** (lower is better).

#### `ipc::route` — 1 sender, N receivers (random 2–256 bytes × 100 000)

 Receivers | µs/datum
 ------ | ------
 1 | **0.70**
 2 | 0.72
 4 | 2.05
 8 | 4.76

#### `ipc::channel` — multiple patterns (random 2–256 bytes × 100 000)

 Threads | 1→N | N→1 | N→N
 ------ | ------ | ------ | ------
 1 | **0.51** | **0.50** | **0.50**
 2 | 0.66 | 0.58 | 0.91
 4 | 2.12 | 0.84 | 2.63
 8 | 4.80 | 1.02 | 5.62

> 💡 Reproduce with: `cmake -B build -DLIBIPC_BUILD_BENCHMARKS=ON -DCMAKE_BUILD_TYPE=Release && cmake --build build --target bench_ipc && ./build/bin/bench_ipc`

Raw data: [performance.xlsx](performance.xlsx) &nbsp;|&nbsp; Benchmark source: [bench/](bench/)

## Documentation

- **[macOS Technical Notes](doc/macos-technical-notes.md)** — platform-specific implementation details for macOS (semaphores, mutexes, shared memory)
- **[Windows Technical Notes](doc/windows-technical-notes.md)** — platform-specific implementation details for Windows (MSVC conformance, process management, thread priority)
- **[macOS Deployment & Distribution](doc/macos-deployment.md)** — code signing, notarization, sandbox restrictions, and XPC alternatives for production shipping
- **[Typed Protocol Layer](doc/proto-layer.md)** *(prototype)* — FlatBuffers-based typed channels and routes for type-safe, zero-copy IPC messaging
- **[Process Orchestration & Discovery](doc/orchestration.md)** *(prototype)* — service registry, process management, redundant service groups with automatic failover
- **[Audio Service Demo](demo/audio_service/)** *(prototype)* — complete example with FlatBuffers protocol, redundancy, crash recovery, and auto-reconnect
- **[Real-Time Audio Demo](demo/audio_realtime/)** *(prototype)* — dropout-free design with lock-free ring buffer, RT thread priority, heartbeat watchdog, and warm standby failover
- **[Cross-Language Services via C FFI](doc/rust-services.md)** *(prototype)* — Rust 2024 edition service using bindgen-generated FFI bindings to the proto layer, with CMake auto-detection

## License

This project is licensed under the [MIT License](LICENSE).

The original library is copyright © 2018 mutouyun. The macOS port, protocol
layer, orchestration utilities, and documentation are copyright © 2025–2026
natyamatsya contributors. Both are distributed under the same MIT license.

All source files carry [SPDX](https://spdx.dev/) headers that identify the
license and copyright holders:

```text
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2018 mutouyun (http://orzz.org)          ← upstream code
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors       ← additions
```

Files created entirely by natyamatsya contributors carry only the natyamatsya
copyright line. Modified upstream files carry both.

## Reference

- [Lock-Free Data Structures | Dr Dobb's](http://www.drdobbs.com/lock-free-data-structures/184401865)
- [Yet another implementation of a lock-free circular array queue | CodeProject](https://www.codeproject.com/Articles/153898/Yet-another-implementation-of-a-lock-free-circular)
- [Lock-Free 编程 | 匠心十年 - 博客园](http://www.cnblogs.com/gaochundong/p/lock_free_programming.html)
- [无锁队列的实现 | 酷 壳 - CoolShell](https://coolshell.cn/articles/8239.html)
- [Implementing Condition Variables with Semaphores](https://www.microsoft.com/en-us/research/wp-content/uploads/2004/12/ImplementingCVs.pdf)

------

## 使用共享内存的跨平台（Linux/Windows/macOS/FreeBSD，x86/x64/ARM）高性能IPC通讯库

- 推荐支持C++17的编译器（msvc-2017/gcc-7/clang-4）
- 除STL外，无其他依赖
- 无锁（lock-free）或轻量级spin-lock
- 底层数据结构为循环数组（circular array）
- `ipc::route`支持单写多读，`ipc::channel`支持多写多读【**注意：目前同一条通道最多支持32个receiver，sender无限制**】
- 默认采用广播模式收发数据，支持用户任意选择读写方案
- 不会长时间忙等（重试一定次数后会使用信号量进行等待），支持超时
- 支持[Vcpkg](https://github.com/microsoft/vcpkg/blob/master/README_zh_CN.md)方式安装，如`vcpkg install cpp-ipc`

## 使用方法

详见：[Wiki](https://github.com/mutouyun/cpp-ipc/wiki)

## 性能

| 环境     | 值                               |
| -------- | -------------------------------- |
| 设备     | 联想 ThinkPad T450               |
| CPU      | 英特尔® Core™ i5-4300U @ 2.5 GHz |
| 内存     | 16 GB                            |
| 操作系统 | Windows 7 Ultimate x64           |
| 编译器   | MSVC 2017 15.9.4                 |

单元测试和Benchmark测试: [test](test)  
性能数据: [performance.xlsx](performance.xlsx)

## 参考

- [Lock-Free Data Structures | Dr Dobb's](http://www.drdobbs.com/lock-free-data-structures/184401865)
- [Yet another implementation of a lock-free circular array queue | CodeProject](https://www.codeproject.com/Articles/153898/Yet-another-implementation-of-a-lock-free-circular)
- [Lock-Free 编程 | 匠心十年 - 博客园](http://www.cnblogs.com/gaochundong/p/lock_free_programming.html)
- [无锁队列的实现 | 酷 壳 - CoolShell](https://coolshell.cn/articles/8239.html)
- [Implementing Condition Variables with Semaphores](https://www.microsoft.com/en-us/research/wp-content/uploads/2004/12/ImplementingCVs.pdf)
