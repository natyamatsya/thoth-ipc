// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// ABI tooling for the language-neutral IDL (abi/abi.json).
//
//   check    (default) — validate abi.json against abi/abi.schema.json (JSON
//            Schema, structural gate), then compile+run abi/dump_abi.cpp and diff
//            its ground-truth values against abi.json (semantic gate). The xlang
//            matrix remains the behavioural gate.
//   generate --lang <zig> [--target apple_arm64] [--out PATH] [--check]
//            emit a per-language constant module from abi.json. `--check` fails
//            (exit 1) if the on-disk file differs — the CI staleness gate.
//
// Run from repo root: cargo run --manifest-path tools/abi/Cargo.toml [-- ...]

use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

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

/// A plain integer, or a per-target object resolved for `target`.
fn resolve_int(v: &Value, target: &str) -> Option<u64> {
    if let Some(u) = as_u64(v) {
        return Some(u);
    }
    v.get(target).and_then(as_u64)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let root = repo_root();
    match args.get(1).map(String::as_str) {
        None | Some("check") => run_check(&root),
        Some("generate") => run_generate(&root, &args[2..]),
        Some(other) => {
            eprintln!("unknown subcommand '{other}' (expected: check | generate)");
            std::process::exit(2);
        }
    }
}

// ---------------------------------------------------------------- check -------

fn run_check(root: &Path) {
    let schema = read_json(&root.join("abi/abi.schema.json"));
    let abi = read_json(&root.join("abi/abi.json"));

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

    let mut flat: BTreeMap<String, u64> = BTreeMap::new();
    for c in abi["constants"].as_array().unwrap_or(&vec![]) {
        if let (Some(name), Some(u)) = (c["name"].as_str(), resolve_int(&c["value"], TARGET)) {
            flat.insert(name.to_string(), u);
        }
    }
    for s in abi["structs"].as_array().unwrap_or(&vec![]) {
        if let (Some(name), Some(u)) = (s["name"].as_str(), resolve_int(&s["size"], TARGET)) {
            flat.insert(format!("{name}.size"), u);
        }
    }

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
    let out = Command::new(&bin).output().expect("run abi dumper");
    let dumped: Value = serde_json::from_slice(&out.stdout).expect("parse dumper JSON output");

    let (mut checked, mut mismatches) = (0usize, 0usize);
    let dobj = dumped.as_object().expect("dumper emitted a JSON object");
    for (k, v) in dobj {
        let cpp = as_u64(v).unwrap_or_else(|| panic!("dumper value for '{k}' is not a u64"));
        match flat.get(k) {
            Some(&abi_v) if abi_v == cpp => checked += 1,
            Some(&abi_v) => {
                mismatches += 1;
                println!("  ✗ {k}: abi.json = {abi_v:#x} ({abi_v}) but C++ = {cpp:#x} ({cpp})");
            }
            None => println!("  · C++ has {k} = {cpp:#x} with no abi.json entry"),
        }
    }
    let uncovered: Vec<&str> = flat.keys().map(String::as_str).filter(|k| !dobj.contains_key(*k)).collect();
    println!("✓ semantic: {checked} value(s) match the deployed C++, {mismatches} mismatch(es)");
    if !uncovered.is_empty() {
        println!("  ({} not yet C++-dumped, matrix-verified only: {})", uncovered.len(), uncovered.join(", "));
    }
    if mismatches > 0 {
        std::process::exit(1);
    }
    println!("\n✓ ABI conformance OK");
}

// ------------------------------------------------------------- generate -------

