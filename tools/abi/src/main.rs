// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// ABI conformance checker for the language-neutral IDL (abi/abi.json).
//
// Two gates:
//   1. Structural — validate abi.json against abi/abi.schema.json (JSON Schema).
//   2. Semantic   — compile + run abi/dump_abi.cpp (the canonical C++), and diff
//      its ground-truth sizeof / mask / constant values against abi.json, so the
//      IDL can never silently drift from the deployed C++ wire format.
//
// The xlang matrix remains the third, behavioural gate (protocols, not covered
// here). Run: `cargo run --manifest-path tools/abi/Cargo.toml` (from repo root).

use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Target whose per-target values (e.g. ring sizes) we check against C++.
const TARGET: &str = "apple_arm64";

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("resolve repo root")
}

fn read_json(path: &Path) -> Value {
    let s = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&s).unwrap_or_else(|e| panic!("parse {}: {e}", path.display()))
}

/// Interpret a JSON value as a u64: a number, or a "0x…" / decimal string.
fn as_u64(v: &Value) -> Option<u64> {
    match v {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => {
            let s = s.trim();
            match s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
                Some(h) => u64::from_str_radix(h, 16).ok(),
                None => s.parse::<u64>().ok(),
            }
        }
        _ => None,
    }
}

/// A plain integer, or a per-target object resolved for `TARGET`.
fn resolve_int(v: &Value) -> Option<u64> {
    if let Some(u) = as_u64(v) {
        return Some(u);
    }
    v.get(TARGET).and_then(as_u64)
}

fn main() {
    let root = repo_root();
    let schema = read_json(&root.join("abi/abi.schema.json"));
    let abi = read_json(&root.join("abi/abi.json"));

    // --- Gate 1: structural (JSON Schema) ---
    let validator = jsonschema::validator_for(&schema).expect("compile abi.schema.json");
    let errors: Vec<String> = validator
        .iter_errors(&abi)
        .map(|e| format!("{} (at {})", e, e.instance_path))
        .collect();
    if !errors.is_empty() {
        eprintln!("✗ abi.json failed schema validation:");
        for e in &errors {
            eprintln!("    {e}");
        }
        std::process::exit(1);
    }
    println!("✓ structural: abi.json valid against abi.schema.json");

    // Flatten the numeric surface of abi.json: constants by name, struct sizes
    // as "<name>.size", both resolved for TARGET.
    let mut flat: BTreeMap<String, u64> = BTreeMap::new();
    for c in abi["constants"].as_array().unwrap_or(&vec![]) {
        if let (Some(name), Some(u)) = (c["name"].as_str(), resolve_int(&c["value"])) {
            flat.insert(name.to_string(), u);
        }
    }
    for s in abi["structs"].as_array().unwrap_or(&vec![]) {
        if let (Some(name), Some(u)) = (s["name"].as_str(), resolve_int(&s["size"])) {
            flat.insert(format!("{name}.size"), u);
        }
    }

    // --- Gate 2: semantic (compile + run the canonical C++ dumper) ---
    let bin = std::env::temp_dir().join("thoth_dump_abi");
    let cxx = std::env::var("CXX").unwrap_or_else(|_| "c++".to_string());
    let compile = Command::new(&cxx)
        .args([
            "-std=c++20",
            "-I",
            root.join("cpp/libipc/include").to_str().unwrap(),
            "-I",
            root.join("cpp/libipc/src").to_str().unwrap(),
            root.join("abi/dump_abi.cpp").to_str().unwrap(),
            "-o",
            bin.to_str().unwrap(),
        ])
        .status()
        .expect("invoke C++ compiler");
    if !compile.success() {
        eprintln!("✗ failed to compile abi/dump_abi.cpp (need a C++20 compiler)");
        std::process::exit(1);
    }
    let dumped = read_dumper(&bin);

    let mut checked = 0usize;
    let mut mismatches = 0usize;
    for (k, v) in dumped.as_object().expect("dumper emitted a JSON object") {
        let cpp = as_u64(v).unwrap_or_else(|| panic!("dumper value for '{k}' is not a u64"));
        match flat.get(k) {
            Some(&abi_v) if abi_v == cpp => checked += 1,
            Some(&abi_v) => {
                mismatches += 1;
                println!("  ✗ {k}: abi.json = {abi_v:#x} ({abi_v}) but C++ = {cpp:#x} ({cpp})");
            }
            None => println!("  · C++ has {k} = {cpp:#x} with no abi.json entry (extend abi.json)"),
        }
    }

    let dobj = dumped.as_object().unwrap();
    let uncovered: Vec<&str> = flat.keys().map(String::as_str).filter(|k| !dobj.contains_key(*k)).collect();

    println!("✓ semantic: {checked} value(s) match the deployed C++, {mismatches} mismatch(es)");
    if !uncovered.is_empty() {
        println!("  ({} abi.json value(s) not yet C++-dumped, matrix-verified only: {})", uncovered.len(), uncovered.join(", "));
    }
    if mismatches > 0 {
        std::process::exit(1);
    }
    println!("\n✓ ABI conformance OK");
}

fn read_dumper(bin: &Path) -> Value {
    let out = Command::new(bin).output().expect("run abi dumper");
    if !out.status.success() {
        eprintln!("✗ abi dumper exited non-zero");
        std::process::exit(1);
    }
    serde_json::from_slice(&out.stdout).expect("parse dumper JSON output")
}
