// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of Rust bench_ipc.rs — two backends selectable at runtime.
//
// Usage:
//   bench-ipc [--threads] [--gcd] [max_threads]
//
//   --threads  POSIX pthread_create — mirrors the Rust benchmark  [default]
//   --gcd      Grand Central Dispatch (DispatchQueue.global)
//
// Note: a Swift async (Task.detached) backend was attempted but is not viable
// for N>1 because send/recv call pthread_cond_wait internally, which blocks
// the OS thread backing the cooperative pool and causes deadlocks under load.
//
// Examples:
//   swift run -c release bench-ipc                        # pthreads, up to 8
//   swift run -c release bench-ipc --gcd 4                # GCD, up to 4
//   swift run -c release bench-ipc --threads --gcd 4      # both backends

import Darwin.POSIX

// MARK: - Argument parsing

enum Backend { case threads, gcd }

var backends: [Backend] = []
nonisolated(unsafe) var maxThreads = 8

var i = 1
while i < CommandLine.arguments.count {
    switch CommandLine.arguments[i] {
    case "--threads": backends.append(.threads)
    case "--gcd":     backends.append(.gcd)
    default:
        if let n = Int(CommandLine.arguments[i]) { maxThreads = n }
        else { fputs("unknown argument: \(CommandLine.arguments[i])\n", stderr); exit(1) }
    }
    i += 1
}
if backends.isEmpty { backends = [.threads] }

// MARK: - Sync runner (shared by threads + gcd)

func runSyncBackend(
    _ backend: Backend,
    routeFn:   (Int, Int, Int, Int) -> Stats,
    chanFn:    (String, Int, Int, Int, Int) -> Stats
) {
    let tag = backend == .threads ? "threads (pthread)" : "gcd (DispatchQueue)"
    print("\n\n╔══════════════════════════════════════════════════════╗")
    print(  "║  Backend: \(tag)\(String(repeating: " ", count: max(0, 42 - tag.count)))║")
    print(  "╚══════════════════════════════════════════════════════╝")

    printHeader("ipc::route — 1 sender, N receivers (random 2–256 bytes × 100 000)")
    printTableHeader(col1: "Receivers")
    var n = 1
    while n <= maxThreads {
        printTableRow(label: n, stats: routeFn(n, 100_000, 2, 256)); n *= 2
    }

    printHeader("ipc::channel — 1-N (random 2–256 bytes × 100 000)")
    printTableHeader(col1: "Receivers")
    n = 1
    while n <= maxThreads {
        printTableRow(label: n, stats: chanFn("1-N", n, 100_000, 2, 256)); n *= 2
    }

    printHeader("ipc::channel — N-1 (random 2–256 bytes × 100 000)")
    printTableHeader(col1: "Senders")
    n = 1
    while n <= maxThreads {
        printTableRow(label: n, stats: chanFn("N-1", n, 100_000, 2, 256)); n *= 2
    }

    printHeader("ipc::channel — N-N (random 2–256 bytes × 100 000)")
    printTableHeader(col1: "Threads")
    n = 1
    while n <= maxThreads {
        printTableRow(label: n, stats: chanFn("N-N", n, 100_000, 2, 256)); n *= 2
    }
}

// MARK: - Entry point

let nCPU = Int(sysconf(_SC_NPROCESSORS_ONLN))
print("cpp-ipc benchmark (Swift port)")
print("Platform: macOS, \(nCPU) hardware threads")

for backend in backends {
    switch backend {
    case .threads:
        runSyncBackend(.threads,
            routeFn: { threadsBenchRoute(nReceivers: $0, count: $1, msgLo: $2, msgHi: $3) },
            chanFn:  { threadsBenchChannel(pattern: $0, n: $1, count: $2, msgLo: $3, msgHi: $4) })
    case .gcd:
        runSyncBackend(.gcd,
            routeFn: { gcdBenchRoute(nReceivers: $0, count: $1, msgLo: $2, msgHi: $3) },
            chanFn:  { gcdBenchChannel(pattern: $0, n: $1, count: $2, msgLo: $3, msgHi: $4) })
    }
}

print("\nDone.")
