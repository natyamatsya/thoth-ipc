// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// xlang-runner — cross-language IPC ABI test framework.
//
// thoth-ipc's C++, Rust and Swift ports share one byte-exact wire ABI
// (context/xlang-channel-abi.md). Each language ships one harness binary with
// a uniform CLI (write/read/aread/swrite/sread/clear/hold/count/caps); this
// runner plans every writer x reader pairing for the configured scenarios and
// executes them with hard deadlines, reporting console + JUnit + JSON.
//
// Scenarios:
//   sync           blocking write -> read round-trip, byte-for-byte
//   async          write posts a notify; reader does an async (readiness) recv
//   reap           dead-connection reaping (holder x reaper x {live, dead})
//   secure         AEAD envelope round-trip (swrite -> sread) per algorithm
//   secure-badkey  reader keyed differently must reject every message
//
// Usage (from the repo root):
//   XLANG_CPP_BIN=... XLANG_RUST_BIN=... xlang-runner --config tools/xlang-ci.toml
//
// Exit codes: 0 all passed, 1 case failures, 2 configuration/planning error.

mod cases;
mod config;
mod exec;
mod harness;
mod report;

use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;

use crate::exec::{CaseResult, Status};

#[derive(Parser)]
#[command(name = "xlang-runner", about = "Cross-language IPC ABI matrix runner")]
struct Cli {
    /// Matrix configuration (TOML); binary paths may use ${ENV_VAR}.
    #[arg(long, default_value = "tools/xlang-ci.toml")]
    config: PathBuf,

    /// Run only these scenarios (comma-separated: sync,async,reap,secure,secure-badkey).
    #[arg(long, value_delimiter = ',')]
    scenario: Vec<String>,

    /// Languages that must be present and capable, else exit 2 (CI guard
    /// against silently skipping, e.g. "cpp,rust").
    #[arg(long, value_delimiter = ',')]
    require: Vec<String>,

    /// Treat missing capabilities as an error instead of skipping the language.
    #[arg(long)]
    strict_caps: bool,

    /// Override [run].jobs from the config.
    #[arg(long)]
    jobs: Option<usize>,

    /// Override [run].retries from the config.
    #[arg(long)]
    retries: Option<u32>,

    /// Write a JUnit XML report.
    #[arg(long)]
    junit: Option<PathBuf>,

    /// Write a JSON report.
    #[arg(long)]
    json: Option<PathBuf>,

    /// Print the planned cases without executing them.
    #[arg(long)]
    list: bool,
}

fn main() -> ExitCode {
    let cli = Cli::parse();

    for s in &cli.scenario {
        if !cases::SCENARIOS.contains(&s.as_str()) {
            eprintln!(
                "error: unknown scenario '{s}' (known: {})",
                cases::SCENARIOS.join(", ")
            );
            return ExitCode::from(2);
        }
    }

    let mut cfg = match config::load(&cli.config) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::from(2);
        }
    };
    if let Some(jobs) = cli.jobs {
        cfg.run.jobs = jobs;
    }
    if let Some(retries) = cli.retries {
        cfg.run.retries = retries;
    }

    let resolved = harness::resolve(&cfg.languages);
    for u in &resolved.unavailable {
        eprintln!("note: language '{}' unavailable: {}", u.name, u.reason);
    }
    for lang in &cli.require {
        if !resolved.ready.contains_key(lang) {
            eprintln!("error: required language '{lang}' is not usable on this host");
            return ExitCode::from(2);
        }
    }
    if resolved.ready.is_empty() {
        eprintln!("error: no usable languages configured");
        return ExitCode::from(2);
    }

    println!("languages:");
    for h in resolved.ready.values() {
        let caps = if h.caps.is_empty() {
            "(none)".to_string()
        } else {
            h.caps.iter().cloned().collect::<Vec<_>>().join(" ")
        };
        println!("  {:<10} {}  caps: {caps}", h.name, h.bin.display());
    }

    let plan = cases::plan(&cfg, &resolved.ready, &cli.scenario);
    for note in &plan.notes {
        eprintln!(
            "note: '{}' skipped in scenario '{}': {}",
            note.lang, note.scenario, note.reason
        );
    }
    if cli.strict_caps && !plan.notes.is_empty() {
        eprintln!("error: --strict-caps and at least one language lacks required caps");
        return ExitCode::from(2);
    }
    if plan.cases.is_empty() {
        eprintln!("error: no cases planned (check modes/caps/scenario filter)");
        return ExitCode::from(2);
    }

    if cli.list {
        for c in &plan.cases {
            println!("  {:<13} {}", c.scenario, c.id);
        }
        println!("{} cases planned.", plan.cases.len());
        return ExitCode::SUCCESS;
    }

    println!(
        "\nrunning {} cases (jobs={}, retries={})\n",
        plan.cases.len(),
        cfg.run.jobs.max(1),
        cfg.run.retries
    );
    let mut results = exec::run_all(&plan.cases, &cfg.run, false);

    // Surface planning-time skips in the machine-readable reports too.
    results.extend(plan.notes.iter().map(|n| CaseResult {
        scenario: n.scenario.clone(),
        id: format!("{} (all pairings)", n.lang),
        status: Status::Skip,
        detail: n.reason.clone(),
        duration_secs: 0.0,
        attempts: 0,
    }));

    if let Some(path) = &cli.junit {
        if let Err(e) = report::write_junit(path, &results) {
            eprintln!("error: writing junit {}: {e}", path.display());
            return ExitCode::from(2);
        }
    }
    if let Some(path) = &cli.json {
        if let Err(e) = report::write_json(path, &results) {
            eprintln!("error: writing json {}: {e}", path.display());
            return ExitCode::from(2);
        }
    }

    if report::summarize(&results) {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
