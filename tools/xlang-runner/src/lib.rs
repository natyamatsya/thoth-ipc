// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Shared core of the two matrix runners: `xlang-runner` (the cross-language
// ABI matrix over the per-language harnesses) and `demo-runner` (the same idea
// over the demos — every language in every role of each demo).

pub mod cases;
pub mod config;
pub mod demo;
pub mod exec;
pub mod harness;
pub mod report;
