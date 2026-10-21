// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Demo-matrix execution: start a case's processes in order (each after the
// previous one's `ready` line, or a short pause), wait for all of them under
// one deadline, then check exit codes and stdout expectations.
//
// Output is read line by line on background threads while the processes run,
// both to detect readiness and so a chatty process never blocks on a full pipe.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use super::config::DemoRunConfig;
use super::plan::{CaseProc, DemoCase};
use crate::exec::{CaseResult, Status};

#[derive(Default)]
struct Lines {
    stdout: Vec<String>,
    stderr: Vec<String>,
}

#[derive(Default)]
struct Output {
    lines: Mutex<Lines>,
    changed: Condvar,
}

struct Running<'a> {
    spec: &'a CaseProc,
    child: Child,
    output: Arc<Output>,
    readers: Vec<JoinHandle<()>>,
    exit: Option<Option<i32>>, // Some(code) once exited; Some(None) if killed by a signal
    killed: bool,
}

fn read_lines(stream: impl Read + Send + 'static, output: Arc<Output>, stdout: bool) -> JoinHandle<()> {
    std::thread::spawn(move || {
        for line in BufReader::new(stream).lines() {
            let Ok(line) = line else { break };
            let mut lines = output.lines.lock().unwrap();
            if stdout {
                lines.stdout.push(line);
            } else {
                lines.stderr.push(line);
            }
            drop(lines);
            output.changed.notify_all();
        }
    })
}

fn spawn<'a>(spec: &'a CaseProc) -> Result<Running<'a>, String> {
    let mut child = Command::new(&spec.bin)
        .args(&spec.args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("{}: cannot start {}: {e}", spec.label, spec.bin.display()))?;
    let output = Arc::new(Output::default());
    let readers = vec![
        read_lines(child.stdout.take().unwrap(), output.clone(), true),
        read_lines(child.stderr.take().unwrap(), output.clone(), false),
    ];
    Ok(Running { spec, child, output, readers, exit: None, killed: false })
}

impl Running<'_> {
    fn poll(&mut self) -> bool {
        if self.exit.is_none() {
            if let Ok(Some(status)) = self.child.try_wait() {
                self.exit = Some(status.code());
            }
        }
        self.exit.is_some()
    }

    fn kill(&mut self) {
        if !self.poll() {
            let _ = self.child.kill();
            let _ = self.child.wait();
            self.exit = Some(None);
            self.killed = true;
        }
    }

    /// Wait until a line matching the process's `ready` pattern appears, the
    /// process exits, or `timeout` passes. True if ready.
    fn wait_ready(&mut self, timeout: Duration) -> bool {
        let Some(ready) = &self.spec.ready else { return true };
        let seen = |lines: &Lines| lines.stdout.iter().chain(&lines.stderr).any(|l| ready.is_match(l));
        let deadline = Instant::now() + timeout;
        loop {
            if seen(&self.output.lines.lock().unwrap()) {
                return true;
            }
            if self.poll() {
                // Exited: its readers may still be draining the last lines.
                std::thread::sleep(Duration::from_millis(50));
                return seen(&self.output.lines.lock().unwrap());
            }
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            // Wake on new output, and re-check for an exit at least every 50 ms.
            let lines = self.output.lines.lock().unwrap();
            let wait = (deadline - now).min(Duration::from_millis(50));
            let _ = self.output.changed.wait_timeout(lines, wait).unwrap();
        }
    }

    fn last_stderr(&self) -> String {
        let lines = self.output.lines.lock().unwrap();
        lines.stderr.iter().rev().find(|l| !l.trim().is_empty()).cloned().unwrap_or_default()
    }

    /// Why this process failed its expectations, if it did.
    fn verdict(&self) -> Option<String> {
        let label = &self.spec.label;
        let tail = match self.last_stderr() {
            s if s.is_empty() => String::new(),
            s => format!(" — {s}"),
        };
        match self.exit {
            Some(None) if self.killed => return Some(format!("{label}: killed at the deadline{tail}")),
            Some(None) => return Some(format!("{label}: died from a signal{tail}")),
            Some(Some(code)) if code != self.spec.exit => {
                return Some(format!("{label}: exit {code} (expected {}){tail}", self.spec.exit));
            }
            None => return Some(format!("{label}: still running")),
            _ => {}
        }
        let lines = self.output.lines.lock().unwrap();
        for e in &self.spec.expect {
            let n = lines.stdout.iter().filter(|l| e.pattern.is_match(l)).count();
            let ok = match e.count {
                Some(want) => n == want,
                None => n > 0,
            };
            if !ok {
                let want = e.count.map_or("at least 1".to_string(), |c| c.to_string());
                return Some(format!("{label}: {n} stdout line(s) match /{}/, expected {want}", e.pattern));
            }
        }
        None
    }
}

