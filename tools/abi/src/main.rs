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

/// A plain string, or a per-target object resolved for `target`.
fn resolve_str<'a>(v: &'a Value, target: &str) -> Option<&'a str> {
    if let Some(s) = v.as_str() {
        return Some(s);
    }
    v.get(target).and_then(|x| x.as_str())
}

/// FNV-1a-64 — byte-identical to the C++ `shm_name.h` / `notify.h` hash.
fn fnv1a_64(data: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in data {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

/// Reference `make_shm_name` — the POSIX shm-name shortening, byte-identical to
/// C++ `shm_name.h` and every port: prepend '/', and if that exceeds
/// `shm_name_max` (> 0), replace with `/<first 13 body chars>_<16-hex fnv1a of the
/// whole /-name>`. `shm_name_max == 0` disables shortening (off macOS).
fn make_shm_name(name: &str, shm_name_max: usize) -> String {
    let result = if name.starts_with('/') { name.to_string() } else { format!("/{name}") };
    if shm_name_max == 0 || result.len() <= shm_name_max {
        return result;
    }
    let hash = fnv1a_64(result.as_bytes());
    let prefix_len = if shm_name_max > 17 + 1 { shm_name_max - 17 - 1 } else { 0 };
    let body: String = result.chars().skip(1).take(prefix_len).collect();
    format!("/{body}_{hash:016x}")
}

/// Naming gate: for each `names[]` template, (a) resolve it against the canonical
/// binding (prefix="", name="xchan", data_length, align_size per-target,
/// chunk_size=1024) and check it equals the stored golden, and (b) diff the name
/// C++ actually built (`dumped["name:<n>"]`, via make_public_abi_prefix) against
/// that golden — making C++ a checked peer for the shm-name contract. Then
/// independently recompute the notify FNV-1a-64. Returns true on full agreement.
fn check_naming(abi: &Value, target: &str, dumped: &serde_json::Map<String, Value>) -> bool {
    let constant = |n: &str| abi["constants"].as_array().unwrap().iter().find(|c| c["name"] == n);
    let data_length = constant("data_length").and_then(|c| resolve_int(&c["value"], target)).expect("data_length");
    let align_size = resolve_int(&abi["targets"][target]["align_size"], target)
        .unwrap_or_else(|| panic!("no align_size for target '{target}'"));
    let shm_name_max = resolve_int(&abi["targets"][target]["shm_name_max"], target).unwrap_or(0) as usize;
    let notify_hash = constant("notify_hash_xchan").and_then(|c| c["value"].as_str()).expect("notify_hash_xchan");

    let subst = |t: &str| t
        .replace("{prefix}", "")
        .replace("{name}", "xchan")
        .replace("{data_length}", &data_length.to_string())
        .replace("{align_size}", &align_size.to_string())
        .replace("{chunk_size}", "1024")
        .replace("{notify_hash}", notify_hash);

    let (mut ok, mut cpp_ok, mut posix_ok, mut bad) = (0usize, 0usize, 0usize, 0usize);
    for n in abi["names"].as_array().unwrap_or(&vec![]) {
        let name = n["name"].as_str().unwrap();
        let Some(golden) = n.get("golden").and_then(|g| resolve_str(g, target)) else { continue };
        // (a) template resolution vs golden — abi.json self-consistency.
        let resolved = subst(n["template"].as_str().unwrap());
        if resolved == golden {
            ok += 1;
        } else {
            bad += 1;
            println!("  ✗ name {name}: template resolves to {resolved:?} but golden = {golden:?}");
        }
        // (b) the name C++ actually built vs golden — make_public_abi_prefix checked peer.
        if let Some(cpp) = dumped.get(&format!("name:{name}")).and_then(|v| v.as_str()) {
            if cpp == golden {
                cpp_ok += 1;
            } else {
                bad += 1;
                println!("  ✗ name {name}: C++ built {cpp:?} but golden = {golden:?}");
            }
        }
        // (c) POSIX shortening: reference make_shm_name(golden) vs posix_golden.
        if let Some(pg) = n.get("posix_golden").and_then(|g| resolve_str(g, target)) {
            let computed = make_shm_name(golden, shm_name_max);
            if computed == pg {
                posix_ok += 1;
            } else {
                bad += 1;
                println!("  ✗ name {name}: make_shm_name({golden:?}) = {computed:?} but posix_golden = {pg:?}");
            }
        }
    }

    // Independent check of the notify_hash golden: hash make_public_abi_prefix("", "NOTIFY__", "xchan").
    let notify_id = "__THOTH_SHM__NOTIFY__xchan";
    let computed = format!("{:016x}", fnv1a_64(notify_id.as_bytes()));
    let fnv_ok = computed == notify_hash;
    if !fnv_ok {
        bad += 1;
        println!("  ✗ notify_hash: fnv1a_64({notify_id:?}) = {computed} but abi.json = {notify_hash}");
    }

    println!(
        "{} naming ({target}): {ok} template(s) + {cpp_ok} C++-built name(s) match golden; \
         {posix_ok} shortened POSIX name(s) match; notify FNV-1a-64 {}",
        if bad == 0 { "✓" } else { "✗" },
        if fnv_ok { "verified" } else { "FAILED" }
    );
    bad == 0
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let root = repo_root();
    match args.get(1).map(String::as_str) {
        None | Some("check") => run_check(&root, &args[2..]),
        Some("generate") => run_generate(&root, &args[2..]),
        Some(other) => {
            eprintln!("unknown subcommand '{other}' (expected: check | generate)");
            std::process::exit(2);
        }
    }
}

// ---------------------------------------------------------------- check -------

/// The target this checker binary was built for — so `check` on a Linux x86_64
/// CI host resolves the x86_64 abi values, not apple's.
fn host_target() -> &'static str {
    if cfg!(all(target_arch = "aarch64", target_vendor = "apple")) { "apple_arm64" } else { "x86_64" }
}

fn run_check(root: &Path, args: &[String]) {
    // `check [--target <t>]` — default to the host target; a non-host target
    // cross-compiles the dumper (macOS `-arch`, run under Rosetta) for a local
    // per-target check without needing a second machine.
    let mut target = host_target().to_string();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if a == "--target" {
            target = it.next().expect("--target needs a value").clone();
        }
    }
    let schema = read_json(&root.join("abi/abi.schema.json"));
    let abi = read_json(&root.join("abi/abi.json"));

    let validator = jsonschema::validator_for(&schema).expect("compile abi.schema.json");
    let errors: Vec<String> = validator
        .iter_errors(&abi)
        .map(|e| format!("{} (at {})", e, e.instance_path()))
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
        if let (Some(name), Some(u)) = (c["name"].as_str(), resolve_int(&c["value"], &target)) {
            flat.insert(name.to_string(), u);
        }
    }
    for s in abi["structs"].as_array().unwrap_or(&vec![]) {
        if let (Some(name), Some(u)) = (s["name"].as_str(), resolve_int(&s["size"], &target)) {
            flat.insert(format!("{name}.size"), u);
        }
    }

    let bin = std::env::temp_dir().join(format!("thoth_dump_abi_{target}"));
    let cxx = std::env::var("CXX").unwrap_or_else(|_| "c++".to_string());
    let mut cmd = Command::new(&cxx);
    cmd.arg("-std=c++20");
    if target != host_target() {
        // Local cross-target check: build for the other align class and let Rosetta
        // run it. macOS-only (`-arch`); the default host check needs no cross-arch.
        let arch = match target.as_str() {
            "x86_64" => "x86_64",
            "apple_arm64" => "arm64",
            t => {
                eprintln!("✗ no cross-compile arch for target '{t}' (host is {})", host_target());
                std::process::exit(2);
            }
        };
        cmd.arg("-arch").arg(arch);
    }
    cmd.args([
        "-I",
        root.join("cpp/thoth-ipc/include").to_str().unwrap(),
        "-I",
        root.join("cpp/thoth-ipc/src").to_str().unwrap(),
        root.join("abi/dump_abi.cpp").to_str().unwrap(),
        "-o",
        bin.to_str().unwrap(),
    ]);
    let compile = cmd.status().expect("invoke C++ compiler");
    if !compile.success() {
        eprintln!("✗ failed to compile abi/dump_abi.cpp (need a C++20 compiler)");
        std::process::exit(1);
    }
    let out = Command::new(&bin).output().expect("run abi dumper");
    let dumped: Value = serde_json::from_slice(&out.stdout).expect("parse dumper JSON output");

    let (mut checked, mut mismatches) = (0usize, 0usize);
    let dobj = dumped.as_object().expect("dumper emitted a JSON object");
    for (k, v) in dobj {
        let Some(cpp) = as_u64(v) else { continue }; // "name:*" strings checked by check_naming
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
    println!("✓ semantic ({target}): {checked} value(s) match the deployed C++, {mismatches} mismatch(es)");
    if !uncovered.is_empty() {
        println!(
            "  ({} not dumper-reachable (types in heavier headers) — each a compile-time \
             static_assert checked-peer vs thoth::abi in its own TU (sync_abi.h / secure_codec.h), \
             plus xlang-matrix verified: {})",
            uncovered.len(),
            uncovered.join(", ")
        );
    }
    let naming_ok = check_naming(&abi, &target, dobj);

    if mismatches > 0 || !naming_ok {
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
        // Every port generates into its own tree and consumes the module.
        "zig" => (gen_zig(&abi, &target), root.join("zig/thoth-ipc/src/abi_generated.zig")),
        "rust" => (gen_rust(&abi, &target), root.join("rust/thoth-ipc/src/abi_generated.rs")),
        "swift" => (gen_swift(&abi, &target), root.join("swift/thoth-ipc/Sources/ThothIPC/Generated/abi_generated.swift")),
        "cpp" => (gen_cpp(&abi, &target), root.join("cpp/thoth-ipc/include/thoth-ipc/abi_generated.hpp")),
        other => {
            eprintln!("no generator for language '{other}' (have: zig, rust, swift, cpp)");
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

    o.push_str("\n// --- shm-name goldens (canonical binding — see abi/README.md) ---\n");
    for n in abi["names"].as_array().unwrap_or(&vec![]) {
        let nm = n["name"].as_str().unwrap();
        if let Some(g) = n.get("golden").and_then(|g| resolve_str(g, target)) {
            o.push_str(&format!("pub const name_golden_{nm}: []const u8 = {g:?};\n"));
        }
        if let Some(p) = n.get("posix_golden").and_then(|g| resolve_str(g, target)) {
            o.push_str(&format!("pub const name_golden_{nm}_posix: []const u8 = {p:?};\n"));
        }
    }
    o
}

/// Render a numeric value: hex strings verbatim (0x…), integers as decimal,
/// per-target objects resolved for `target`. Language-agnostic; a per-language
/// integer-literal suffix (e.g. C++ `ull`) is appended by the caller.
fn zig_num(v: &Value, target: &str) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Object(_) => resolve_int(v, target).unwrap().to_string(),
        _ => panic!("unrenderable numeric value {v:?}"),
    }
}

