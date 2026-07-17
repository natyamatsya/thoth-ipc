// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Case execution: process orchestration with hard deadlines, plus a worker
// pool. No async runtime — cases are process-bound, threads are plenty.

use std::io::Read;
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use crate::cases::{Case, CaseKind, Probe, Proc};
use crate::config::RunConfig;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Pass,
    /// Passed only after at least one retry.
    Flaky,
    Fail,
    /// Failed, but the failure is expected (known library gap) — not fatal.
    XFail,
    /// Passed although failure was expected — the expectation should be flipped.
    XPass,
    Skip,
}

impl Status {
    pub fn label(self) -> &'static str {
        match self {
            Status::Pass => "PASS",
            Status::Flaky => "FLAKY",
            Status::Fail => "FAIL",
            Status::XFail => "XFAIL",
            Status::XPass => "XPASS",
            Status::Skip => "SKIP",
        }
    }
}

#[derive(Debug, Clone)]
pub struct CaseResult {
    pub scenario: String,
    pub id: String,
    pub status: Status,
    pub detail: String,
    pub duration_secs: f64,
    pub attempts: u32,
}

pub struct WaitResult {
    pub status: ExitStatus,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub timed_out: bool,
}

/// Wait for a child with a deadline, draining its piped streams from
/// background threads (so a chatty child can never block on a full pipe).
/// On timeout the child is killed; `timed_out` is set.
pub fn wait_collect(mut child: Child, timeout: Duration) -> std::io::Result<WaitResult> {
    fn drain(stream: Option<impl Read + Send + 'static>) -> std::thread::JoinHandle<Vec<u8>> {
        std::thread::spawn(move || {
            let mut buf = Vec::new();
            if let Some(mut s) = stream {
                let _ = s.read_to_end(&mut buf);
            }
            buf
        })
    }
    let out = drain(child.stdout.take());
    let err = drain(child.stderr.take());

    let deadline = Instant::now() + timeout;
    let (status, timed_out) = loop {
        if let Some(status) = child.try_wait()? {
            break (status, false);
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            break (child.wait()?, true);
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    Ok(WaitResult {
        status,
        stdout: out.join().unwrap_or_default(),
        stderr: err.join().unwrap_or_default(),
        timed_out,
    })
}

/// Convenience shim used by caps probing: Err(()) on spawn-side timeout.
pub fn wait_with_timeout(
    child: Child,
    timeout: Duration,
) -> Result<WaitResult, ()> {
    match wait_collect(child, timeout) {
        Ok(r) if !r.timed_out => Ok(r),
        _ => Err(()),
    }
}

fn spawn(bin: &Path, args: &[String]) -> std::io::Result<Child> {
    Command::new(bin)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
}

/// Unlink the channel's shm segments via a harness's `clear` verb. Best-effort:
/// stale segments surface later as case failures, not runner errors.
fn clear(bin: &Path, channel: &str) {
    if let Ok(child) = Command::new(bin)
        .args(["clear", channel])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    {
        let _ = wait_collect(child, Duration::from_secs(10));
    }
}

fn last_stderr_line(bytes: &[u8]) -> Option<String> {
    let text = String::from_utf8_lossy(bytes);
    text.lines()
        .rev()
        .find(|l| !l.trim().is_empty())
        .map(str::to_string)
}

fn distinct_bins<'a>(procs: impl Iterator<Item = &'a Proc>) -> Vec<&'a Path> {
    let mut bins: Vec<&Path> = Vec::new();
    for p in procs {
        if !bins.contains(&p.endpoint.bin.as_path()) {
            bins.push(p.endpoint.bin.as_path());
        }
    }
    bins
}

