// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Result reporting: console summary plus machine-readable JUnit XML and JSON
// for CI annotation and trend tooling.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::Path;

use crate::exec::{CaseResult, Status};

pub fn summarize(results: &[CaseResult]) -> bool {
    #[derive(Default)]
    struct Tally {
        pass: usize,
        flaky: usize,
        fail: usize,
        xfail: usize,
        xpass: usize,
        skip: usize,
    }
    let mut by_scenario: BTreeMap<&str, Tally> = BTreeMap::new();
    for r in results {
        let e = by_scenario.entry(&r.scenario).or_default();
        match r.status {
            Status::Pass => e.pass += 1,
            Status::Flaky => e.flaky += 1,
            Status::Fail => e.fail += 1,
            Status::XFail => e.xfail += 1,
            Status::XPass => e.xpass += 1,
            Status::Skip => e.skip += 1,
        }
    }

    println!();
    for (scenario, t) in &by_scenario {
        let total = t.pass + t.flaky + t.fail;
        let mut extras = String::new();
        if t.flaky > 0 {
            extras.push_str(&format!(", {} flaky", t.flaky));
        }
        if t.xfail > 0 {
            extras.push_str(&format!(", {} expected-fail", t.xfail));
        }
        if t.xpass > 0 {
            extras.push_str(&format!(", {} UNEXPECTED-pass", t.xpass));
        }
        if t.skip > 0 {
            extras.push_str(&format!(", {} skipped", t.skip));
        }
        if total > 0 {
            println!(
                "  {scenario:<14} {:>3}/{total} passed{extras}",
                t.pass + t.flaky
            );
        } else {
            println!("  {scenario:<14} (no strict cases){extras}");
        }
    }

    let xpasses: Vec<_> = results.iter().filter(|r| r.status == Status::XPass).collect();
    if !xpasses.is_empty() {
        println!("\nUNEXPECTED PASSES (flip the scenario's xfail expectation?):");
        for x in &xpasses {
            println!("  {} | {}", x.scenario, x.id);
        }
    }

    let failures: Vec<_> = results.iter().filter(|r| r.status == Status::Fail).collect();
    if failures.is_empty() {
        println!("\nAll strict cross-language pairings passed.");
        true
    } else {
        println!("\nFAILURES:");
        for f in &failures {
            println!("  {} | {}: {}", f.scenario, f.id, f.detail);
        }
        false
    }
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

pub fn write_junit(path: &Path, results: &[CaseResult]) -> std::io::Result<()> {
    let mut suites: BTreeMap<&str, Vec<&CaseResult>> = BTreeMap::new();
    for r in results {
        suites.entry(&r.scenario).or_default().push(r);
    }

    let mut out = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    let failures = results.iter().filter(|r| r.status == Status::Fail).count();
    let skipped = results.iter().filter(|r| r.status == Status::Skip).count();
    out.push_str(&format!(
        "<testsuites name=\"xlang\" tests=\"{}\" failures=\"{failures}\" skipped=\"{skipped}\">\n",
        results.len()
    ));
    for (scenario, cases) in &suites {
        let fails = cases.iter().filter(|r| r.status == Status::Fail).count();
        let skips = cases.iter().filter(|r| r.status == Status::Skip).count();
        out.push_str(&format!(
            "  <testsuite name=\"{}\" tests=\"{}\" failures=\"{fails}\" skipped=\"{skips}\">\n",
            xml_escape(scenario),
            cases.len()
        ));
        for r in cases {
            out.push_str(&format!(
                "    <testcase classname=\"xlang.{}\" name=\"{}\" time=\"{:.3}\"",
                xml_escape(scenario),
                xml_escape(&r.id),
                r.duration_secs
            ));
            match r.status {
                Status::Pass | Status::Flaky | Status::XPass => out.push_str("/>\n"),
                Status::Fail => out.push_str(&format!(
                    ">\n      <failure message=\"{}\"/>\n    </testcase>\n",
                    xml_escape(&r.detail)
                )),
                // JUnit has no xfail notion; report as skipped-with-reason so
                // dashboards show it without failing the suite.
                Status::XFail => out.push_str(&format!(
                    ">\n      <skipped message=\"expected failure: {}\"/>\n    </testcase>\n",
                    xml_escape(&r.detail)
                )),
                Status::Skip => out.push_str(&format!(
                    ">\n      <skipped message=\"{}\"/>\n    </testcase>\n",
                    xml_escape(&r.detail)
                )),
            }
        }
        out.push_str("  </testsuite>\n");
    }
    out.push_str("</testsuites>\n");
    std::fs::File::create(path)?.write_all(out.as_bytes())
}

pub fn write_json(path: &Path, results: &[CaseResult]) -> std::io::Result<()> {
    #[derive(serde::Serialize)]
    struct Entry<'a> {
        scenario: &'a str,
        id: &'a str,
        status: &'a str,
        detail: &'a str,
        duration_secs: f64,
        attempts: u32,
    }
    let entries: Vec<Entry> = results
        .iter()
        .map(|r| Entry {
            scenario: &r.scenario,
            id: &r.id,
            status: r.status.label(),
            detail: &r.detail,
            duration_secs: r.duration_secs,
            attempts: r.attempts,
        })
        .collect();
    let text = serde_json::to_string_pretty(&entries)?;
    std::fs::write(path, text)
}