fn gen_header(o: &mut String, lang: &str, target: &str, comment: &str) {
    o.push_str(&format!("{comment} SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT\n"));
    o.push_str(&format!("{comment} SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors\n{comment}\n"));
    o.push_str(&format!("{comment} @generated by `tools/abi` from abi/abi.json — DO NOT EDIT.\n"));
    o.push_str(&format!("{comment} Regenerate: cargo run --manifest-path tools/abi/Cargo.toml -- generate --lang {lang}\n"));
    o.push_str(&format!("{comment} Target: {target}.\n"));
}

fn each_field(s: &Value) -> impl Iterator<Item = &Value> {
    s["fields"].as_array().map(|v| v.as_slice()).unwrap_or(&[]).iter()
}

// ---- per-target emission (dedup + align-gating) --------------------------------
//
// Most ABI values are identical on every target and are emitted once, ungated.
// The few that depend on AlignSize (8 on apple_arm64, 16 elsewhere) are emitted
// as align-gated variants — but only for the multi-platform ports (Rust, C++).
// Swift/Zig are macOS-arm64-only, so they always resolve to `apple_arm64`.

/// abi.json targets, `apple_arm64` (the align-8 target) first, others after.
fn targets(abi: &Value) -> Vec<String> {
    let mut ts: Vec<String> = abi["targets"].as_object().unwrap().keys().cloned().collect();
    ts.sort_by_key(|t| (t != "apple_arm64", t.clone()));
    ts
}