/// Readers first, warmup, then writers; every process must exit 0.
/// Clears the channel's storage before and after through each distinct binary.
fn run_group(readers: &[Proc], writers: &[Proc], channel: &str, cfg: &RunConfig) -> (bool, String) {
    let clearers = distinct_bins(readers.iter().chain(writers));
    for bin in &clearers {
        clear(bin, channel);
    }
    let result = run_group_inner(readers, writers, cfg);
    for bin in &clearers {
        clear(bin, channel);
    }
    result
}

/// The group body without any storage clearing (used directly when the case
/// intentionally runs on pre-existing state, e.g. traffic-after-reap).
fn run_group_inner(readers: &[Proc], writers: &[Proc], cfg: &RunConfig) -> (bool, String) {
    let timeout = Duration::from_secs(cfg.pair_timeout_secs);
    let mut children: Vec<(String, Child)> = Vec::new();
    let spawn_all = |procs: &[Proc], role: &str, children: &mut Vec<(String, Child)>| -> Result<(), String> {
        for p in procs {
            let label = format!("{role}[{}]", p.endpoint.lang);
            match spawn(&p.endpoint.bin, &p.args) {
                Ok(c) => children.push((label, c)),
                Err(e) => return Err(format!("spawn {label} failed: {e}")),
            }
        }
        Ok(())
    };

    let spawn_err = spawn_all(readers, "reader", &mut children).err().or_else(|| {
        // Give the readers a moment to create the ring and register their
        // receiver slots before any writer connects.
        std::thread::sleep(Duration::from_millis(cfg.reader_warmup_ms));
        spawn_all(writers, "writer", &mut children).err()
    });
    if let Some(e) = spawn_err {
        for (_, mut c) in children {
            let _ = c.kill();
            let _ = c.wait();
        }
        return (false, e);
    }

    // Wait writers first (they finish first in a healthy run), then readers.
    children.reverse();
    let mut detail = String::new();
    let mut ok = true;
    for (label, child) in children {
        match wait_collect(child, timeout) {
            Ok(wr) => {
                let mut failed = false;
                if wr.timed_out {
                    failed = true;
                    detail.push_str(&format!("{label}-timeout "));
                } else if !wr.status.success() {
                    failed = true;
                    detail.push_str(&format!("{label} rc={} ", wr.status.code().unwrap_or(-1)));
                }
                if failed {
                    ok = false;
                    if let Some(line) = last_stderr_line(&wr.stderr) {
                        detail.push_str(&format!("| {label}: {line} "));
                    }
                }
            }
            Err(e) => {
                ok = false;
                detail.push_str(&format!("{label} wait error: {e} "));
            }
        }
    }
    (ok, detail.trim().to_string())
}