fn clear(case: &DemoCase) {
    if let Some((bin, args)) = &case.clear {
        let _ = Command::new(bin)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

fn run_once(case: &DemoCase, cfg: &DemoRunConfig) -> (bool, String) {
    clear(case);
    let deadline = Instant::now() + Duration::from_secs(cfg.case_timeout_secs);
    let mut running: Vec<Running> = Vec::new();
    let mut failure: Option<String> = None;

    for spec in &case.procs {
        match spawn(spec) {
            Ok(mut r) => {
                if spec.ready.is_some() {
                    if !r.wait_ready(Duration::from_secs(cfg.ready_timeout_secs)) {
                        failure = Some(format!("{}: no ready line within {}s", spec.label, cfg.ready_timeout_secs));
                    }
                } else {
                    std::thread::sleep(Duration::from_millis(cfg.start_gap_ms));
                }
                running.push(r);
            }
            Err(e) => failure = Some(e),
        }
        if failure.is_some() {
            break;
        }
    }

    // Wait for every process; once one fails, the rest get a short grace.
    let mut grace_end: Option<Instant> = failure.as_ref().map(|_| Instant::now());
    loop {
        let mut all_done = true;
        for r in &mut running {
            if r.poll() {
                if grace_end.is_none() && r.exit != Some(Some(r.spec.exit)) {
                    grace_end = Some(Instant::now() + Duration::from_millis(cfg.failure_grace_ms));
                }
            } else {
                all_done = false;
            }
        }
        let now = Instant::now();
        if all_done || now >= deadline || grace_end.is_some_and(|g| now >= g) {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    for r in &mut running {
        r.kill();
    }
    for r in &mut running {
        for h in r.readers.drain(..) {
            let _ = h.join();
        }
    }
    clear(case);

    if let Some(f) = failure {
        return (false, f);
    }
    // Report the first process (in start order) that failed: a timed-out
    // consumer is usually the symptom of an upstream failure listed first.
    let verdicts: Vec<String> = running.iter().filter_map(Running::verdict).collect();
    match verdicts.first() {
        None => (true, String::new()),
        Some(_) => (false, verdicts.join("; ")),
    }
}

fn run_case(case: &DemoCase, cfg: &DemoRunConfig) -> CaseResult {
    let started = Instant::now();
    let mut attempts = 0;
    let (status, detail) = loop {
        attempts += 1;
        let (ok, detail) = run_once(case, cfg);
        if ok {
            let status = match (case.xfail, attempts > 1) {
                (true, _) => Status::XPass,
                (false, true) => Status::Flaky,
                (false, false) => Status::Pass,
            };
            break (status, detail);
        }
        if case.xfail {
            break (Status::XFail, detail);
        }
        if attempts > cfg.retries {
            break (Status::Fail, detail);
        }
    };
    CaseResult {
        scenario: case.demo.clone(),
        id: case.id.clone(),
        status,
        detail,
        duration_secs: started.elapsed().as_secs_f64(),
        attempts,
    }
}

/// Run all cases on `cfg.jobs` workers. Cases of one serial group run one
/// after another on a single worker; everything else runs in parallel.
/// Results come back in planning order.
pub fn run_all(cases: &[DemoCase], cfg: &DemoRunConfig, quiet: bool) -> Vec<CaseResult> {
    // Work units: one per serial group (its cases in order), one per other case.
    let mut groups: BTreeMap<&str, Vec<usize>> = BTreeMap::new();
    let mut units: Vec<Vec<usize>> = Vec::new();
    for (i, c) in cases.iter().enumerate() {
        match &c.serial_group {
            Some(g) => groups.entry(g.as_str()).or_default().push(i),
            None => units.push(vec![i]),
        }
    }
    // Serial groups first: they are the long poles.
    let mut ordered: Vec<Vec<usize>> = groups.into_values().collect();
    ordered.extend(units);

    let jobs = cfg.jobs.max(1).min(ordered.len().max(1));
    let next = AtomicUsize::new(0);
    let done = AtomicUsize::new(0);
    let total = cases.len();
    let results: Vec<Mutex<Option<CaseResult>>> = cases.iter().map(|_| Mutex::new(None)).collect();

    std::thread::scope(|scope| {
        for _ in 0..jobs {
            scope.spawn(|| loop {
                let u = next.fetch_add(1, Ordering::Relaxed);
                let Some(unit) = ordered.get(u) else { break };
                for &i in unit {
                    let result = run_case(&cases[i], cfg);
                    if !quiet {
                        let n = done.fetch_add(1, Ordering::Relaxed) + 1;
                        let mut line = format!(
                            "  [{}] ({n}/{total}) {:<18} {}",
                            result.status.label(),
                            result.scenario,
                            result.id
                        );
                        if matches!(result.status, Status::Fail | Status::Flaky | Status::XFail) {
                            line.push_str(&format!("   {}", result.detail));
                        }
                        println!("{line}");
                    }
                    *results[i].lock().unwrap() = Some(result);
                }
            });
        }
    });

    results
        .into_iter()
        .map(|m| m.into_inner().unwrap().expect("worker filled every slot"))
        .collect()
}

/// For `--list`: the commands a case runs, one per line.
pub fn describe(case: &DemoCase) -> String {
    let mut out = format!("{} | {}", case.demo, case.id);
    for p in &case.procs {
        let bin = Path::new(&p.bin).file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default();
        out.push_str(&format!("\n    {:<20} {bin} {}", p.label, p.args.join(" ")));
    }
    out
}