/// The Rust `cfg` predicate that selects `target`: apple_arm64 gets the positive
/// align-8 predicate, every other (align-16) target is its negation.
fn rust_cfg(target: &str) -> &'static str {
    match target {
        // align-8 class: apple_arm64 and any MSVC-ABI target (windows-msvc has 8-byte max align),
        // mirroring the C++ `|| defined(_MSC_VER)` guard in emit_cpp.
        "apple_arm64" => "#[cfg(any(all(target_arch = \"aarch64\", target_vendor = \"apple\"), target_env = \"msvc\"))]",
        _ => "#[cfg(not(any(all(target_arch = \"aarch64\", target_vendor = \"apple\"), target_env = \"msvc\")))]",
    }
}

/// Emit `<prefix> = <value>;` — once if `render` is identical across targets,
/// else one `#[cfg]`-gated line per target.
fn emit_rust(o: &mut String, prefix: &str, ts: &[String], render: impl Fn(&str) -> String) {
    if ts.iter().all(|t| render(t) == render(&ts[0])) {
        o.push_str(&format!("{prefix} = {};\n", render(&ts[0])));
    } else {
        for t in ts {
            o.push_str(&format!("{}\n{prefix} = {};\n", rust_cfg(t), render(t)));
        }
    }
}

/// C++ analogue: one line if uniform, else an `#if/#else/#endif` over the two
/// align classes (apple_arm64 vs everything else).
fn emit_cpp(o: &mut String, prefix: &str, suffix: &str, ts: &[String], render: impl Fn(&str) -> String) {
    if ts.iter().all(|t| render(t) == render(&ts[0])) {
        o.push_str(&format!("{prefix} = {}{suffix};\n", render(&ts[0])));
    } else {
        let other = ts.iter().find(|t| *t != "apple_arm64").expect("need a non-apple target");
        // The align-8 class is `alignof(max_align_t) == 8`, not "Apple only": MSVC x64/arm64 has an
        // 8-byte max_align (long double == double), so it selects the apple_arm64 (align-8) values.
        // clang-cl defines _MSC_VER too; MinGW (align-16) does not. NOTE: for the POSIX-shortened
        // `*_posix` shm-name goldens this also hands MSVC the macOS-shortened string, which is wrong
        // in principle -- but POSIX shm names are #if'd out on Windows (it uses named kernel objects),
        // so that constant is unused there. Formalizing a distinct windows_x64 abi target (align-8 +
        // shm_name_max=0) is the proper follow-up.
        o.push_str("#if (defined(__APPLE__) && defined(__aarch64__)) || defined(_MSC_VER)\n");
        o.push_str(&format!("{prefix} = {}{suffix};\n", render("apple_arm64")));
        o.push_str("#else\n");
        o.push_str(&format!("{prefix} = {}{suffix};\n", render(other)));
        o.push_str("#endif\n");
    }
}

