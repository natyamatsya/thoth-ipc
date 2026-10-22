// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Declarative demo-matrix configuration (tools/demos.toml). As for the xlang
// matrix, one file serves every OS/CI job: each language's demo directory is an
// `${ENV_VAR}`, and a language whose variable is unset (Swift on Linux) is
// simply not present on this host.
//
// A demo is a set of processes. Each process plays a role and takes its
// language either from a matrix *slot* (the planner assigns every present
// language to every slot, as the Cartesian product) or is started once per
// present language (`each_language`, for fan-in roles such as producers). A
// slot takes the languages that ship every binary its processes run, and the
// `each_language` roles those that ship all of theirs, so a port of a single
// role (the FFI audio service) fills only that role's slot.
// Arguments and expectations use placeholders, expanded per case:
//
//   {count}          the demo's `count`
//   {total}          count x the number of `each_language` processes (or count)
//   {fanin}          the number of `each_language` processes
//   {index}          an `each_language` process's position (0, 1, ...); 0 otherwise
//   {lang}           this process's language
//   {lang:SLOT}      the language assigned to SLOT
//   {ch:NAME}        a channel name unique to this case (cases run in parallel)
//   {path:BIN@SLOT}  the path of binary BIN in SLOT's language
//   {each}           in a `for_each_language` expectation: one of the
//                    `each_language` processes' languages
//
// In `expect.line` and `ready`, which are regular expressions, substituted
// values are regex-escaped.

use std::collections::BTreeMap;

use serde::Deserialize;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DemoFile {
    #[serde(default)]
    pub run: DemoRunConfig,
    pub languages: BTreeMap<String, LanguageDir>,
    pub demos: BTreeMap<String, Demo>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct DemoRunConfig {
    /// Cases executed concurrently. A `serial` demo's cases never overlap each
    /// other (its IPC names are fixed), but may overlap other demos' cases.
    pub jobs: usize,
    /// Re-run a failed case up to this many extra times ("flaky" if it then passes).
    pub retries: u32,
    /// Hard deadline for a whole case; every process still running is killed.
    pub case_timeout_secs: u64,
    /// How long to wait for a process's `ready` line before giving up.
    pub ready_timeout_secs: u64,
    /// Pause after starting a process that declares no `ready` line.
    pub start_gap_ms: u64,
    /// Once one process has failed, how long the others get to finish.
    pub failure_grace_ms: u64,
}

impl Default for DemoRunConfig {
    fn default() -> Self {
        Self {
            jobs: 4,
            retries: 0,
            case_timeout_secs: 60,
            ready_timeout_secs: 10,
            start_gap_ms: 300,
            failure_grace_ms: 2000,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LanguageDir {
    /// Directory holding this language's demo binaries; usually `${ENV_VAR}`.
    pub dir: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Demo {
    #[serde(default)]
    pub description: String,
    /// Binary key -> language -> file name in that language's `dir`. A process
    /// runs the binary named by its `bin` (default `main`); a language fills a
    /// slot only if it ships every binary that slot's processes run.
    pub bins: BTreeMap<String, BTreeMap<String, String>>,
    /// The demo's IPC names are fixed: run its cases one at a time.
    #[serde(default)]
    pub serial: bool,
    /// Arguments of a verb that removes the demo's IPC objects, run (with the
    /// main binary of the case's first language) before and after every case.
    #[serde(default)]
    pub clear: Vec<String>,
    pub count: usize,
    /// Only these languages take part (all present ones if empty).
    #[serde(default)]
    pub languages: Vec<String>,
    /// Cases whose id contains one of these run as expected-fail (known gaps).
    #[serde(default)]
    pub xfail: Vec<String>,
    /// Processes, started in this order.
    pub procs: Vec<ProcSpec>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProcSpec {
    pub role: String,
    /// The matrix slot this process takes its language from.
    #[serde(default)]
    pub slot: Option<String>,
    /// Start this process once per present language instead.
    #[serde(default)]
    pub each_language: bool,
    #[serde(default = "main_bin")]
    pub bin: String,
    pub args: Vec<String>,
    /// Wait for an output line (stdout or stderr) matching this pattern before
    /// starting the next process; otherwise pause `start_gap_ms`.
    #[serde(default)]
    pub ready: Option<String>,
    /// Expected exit code.
    #[serde(default)]
    pub exit: i32,
    #[serde(default)]
    pub expect: Vec<Expect>,
    /// This role's process is started by the named role, not by the runner
    /// (e.g. a service the host spawns from `{path:BIN@SLOT}`): it only adds
    /// its slot to the matrix.
    #[serde(default)]
    pub spawned_by: Option<String>,
}

fn main_bin() -> String {
    "main".to_string()
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Expect {
    /// Pattern for whole stdout lines.
    pub line: String,
    /// Exact number of matching lines (placeholders allowed); at least one if unset.
    #[serde(default)]
    pub count: Option<String>,
    /// Check the expectation once per `each_language` language, as `{each}`.
    #[serde(default)]
    pub for_each_language: bool,
}

pub fn load(path: &std::path::Path) -> Result<DemoFile, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("cannot read config {}: {e}", path.display()))?;
    let file: DemoFile =
        toml::from_str(&text).map_err(|e| format!("bad config {}: {e}", path.display()))?;
    for (name, demo) in &file.demos {
        for p in &demo.procs {
            if p.slot.is_some() == p.each_language {
                return Err(format!(
                    "demo '{name}', role '{}': set exactly one of `slot` and `each_language`",
                    p.role
                ));
            }
            if !demo.bins.contains_key(&p.bin) {
                return Err(format!(
                    "demo '{name}', role '{}': unknown bin '{}'",
                    p.role, p.bin
                ));
            }
            if let Some(by) = &p.spawned_by {
                if p.slot.is_none() || !demo.procs.iter().any(|q| &q.role == by) {
                    return Err(format!(
                        "demo '{name}', role '{}': `spawned_by` needs a `slot` and an existing role",
                        p.role
                    ));
                }
            }
        }
    }
    Ok(file)
}
