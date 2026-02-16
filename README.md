# cpp-ipc (libipc) - C++ IPC Library

[![MIT licensed](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/mutouyun/cpp-ipc/blob/master/LICENSE)
[![Build Status](https://github.com/mutouyun/cpp-ipc/actions/workflows/c-cpp.yml/badge.svg)](https://github.com/mutouyun/cpp-ipc/actions)
[![CodeCov](https://codecov.io/github/mutouyun/cpp-ipc/graph/badge.svg?token=MNOAOLNELH)](https://codecov.io/github/mutouyun/cpp-ipc)
[![Build status](https://ci.appveyor.com/api/projects/status/github/mutouyun/cpp-ipc?branch=master&svg=true)](https://ci.appveyor.com/project/mutouyun/cpp-ipc)
[![Vcpkg package](https://img.shields.io/badge/Vcpkg-package-blueviolet)](https://github.com/microsoft/vcpkg/tree/master/ports/cpp-ipc)

## A high-performance inter-process communication library using shared memory on Linux/Windows/macOS/FreeBSD

* Compilers with C++17 support are recommended (msvc-2017/gcc-7/clang-4)
* No other dependencies except STL.
* Only lock-free or lightweight spin-lock is used.
* Circular array is used as the underline data structure.
* `ipc::route` supports single write and multiple read. `ipc::channel` supports multiple read and write. (**Note: currently, a channel supports up to 32 receivers, but there is no such a limit for the sender.**)
* Broadcasting is used by default, but user can choose any read/ write combinations.
* No long time blind wait. (Semaphore will be used after a certain number of retries.)
* [Vcpkg](https://github.com/microsoft/vcpkg/blob/master/README.md) way of installation is supported. E.g. `vcpkg install cpp-ipc`

## Usage

See: [Wiki](https://github.com/mutouyun/cpp-ipc/wiki)

## Performance

### Windows

 Environment | Value
 ------ | ------
 Device | Lenovo ThinkPad T450
 CPU | Intel® Core™ i5-4300U @ 2.5 GHz
 RAM | 16 GB
 OS | Windows 7 Ultimate x64
 Compiler | MSVC 2017 15.9.9

All values in **µs/datum** (lower is better). "@ 4" = 4-core run, "@ 1" = single-core run.

#### `ipc::route` — 1 sender, N receivers (random 2–256 bytes × 100 000)

 Receivers | @ 4 cores | @ 1 core
 ------ | ------ | ------
 1 | 1.46 | 0.77
 2 | 4.06 | 1.08
 4 | 1.95 | 1.76
 8 | 2.03 | 2.98
 16 | 3.28 | 5.68

#### `ipc::channel` — multiple patterns (random 2–256 bytes × 100 000)

 Threads | 1-N @ 4 | N-1 @ 4 | N-N @ 4 | 1-N @ 1 | N-1 @ 1 | N-N @ 1
 ------ | ------ | ------ | ------ | ------ | ------ | ------
 1 | 0.67 | 0.89 | 0.65 | 0.87 | 0.73 | 0.73
 2 | 0.84 | 0.54 | 0.72 | 1.17 | 0.73 | 1.08
 4 | 1.16 | 0.75 | 1.00 | 1.72 | 0.69 | 1.64
 8 | 1.47 | 0.63 | 1.62 | 2.86 | 0.73 | 2.96
 16 | 3.30 | 0.62 | 2.90 | 5.70 | 0.72 | 5.61

#### `ipc::queue` — 1 sender, N receivers (8 bytes × 10 000 000)

 Receivers | @ 4 cores | @ 1 core
 ------ | ------ | ------
 1 | 0.090 | 0.049
 2 | 0.118 | 0.067
 4 | 0.122 | 0.102
 8 | 0.153 | 0.193
 16 | 0.189 | 0.282

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

* **[Typed Protocol Layer](doc/proto-layer.md)** — FlatBuffers-based typed channels and routes for type-safe, zero-copy IPC messaging
* **[Process Orchestration & Discovery](doc/orchestration.md)** — service registry, process management, redundant service groups with automatic failover
* **[macOS Technical Notes](doc/macos-technical-notes.md)** — platform-specific implementation details for macOS (semaphores, mutexes, shared memory)
* **[Audio Service Demo](demo/audio_service/)** — complete example with FlatBuffers protocol, redundancy, crash recovery, and auto-reconnect

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

* [Lock-Free Data Structures | Dr Dobb's](http://www.drdobbs.com/lock-free-data-structures/184401865)
* [Yet another implementation of a lock-free circular array queue | CodeProject](https://www.codeproject.com/Articles/153898/Yet-another-implementation-of-a-lock-free-circular)
* [Lock-Free 编程 | 匠心十年 - 博客园](http://www.cnblogs.com/gaochundong/p/lock_free_programming.html)
* [无锁队列的实现 | 酷 壳 - CoolShell](https://coolshell.cn/articles/8239.html)
* [Implementing Condition Variables with Semaphores](https://www.microsoft.com/en-us/research/wp-content/uploads/2004/12/ImplementingCVs.pdf)

------

## 使用共享内存的跨平台（Linux/Windows/macOS/FreeBSD，x86/x64/ARM）高性能IPC通讯库

* 推荐支持C++17的编译器（msvc-2017/gcc-7/clang-4）
* 除STL外，无其他依赖
* 无锁（lock-free）或轻量级spin-lock
* 底层数据结构为循环数组（circular array）
* `ipc::route`支持单写多读，`ipc::channel`支持多写多读【**注意：目前同一条通道最多支持32个receiver，sender无限制**】
* 默认采用广播模式收发数据，支持用户任意选择读写方案
* 不会长时间忙等（重试一定次数后会使用信号量进行等待），支持超时
* 支持[Vcpkg](https://github.com/microsoft/vcpkg/blob/master/README_zh_CN.md)方式安装，如`vcpkg install cpp-ipc`

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

* [Lock-Free Data Structures | Dr Dobb's](http://www.drdobbs.com/lock-free-data-structures/184401865)
* [Yet another implementation of a lock-free circular array queue | CodeProject](https://www.codeproject.com/Articles/153898/Yet-another-implementation-of-a-lock-free-circular)
* [Lock-Free 编程 | 匠心十年 - 博客园](http://www.cnblogs.com/gaochundong/p/lock_free_programming.html)
* [无锁队列的实现 | 酷 壳 - CoolShell](https://coolshell.cn/articles/8239.html)
* [Implementing Condition Variables with Semaphores](https://www.microsoft.com/en-us/research/wp-content/uploads/2004/12/ImplementingCVs.pdf)
