// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// demo-runner — the cross-language demo matrix.
//
// The demos (pipeline, bounded buffer, channel aggregator, ...) exist in
// several ports with the same CLI, and because the wire format is byte-exact
// their roles mix across languages. This runner proves it the way xlang-runner
// proves the ABI: for each demo in tools/demos.toml it assigns every present
// language to every role (the Cartesian product over the demo's slots, plus
// fan-in roles started once per language), runs each case with hard deadlines,
// and checks exit codes and stdout. Console + JUnit + JSON reporting.
//
// Usage (from the repo root):
//   DEMO_CPP_DIR=cpp/thoth-ipc/build/bin DEMO_RUST_DIR=rust/thoth-ipc/target/release \
//   DEMO_ZIG_DIR=zig/thoth-ipc/zig-out/bin demo-runner --config tools/demos.toml
//
// Exit codes: 0 all passed, 1 case failures, 2 configuration/planning error.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;

use xlang_runner::demo::{config, plan, run};
use xlang_runner::exec::{CaseResult, Status};
use xlang_runner::report;

#[derive(Parser)]
#[command(name = "demo-runner", about = "Cross-language demo matrix runner")]
struct Cli {
    /// Demo matrix configuration (TOML); language dirs may use ${ENV_VAR}.
    #[arg(long, default_value = "tools/demos.toml")]
    config: PathBuf,

    /// Run only these demos (comma-separated).
    #[arg(long, value_delimiter = ',')]
    demo: Vec<String>,

    /// Languages that must take part in every demo they have a port of, else
    /// exit 2 (CI guard against silently skipping an unbuilt binary).
    #[arg(long, value_delimiter = ',')]
    require: Vec<String>,

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

    /// Print the planned cases (and their commands) without running them.
    #[arg(long)]
    list: bool,
}

fn main() -> ExitCode {
    let cli = Cli::parse();

    let mut cfg = match config::load(&cli.config) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::from(2);
        }
    };
    for d in &cli.demo {
        if !cfg.demos.contains_key(d) {
            let known: Vec<_> = cfg.demos.keys().cloned().collect();
            eprintln!("error: unknown demo '{d}' (known: {})", known.join(", "));
            return ExitCode::from(2);
        }
    }
    if let Some(jobs) = cli.jobs {
        cfg.run.jobs = jobs;
    }
    if let Some(retries) = cli.retries {
        cfg.run.retries = retries;
    }

    let plan = match plan::plan(&cfg, &cli.demo) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::from(2);
        }
    };
    for note in &plan.notes {
        eprintln!("note: {} / {}: {}", note.scenario, note.lang, note.reason);
    }
    for lang in &cli.require {
        if !plan.coverage.contains_key(lang) {
            eprintln!("error: required language '{lang}' takes part in no demo on this host");
            return ExitCode::from(2);
        }
        if plan.notes.iter().any(|n| &n.lang == lang) {
            eprintln!("error: required language '{lang}' is missing from a demo it has a port of");
            return ExitCode::from(2);
        }
    }
    if plan.cases.is_empty() {
        eprintln!("error: no cases planned (check the language dirs and the demo filter)");
        return ExitCode::from(2);
    }

    println!("languages:");
    for (lang, demos) in &plan.coverage {
        println!("  {lang:<6} {}", demos.join(", "));
    }

    if cli.list {
        for c in &plan.cases {
            println!("  {}", run::describe(c));
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
    let mut results = run::run_all(&plan.cases, &cfg.run, false);

    // Surface planning-time skips in the machine-readable reports too.
    results.extend(plan.notes.iter().map(|n| CaseResult {
        scenario: n.scenario.clone(),
        id: format!("{} (all cases)", n.lang),
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
