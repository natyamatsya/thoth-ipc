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

| Receivers | C++ RTT (ms) | C++ us/datum | Rust RTT (ms) | Rust us/datum |
| :---: | :---: | :---: | :---: | :---: |
| 1 | 300.05 | 3.000 | **2.37** | **0.024** |
| 2 | 340.92 | 3.409 | **2.28** | **0.023** |
| 4 | 781.98 | 7.820 | **2.44** | **0.024** |
| 8 | 1790.42 | 17.904 | **2.16** | **0.022** |

### `ipc::channel` — 1 sender, N receivers (1-N)

| Receivers | C++ RTT (ms) | C++ us/datum | Rust RTT (ms) | Rust us/datum |
| :---: | :---: | :---: | :---: | :---: |
| 1 | 288.02 | 2.880 | **2.31** | **0.023** |
| 2 | 349.80 | 3.498 | **2.17** | **0.022** |
| 4 | 774.00 | 7.740 | **2.33** | **0.023** |
| 8 | 1796.00 | 17.960 | **2.31** | **0.023** |

### `ipc::channel` — N senders, 1 receiver (N-1)

| Senders | C++ RTT (ms) | C++ us/datum | Rust RTT (ms) | Rust us/datum |
| :---: | :---: | :---: | :---: | :---: |
| 1 | 287.18 | 2.872 | **3.34** | **0.033** |
| 2 | 192.07 | 1.921 | **2.61** | **0.026** |
| 4 | 208.92 | 2.089 | **5.04** | **0.050** |
| 8 | 318.92 | 3.189 | **8.51** | **0.085** |

### `ipc::channel` — N senders, N receivers (N-N)

| Threads | C++ RTT (ms) | C++ us/datum | Rust RTT (ms) | Rust us/datum |
| :---: | :---: | :---: | :---: | :---: |
| 1 | 299.34 | 2.993 | **2.77** | **0.028** |
| 2 | 399.48 | 3.995 | **6.97** | **0.070** |
| 4 | 1309.55 | 13.096 | **6.94** | **0.069** |
| 8 | 2362.82 | 23.628 | **4.58** | **0.046** |

## Conclusion

The Rust port significantly outperforms the original C++ implementation in these benchmarks on macOS. The Rust implementation shows remarkably consistent performance even as the number of receivers scales up (in the `1-N` and `route` tests), whereas the C++ implementation's latency degrades linearly. In the `N-1` and `N-N` contention scenarios, the Rust port also maintains sub-microsecond latency, vastly outperforming the C++ version.

This performance difference is likely due to the highly optimized concurrent primitive implementations in Rust (like `crossbeam` or standard library atomics) and potentially more efficient memory ordering/caching behavior in the port's architecture.