// ---- Rust ----

fn rust_type(t: &str) -> &str {
    match t {
        "u8" | "u16" | "u32" | "u64" | "i32" | "usize" => t,
        other => panic!("unmapped scalar type '{other}'"),
    }
}

fn gen_rust(abi: &Value, _target: &str) -> String {
    let ts = targets(abi);
    let mut o = String::new();
    gen_header(&mut o, "rust", &ts.join(" / "), "//");
    o.push_str("#![allow(non_upper_case_globals, non_camel_case_types, dead_code)]\n\n");
    o.push_str(&format!("pub const abi_version: &str = \"{}\";\n\n", abi["version"].as_str().unwrap()));

    o.push_str("// --- constants ---\n");
    for c in abi["constants"].as_array().unwrap() {
        let (name, ty) = (c["name"].as_str().unwrap(), c["type"].as_str().unwrap());
        if let Some(d) = c["description"].as_str() {
            o.push_str(&format!("/// {d}\n"));
        }
        if ty == "string" {
            o.push_str(&format!("pub const {name}: &str = \"{}\";\n", c["value"].as_str().unwrap()));
        } else {
            emit_rust(&mut o, &format!("pub const {name}: {}", rust_type(ty)), &ts, |t| zig_num(&c["value"], t));
        }
    }

    o.push_str("\n// --- enums ---\n");
    for e in abi["enums"].as_array().unwrap_or(&Vec::new()) {
        let name = e["name"].as_str().unwrap();
        if let Some(d) = e["description"].as_str() {
            o.push_str(&format!("/// {d}\n"));
        }
        o.push_str(&format!("#[repr({})]\npub enum {name} {{\n", rust_type(e["type"].as_str().unwrap())));
        for v in e["values"].as_array().unwrap() {
            o.push_str(&format!("    {} = {},\n", v["name"].as_str().unwrap(), v["value"].as_i64().unwrap()));
        }
        o.push_str("}\n");
    }

    o.push_str("\n// --- struct layout (byte sizes + field offsets) ---\n");
    for s in abi["structs"].as_array().unwrap() {
        let name = s["name"].as_str().unwrap();
        emit_rust(&mut o, &format!("pub const {name}_size: usize"), &ts, |t| resolve_int(&s["size"], t).unwrap().to_string());
        for f in each_field(s) {
            let fname = f["name"].as_str().unwrap();
            emit_rust(&mut o, &format!("pub const {name}_{fname}_off: usize"), &ts, |t| resolve_int(&f["offset"], t).unwrap().to_string());
        }
    }

    o.push_str("\n// --- shm-name goldens (canonical binding — see abi/README.md) ---\n");
    for n in abi["names"].as_array().unwrap_or(&Vec::new()) {
        let nm = n["name"].as_str().unwrap();
        if n.get("golden").is_some() {
            emit_rust(&mut o, &format!("pub const name_golden_{nm}: &str"), &ts, |t| format!("{:?}", resolve_str(&n["golden"], t).unwrap()));
        }
        if n.get("posix_golden").is_some() {
            emit_rust(&mut o, &format!("pub const name_golden_{nm}_posix: &str"), &ts, |t| format!("{:?}", resolve_str(&n["posix_golden"], t).unwrap()));
        }
    }
    o
}

