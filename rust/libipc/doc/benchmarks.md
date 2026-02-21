# libipc Rust Port Performance Benchmarks

The `libipc` Rust port includes a direct translation of the C++ benchmark suite (`bench_ipc`). This allows for a direct comparison between the original C++ implementation and the new pure Rust implementation.

## Running the Benchmarks

You can run the benchmarks using Cargo:

```bash
cargo run --release --bin bench_ipc
```

## Results Comparison (macOS)

**Environment:**

* **CPU:** Apple Silicon (arm64), 12 hardware threads
* **OS:** macOS (Darwin)
* **Compiler (C++):** Apple Clang (C++17), Release build
* **Compiler (Rust):** rustc 1.85.0, Release build (`--release`)
* **Workload:** 100,000 messages of random sizes between 2 and 256 bytes

### `ipc::route` — 1 sender, N receivers

| Receivers | C++ RTT (ms) (Before Fix) | C++ RTT (ms) (After Fix) | Rust RTT (ms) |
| :---: | :---: | :---: | :---: |
| 1 | 300.05 | 285.63 | **2.37** |
| 2 | 340.92 | 337.70 | **2.28** |
| 4 | 781.98 | 780.37 | **2.44** |
| 8 | 1790.42 | 1874.48 | **2.16** |

### `ipc::channel` — 1 sender, N receivers (1-N)

| Receivers | C++ RTT (ms) (Before Fix) | C++ RTT (ms) (After Fix) | Rust RTT (ms) |
| :---: | :---: | :---: | :---: |
| 1 | 288.02 | 281.67 | **2.31** |
| 2 | 349.80 | 341.63 | **2.17** |
| 4 | 774.00 | 783.96 | **2.33** |
| 8 | 1796.00 | 1818.23 | **2.31** |

### `ipc::channel` — N senders, 1 receiver (N-1)

| Senders | C++ RTT (ms) (Before Fix) | C++ RTT (ms) (After Fix) | Rust RTT (ms) |
| :---: | :---: | :---: | :---: |
| 1 | 287.18 | 288.77 | **3.34** |
| 2 | 192.07 | 194.12 | **2.61** |
| 4 | 208.92 | 208.11 | **5.04** |
| 8 | 318.92 | 252.52 | **8.51** |

### `ipc::channel` — N senders, N receivers (N-N)

| Threads | C++ RTT (ms) (Before Fix) | C++ RTT (ms) (After Fix) | Rust RTT (ms) |
| :---: | :---: | :---: | :---: |
| 1 | 299.34 | 286.79 | **2.77** |
| 2 | 399.48 | 345.35 | **6.97** |
| 4 | 1309.55 | 1219.93 | **6.94** |
| 8 | 2362.82 | 2470.24 | **4.58** |

## Conclusion

The Rust port significantly outperforms the original C++ implementation in these benchmarks on macOS, even after applying a patch to the C++ backoff strategy (removing a `sleep_for(1ms)` call in the contention spin-loop).

The C++ performance bottleneck is deeply architectural on macOS, likely tied to differences in cross-process signaling, atomic CAS loops under contention, and the underlying POSIX shared memory/semaphore implementations which behave differently than on Linux/Windows.

The Rust implementation shows remarkably consistent performance even as the number of receivers scales up (in the `1-N` and `route` tests), whereas the C++ implementation's latency degrades linearly. In the `N-1` and `N-N` contention scenarios, the Rust port also maintains sub-microsecond latency, vastly outperforming the C++ version.
