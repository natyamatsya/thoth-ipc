// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Allocation strategy benchmarks.
//
// Run with:
//   cargo bench --bench alloc --features bump_alloc,slab_pool
//
// Groups:
//   buffer_global   — Vec<u8> via the global allocator (baseline)
//   buffer_bump     — bumpalo arena (feature = bump_alloc)
//   slab_fixed_64   — slab pool of 64-byte blocks (feature = slab_pool)
//   slab_fixed_1024 — slab pool of 1024-byte blocks (feature = slab_pool)
//
// Each group exercises the same workload at three message sizes:
//   small  — 48 bytes  (fits in a ring slot inline, DATA_LENGTH = 64)
//   medium — 256 bytes (just over one slot, triggers fragmentation)
//   large  — 4096 bytes (large-message path, chunk storage)

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};

// ---------------------------------------------------------------------------
// Workload sizes (mirrors channel.rs DATA_LENGTH = 64)
// ---------------------------------------------------------------------------

const SMALL: usize = 48;
const MEDIUM: usize = 256;
const LARGE: usize = 4096;

const SIZES: &[(&str, usize)] = &[
    ("small_48", SMALL),
    ("medium_256", MEDIUM),
    ("large_4096", LARGE),
];

// ---------------------------------------------------------------------------
// Baseline: global allocator (Vec<u8>)
// ---------------------------------------------------------------------------

fn bench_global_alloc(c: &mut Criterion) {
    let mut group = c.benchmark_group("buffer_global");

    for &(label, size) in SIZES {
        group.throughput(Throughput::Bytes(size as u64));
        group.bench_with_input(BenchmarkId::from_parameter(label), &size, |b, &sz| {
            b.iter(|| {
                let v: Vec<u8> = vec![0xABu8; sz];
                black_box(v)
            });
        });
    }

    group.finish();
}

// ---------------------------------------------------------------------------
// bumpalo: allocate into arena, reset between iterations
// ---------------------------------------------------------------------------

#[cfg(feature = "bump_alloc")]
fn bench_bump_alloc(c: &mut Criterion) {
    let mut group = c.benchmark_group("buffer_bump");

    for &(label, size) in SIZES {
        group.throughput(Throughput::Bytes(size as u64));
        group.bench_with_input(BenchmarkId::from_parameter(label), &size, |b, &sz| {
            let mut arena = libipc::mem::BumpArena::with_capacity(sz * 2);
            b.iter(|| {
                let slice = arena.alloc_bytes(sz, 1);
                slice.fill(0xAB);
                black_box(&*slice);
                arena.reset();
            });
        });
    }

    group.finish();
}

// Benchmark: build a Vec inside the arena (no separate heap alloc for the Vec header)
#[cfg(feature = "bump_alloc")]
fn bench_bump_vec(c: &mut Criterion) {
    let mut group = c.benchmark_group("buffer_bump_vec");

    for &(label, size) in SIZES {
        group.throughput(Throughput::Bytes(size as u64));
        group.bench_with_input(BenchmarkId::from_parameter(label), &size, |b, &sz| {
            let mut arena = libipc::mem::BumpArena::with_capacity(sz * 2);
            b.iter(|| {
                let len = {
                    let mut v = arena.alloc_vec_with_capacity(sz);
                    v.resize(sz, 0xABu8);
                    black_box(v.len())
                };
                black_box(len);
                arena.reset();
            });
        });
    }

    group.finish();
}

// Benchmark: copy a pre-existing slice into the arena (recv-side reassembly pattern)
#[cfg(feature = "bump_alloc")]
fn bench_bump_copy(c: &mut Criterion) {
    let mut group = c.benchmark_group("buffer_bump_copy");

    for &(label, size) in SIZES {
        group.throughput(Throughput::Bytes(size as u64));
        let src: Vec<u8> = vec![0xCDu8; size];
        group.bench_with_input(BenchmarkId::from_parameter(label), &size, |b, &_sz| {
            let mut arena = libipc::mem::BumpArena::with_capacity(src.len() * 2);
            b.iter(|| {
                let slice = arena.alloc_slice_copy(&src);
                black_box(slice);
                arena.reset();
            });
        });
    }

    group.finish();
}