// ---- Swift (namespaced in a caseless enum) ----

fn swift_type(t: &str) -> &str {
    match t {
        "u8" => "UInt8",
        "u16" => "UInt16",
        "u32" => "UInt32",
        "u64" => "UInt64",
        "i32" => "Int32",
        "usize" => "Int",
        other => panic!("unmapped scalar type '{other}'"),
    }
}

fn gen_swift(abi: &Value, target: &str) -> String {
    let mut o = String::new();
    gen_header(&mut o, "swift", target, "//");
    o.push_str("\npublic enum ABI {\n");
    o.push_str(&format!("    public static let abi_version: String = \"{}\"\n\n", abi["version"].as_str().unwrap()));

    o.push_str("    // MARK: constants\n");
    for c in abi["constants"].as_array().unwrap() {
        let (name, ty) = (c["name"].as_str().unwrap(), c["type"].as_str().unwrap());
        if let Some(d) = c["description"].as_str() {
            o.push_str(&format!("    /// {d}\n"));
        }
        if ty == "string" {
            o.push_str(&format!("    public static let {name}: String = \"{}\"\n", c["value"].as_str().unwrap()));
        } else {
            o.push_str(&format!("    public static let {name}: {} = {}\n", swift_type(ty), zig_num(&c["value"], target)));
        }
    }

    o.push_str("\n    // MARK: enums\n");
    for e in abi["enums"].as_array().unwrap_or(&Vec::new()) {
        let name = e["name"].as_str().unwrap();
        if let Some(d) = e["description"].as_str() {
            o.push_str(&format!("    /// {d}\n"));
        }
        o.push_str(&format!("    public enum {name}: {} {{\n", swift_type(e["type"].as_str().unwrap())));
        for v in e["values"].as_array().unwrap() {
            o.push_str(&format!("        case {} = {}\n", v["name"].as_str().unwrap(), v["value"].as_i64().unwrap()));
        }
        o.push_str("    }\n");
    }

    o.push_str("\n    // MARK: struct layout (byte sizes + field offsets)\n");
    for s in abi["structs"].as_array().unwrap() {
        let name = s["name"].as_str().unwrap();
        o.push_str(&format!("    public static let {name}_size: Int = {}\n", resolve_int(&s["size"], target).unwrap()));
        for f in each_field(s) {
            o.push_str(&format!("    public static let {name}_{}_off: Int = {}\n", f["name"].as_str().unwrap(), resolve_int(&f["offset"], target).unwrap()));
        }
    }

    o.push_str("\n    // MARK: shm-name goldens (canonical binding — see abi/README.md)\n");
    for n in abi["names"].as_array().unwrap_or(&vec![]) {
        let nm = n["name"].as_str().unwrap();
        if let Some(g) = n.get("golden").and_then(|g| resolve_str(g, target)) {
            o.push_str(&format!("    public static let name_golden_{nm}: String = {g:?}\n"));
        }
        if let Some(p) = n.get("posix_golden").and_then(|g| resolve_str(g, target)) {
            o.push_str(&format!("    public static let name_golden_{nm}_posix: String = {p:?}\n"));
        }
    }
    o.push_str("}\n");
    o
}