fn run_generate(root: &Path, args: &[String]) {
    let mut lang = "zig".to_string();
    let mut target = TARGET.to_string();
    let mut out: Option<PathBuf> = None;
    let mut check = false;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--lang" => lang = it.next().expect("--lang needs a value").clone(),
            "--target" => target = it.next().expect("--target needs a value").clone(),
            "--out" => out = Some(PathBuf::from(it.next().expect("--out needs a value"))),
            "--check" => check = true,
            other => {
                eprintln!("unknown generate flag '{other}'");
                std::process::exit(2);
            }
        }
    }

    let abi = read_json(&root.join("abi/abi.json"));
    let (rendered, default_out) = match lang.as_str() {
        "zig" => (gen_zig(&abi, &target), root.join("zig/libipc/src/abi_generated.zig")),
        other => {
            eprintln!("no generator for language '{other}' yet (have: zig)");
            std::process::exit(2);
        }
    };
    let out = out.unwrap_or(default_out);

    if check {
        let current = std::fs::read_to_string(&out).unwrap_or_default();
        if current != rendered {
            eprintln!("✗ {} is stale — regenerate: cargo run --manifest-path tools/abi/Cargo.toml -- generate --lang {lang}", out.display());
            std::process::exit(1);
        }
        println!("✓ {} is up to date with abi.json", out.display());
    } else {
        std::fs::write(&out, &rendered).unwrap_or_else(|e| panic!("write {}: {e}", out.display()));
        println!("✓ wrote {} ({} bytes) for target {target}", out.display(), rendered.len());
    }
}

fn zig_int_type(t: &str) -> &str {
    match t {
        "u8" | "u16" | "u32" | "u64" | "i32" | "usize" => t,
        other => panic!("unmapped scalar type '{other}'"),
    }
}

fn gen_zig(abi: &Value, target: &str) -> String {
    let mut o = String::new();
    o.push_str("// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT\n");
    o.push_str("// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors\n//\n");
    o.push_str("// @generated by `tools/abi` from abi/abi.json — DO NOT EDIT.\n");
    o.push_str(&format!(
        "// Regenerate: cargo run --manifest-path tools/abi/Cargo.toml -- generate --lang zig\n// Target: {target}.\n\n",
    ));

    o.push_str("/// ABI contract version (semver; decoupled from the release version). Peers\n");
    o.push_str("/// interoperate iff they share the same MAJOR. See abi/README.md#abi-versioning.\n");
    o.push_str(&format!("pub const abi_version: []const u8 = \"{}\";\n\n", abi["version"].as_str().unwrap()));

    o.push_str("// --- constants ---\n");
    for c in abi["constants"].as_array().unwrap() {
        let name = c["name"].as_str().unwrap();
        let ty = c["type"].as_str().unwrap();
        if let Some(d) = c["description"].as_str() {
            o.push_str(&format!("/// {d}\n"));
        }
        if ty == "string" {
            o.push_str(&format!("pub const {name}: []const u8 = \"{}\";\n", c["value"].as_str().unwrap()));
        } else {
            o.push_str(&format!("pub const {name}: {} = {};\n", zig_int_type(ty), zig_num(&c["value"], target)));
        }
    }

    o.push_str("\n// --- enums ---\n");
    for e in abi["enums"].as_array().unwrap_or(&vec![]) {
        let name = e["name"].as_str().unwrap();
        if let Some(d) = e["description"].as_str() {
            o.push_str(&format!("/// {d}\n"));
        }
        o.push_str(&format!("pub const {name} = enum({}) {{\n", zig_int_type(e["type"].as_str().unwrap())));
        for v in e["values"].as_array().unwrap() {
            o.push_str(&format!("    {} = {},\n", v["name"].as_str().unwrap(), v["value"].as_i64().unwrap()));
        }
        o.push_str("};\n");
    }

    o.push_str("\n// --- struct layout (byte sizes + field offsets) ---\n");
    for s in abi["structs"].as_array().unwrap() {
        let name = s["name"].as_str().unwrap();
        if let Some(d) = s["description"].as_str() {
            o.push_str(&format!("/// {d}\n"));
        }
        o.push_str(&format!("pub const {name}_size: usize = {};\n", resolve_int(&s["size"], target).unwrap()));
        for f in s["fields"].as_array().unwrap_or(&vec![]) {
            let fname = f["name"].as_str().unwrap();
            o.push_str(&format!("pub const {name}_{fname}_off: usize = {};\n", resolve_int(&f["offset"], target).unwrap()));
        }
    }
    o
}

/// Render a numeric value for Zig: hex strings verbatim (0x…), integers as
/// decimal, per-target objects resolved for `target`.
fn zig_num(v: &Value, target: &str) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Object(_) => resolve_int(v, target).unwrap().to_string(),
        _ => panic!("unrenderable numeric value {v:?}"),
    }
}