// ---------------------------------------------------------------------------
// slab: fixed-size block pool — 64-byte blocks (inline slot size)
// ---------------------------------------------------------------------------

#[cfg(feature = "slab_pool")]
fn bench_slab_64(c: &mut Criterion) {
    let mut group = c.benchmark_group("slab_fixed_64");
    group.throughput(Throughput::Bytes(64));

    group.bench_function("insert_remove", |b| {
        let mut pool = libipc::mem::SlabPool::<64>::with_capacity(32);
        b.iter(|| {
            let key = pool.insert_zeroed();
            if let Some(block) = pool.get_mut(key) {
                block[0] = 0xAB;
                black_box(&*block);
            }
            pool.remove(key);
        });
    });

    group.bench_function("insert_remove_from_slice", |b| {
        let src = [0xCDu8; 48]; // typical small message
        let mut pool = libipc::mem::SlabPool::<64>::with_capacity(32);
        b.iter(|| {
            let key = pool.insert_from_slice(&src);
            black_box(pool.get(key));
            pool.remove(key);
        });
    });

    group.finish();
}

// ---------------------------------------------------------------------------
// slab: fixed-size block pool — 1024-byte blocks (CHUNK_ALIGN size)
// ---------------------------------------------------------------------------

#[cfg(feature = "slab_pool")]
fn bench_slab_1024(c: &mut Criterion) {
    let mut group = c.benchmark_group("slab_fixed_1024");
    group.throughput(Throughput::Bytes(1024));

    group.bench_function("insert_remove", |b| {
        let mut pool = libipc::mem::SlabPool::<1024>::with_capacity(32);
        b.iter(|| {
            let key = pool.insert_zeroed();
            if let Some(block) = pool.get_mut(key) {
                block[0] = 0xAB;
                black_box(&*block);
            }
            pool.remove(key);
        });
    });

    group.bench_function("insert_remove_from_slice", |b| {
        let src = vec![0xCDu8; 256];
        let mut pool = libipc::mem::SlabPool::<1024>::with_capacity(32);
        b.iter(|| {
            let key = pool.insert_from_slice(&src);
            black_box(pool.get(key));
            pool.remove(key);
        });
    });

    group.finish();
}

// ---------------------------------------------------------------------------
// Comparison: slab vs global for the same 64-byte workload
// ---------------------------------------------------------------------------

fn bench_global_64(c: &mut Criterion) {
    let mut group = c.benchmark_group("global_vs_slab_64");
    group.throughput(Throughput::Bytes(64));

    group.bench_function("global_alloc", |b| {
        b.iter(|| {
            let v: Vec<u8> = vec![0xABu8; 64];
            black_box(v)
        });
    });

    #[cfg(feature = "slab_pool")]
    group.bench_function("slab_pool", |b| {
        let mut pool = libipc::mem::SlabPool::<64>::with_capacity(32);
        b.iter(|| {
            let key = pool.insert_zeroed();
            black_box(pool.get(key));
            pool.remove(key);
        });
    });

    group.finish();
}

// ---------------------------------------------------------------------------
// Criterion entry points
// ---------------------------------------------------------------------------

#[cfg(all(feature = "bump_alloc", feature = "slab_pool"))]
criterion_group!(
    benches,
    bench_global_alloc,
    bench_bump_alloc,
    bench_bump_vec,
    bench_bump_copy,
    bench_slab_64,
    bench_slab_1024,
    bench_global_64,
);

#[cfg(all(feature = "bump_alloc", not(feature = "slab_pool")))]
criterion_group!(
    benches,
    bench_global_alloc,
    bench_bump_alloc,
    bench_bump_vec,
    bench_bump_copy,
    bench_global_64,
);

#[cfg(all(not(feature = "bump_alloc"), feature = "slab_pool"))]
criterion_group!(
    benches,
    bench_global_alloc,
    bench_slab_64,
    bench_slab_1024,
    bench_global_64,
);

#[cfg(all(not(feature = "bump_alloc"), not(feature = "slab_pool")))]
criterion_group!(benches, bench_global_alloc, bench_global_64);

criterion_main!(benches);