// ---- C++ ----

fn cpp_type(t: &str) -> &str {
    match t {
        "u8" => "std::uint8_t",
        "u16" => "std::uint16_t",
        "u32" => "std::uint32_t",
        "u64" => "std::uint64_t",
        "i32" => "std::int32_t",
        "usize" => "std::size_t",
        other => panic!("unmapped scalar type '{other}'"),
    }
}

fn gen_cpp(abi: &Value, _target: &str) -> String {
    let ts = targets(abi);
    let mut o = String::new();
    gen_header(&mut o, "cpp", &ts.join(" / "), "//");
    o.push_str("\n#pragma once\n#include <cstddef>\n#include <cstdint>\n\nnamespace thoth::abi {\n\n");
    o.push_str(&format!("inline constexpr const char* abi_version = \"{}\";\n\n", abi["version"].as_str().unwrap()));

    o.push_str("// --- constants ---\n");
    for c in abi["constants"].as_array().unwrap() {
        let (name, ty) = (c["name"].as_str().unwrap(), c["type"].as_str().unwrap());
        if let Some(d) = c["description"].as_str() {
            o.push_str(&format!("/// {d}\n"));
        }
        if ty == "string" {
            o.push_str(&format!("inline constexpr const char* {name} = \"{}\";\n", c["value"].as_str().unwrap()));
        } else {
            let suffix = if ty == "u64" { "ull" } else { "" };
            emit_cpp(&mut o, &format!("inline constexpr {} {name}", cpp_type(ty)), suffix, &ts, |t| zig_num(&c["value"], t));
        }
    }

    o.push_str("\n// --- enums ---\n");
    for e in abi["enums"].as_array().unwrap_or(&Vec::new()) {
        let name = e["name"].as_str().unwrap();
        if let Some(d) = e["description"].as_str() {
            o.push_str(&format!("/// {d}\n"));
        }
        o.push_str(&format!("enum class {name} : {} {{ ", cpp_type(e["type"].as_str().unwrap())));
        let parts: Vec<String> = e["values"].as_array().unwrap().iter()
            .map(|v| format!("{} = {}", v["name"].as_str().unwrap(), v["value"].as_i64().unwrap()))
            .collect();
        o.push_str(&format!("{} }};\n", parts.join(", ")));
    }

    o.push_str("\n// --- struct layout (byte sizes + field offsets) ---\n");
    for s in abi["structs"].as_array().unwrap() {
        let name = s["name"].as_str().unwrap();
        emit_cpp(&mut o, &format!("inline constexpr std::size_t {name}_size"), "", &ts, |t| resolve_int(&s["size"], t).unwrap().to_string());
        for f in each_field(s) {
            let fname = f["name"].as_str().unwrap();
            emit_cpp(&mut o, &format!("inline constexpr std::size_t {name}_{fname}_off"), "", &ts, |t| resolve_int(&f["offset"], t).unwrap().to_string());
        }
    }

    o.push_str("\n// --- shm-name goldens (canonical binding — see abi/README.md) ---\n");
    for n in abi["names"].as_array().unwrap_or(&Vec::new()) {
        let nm = n["name"].as_str().unwrap();
        if n.get("golden").is_some() {
            emit_cpp(&mut o, &format!("inline constexpr const char* name_golden_{nm}"), "", &ts, |t| format!("{:?}", resolve_str(&n["golden"], t).unwrap()));
        }
        if n.get("posix_golden").is_some() {
            emit_cpp(&mut o, &format!("inline constexpr const char* name_golden_{nm}_posix"), "", &ts, |t| format!("{:?}", resolve_str(&n["posix_golden"], t).unwrap()));
        }
    }
    o.push_str("\n} // namespace thoth::abi\n");
    o
}