fn run_hold_probe(
    holder: &Proc,
    kill_holder: bool,
    probes: &[Probe],
    then_group: &Option<(Vec<Proc>, Vec<Proc>)>,
    channel: &str,
    cfg: &RunConfig,
) -> (bool, String) {
    let mut clearers = distinct_bins(
        std::iter::once(holder)
            .chain(probes.iter().map(|p| &p.proc))
            .chain(then_group.iter().flat_map(|(r, w)| r.iter().chain(w))),
    );
    clearers.dedup();
    for bin in &clearers {
        clear(bin, channel);
    }

    let mut holder_child = match Command::new(&holder.endpoint.bin)
        .args(&holder.args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => return (false, format!("spawn holder failed: {e}")),
    };

    // Wait for the READY line proving the holder acquired its resource.
    let stdout = holder_child.stdout.take();
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    std::thread::spawn(move || {
        if let Some(s) = stdout {
            let mut reader = std::io::BufReader::new(s);
            let mut line = String::new();
            use std::io::BufRead;
            if reader.read_line(&mut line).is_ok() {
                let _ = tx.send(line);
            }
            // Keep draining so the holder never blocks on stdout.
            let mut rest = String::new();
            let _ = reader.read_to_string(&mut rest);
        }
    });
    let ready = matches!(rx.recv_timeout(Duration::from_secs(10)), Ok(l) if l.contains("READY"));
    if !ready {
        let _ = holder_child.kill();
        let _ = holder_child.wait();
        for bin in &clearers {
            clear(bin, channel);
        }
        return (false, "holder never became READY".into());
    }

    if kill_holder {
        let _ = holder_child.kill();
        let _ = holder_child.wait();
    }

    let mut ok = true;
    let mut detail = String::new();
    for (i, probe) in probes.iter().enumerate() {
        let out = Command::new(&probe.proc.endpoint.bin)
            .args(&probe.proc.args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| e.to_string())
            .and_then(|c| {
                wait_collect(c, Duration::from_secs(cfg.pair_timeout_secs.min(15)))
                    .map_err(|e| e.to_string())
            });
        let got = match out {
            Ok(r) if r.timed_out => "<timeout>".to_string(),
            Ok(r) => String::from_utf8_lossy(&r.stdout).trim().to_string(),
            Err(e) => format!("<error: {e}>"),
        };
        if got != probe.expect {
            ok = false;
            detail.push_str(&format!(
                "probe[{i} {}]={got} expected={} ",
                probe.proc.endpoint.lang, probe.expect
            ));
        }
    }

    // The follow-up group runs on the channel's REMAINING state (no clearing).
    if ok {
        if let Some((readers, writers)) = then_group {
            let (g_ok, g_detail) = run_group_inner(readers, writers, cfg);
            if !g_ok {
                ok = false;
                detail.push_str(&g_detail);
            }
        }
    }

    if !kill_holder {
        let _ = holder_child.kill();
        let _ = holder_child.wait();
    }
    for bin in &clearers {
        clear(bin, channel);
    }
    (ok, detail.trim().to_string())
}

fn run_once(case: &Case, cfg: &RunConfig) -> (bool, String) {
    match &case.kind {
        CaseKind::Group { readers, writers } => {
            run_group(readers, writers, &case.channel, cfg)
        }
        CaseKind::HoldProbe {
            holder,
            kill_holder,
            probes,
            then_group,
        } => run_hold_probe(holder, *kill_holder, probes, then_group, &case.channel, cfg),
    }
}

fn run_case(case: &Case, cfg: &RunConfig) -> CaseResult {
    let started = Instant::now();
    let mut attempts = 0;
    let (status, detail) = loop {
        attempts += 1;
        let (ok, detail) = run_once(case, cfg);
        if ok {
            break (
                match (case.xfail, attempts > 1) {
                    (true, _) => Status::XPass,
                    (false, true) => Status::Flaky,
                    (false, false) => Status::Pass,
                },
                detail,
            );
        }
        if case.xfail {
            break (Status::XFail, detail);
        }
        if attempts > cfg.retries {
            break (Status::Fail, detail);
        }
    };
    CaseResult {
        scenario: case.scenario.clone(),
        id: case.id.clone(),
        status,
        detail,
        duration_secs: started.elapsed().as_secs_f64(),
        attempts,
    }
}

/// Run all cases on a pool of `cfg.jobs` workers, printing one line per case
/// as it completes. Results come back in planning order.
pub fn run_all(cases: &[Case], cfg: &RunConfig, quiet: bool) -> Vec<CaseResult> {
    let jobs = cfg.jobs.max(1).min(cases.len().max(1));
    let next = AtomicUsize::new(0);
    let results: Vec<Mutex<Option<CaseResult>>> =
        cases.iter().map(|_| Mutex::new(None)).collect();
    let done = AtomicUsize::new(0);
    let total = cases.len();

    std::thread::scope(|scope| {
        for _ in 0..jobs {
            scope.spawn(|| {
                loop {
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    if i >= cases.len() {
                        break;
                    }
                    let result = run_case(&cases[i], cfg);
                    if !quiet {
                        let n = done.fetch_add(1, Ordering::Relaxed) + 1;
                        let mut line = format!(
                            "  [{}] ({n}/{total}) {:<13} {}",
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
