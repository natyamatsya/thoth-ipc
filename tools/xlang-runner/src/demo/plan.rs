// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Demo-matrix planning: resolve which languages ship each demo on this host,
// then expand every assignment of those languages to the demo's slots into a
// concrete case (binaries, argv, readiness and output patterns).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use regex::Regex;

use super::config::{Demo, DemoFile, ProcSpec};
use crate::cases::PlanNote;
use crate::config::expand_env;

/// One process of a planned case.
pub struct CaseProc {
    /// `role[lang]`, for reports.
    pub label: String,
    pub bin: PathBuf,
    pub args: Vec<String>,
    pub ready: Option<Regex>,
    pub exit: i32,
    pub expect: Vec<LineExpect>,
}

pub struct LineExpect {
    pub pattern: Regex,
    /// Exact count, or None for "at least one".
    pub count: Option<usize>,
}

pub struct DemoCase {
    pub demo: String,
    pub id: String,
    /// Cases with the same group must not run concurrently.
    pub serial_group: Option<String>,
    /// Binary + argv that removes the demo's IPC objects.
    pub clear: Option<(PathBuf, Vec<String>)>,
    pub procs: Vec<CaseProc>,
    pub xfail: bool,
}

pub struct DemoPlan {
    pub cases: Vec<DemoCase>,
    pub notes: Vec<PlanNote>,
    /// Language -> the demos it takes part in (for `--require`).
    pub coverage: BTreeMap<String, Vec<String>>,
}

/// Per-case values the placeholders expand to.
struct Ctx<'a> {
    count: usize,
    total: usize,
    fanin: usize,
    index: usize,
    lang: &'a str,
    slots: &'a BTreeMap<String, String>,
    ch_prefix: &'a str,
    each: Option<&'a str>,
    paths: &'a dyn Fn(&str, &str) -> Option<PathBuf>,
}

/// Expand `{...}` placeholders in `template`; regex-escape values if `escape`.
fn expand(template: &str, ctx: &Ctx, escape: bool) -> Result<String, String> {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(start) = rest.find('{') {
        out.push_str(&rest[..start]);
        let after = &rest[start + 1..];
        let Some(end) = after.find('}') else {
            return Err(format!("unterminated placeholder in '{template}'"));
        };
        let key = &after[..end];
        // A regex quantifier such as `\d{2}` is not a placeholder: keep it.
        if key.is_empty() || key.chars().all(|c| c.is_ascii_digit() || c == ',') {
            out.push('{');
            out.push_str(key);
            out.push('}');
            rest = &after[end + 1..];
            continue;
        }
        let value = match key.split_once(':') {
            None => match key {
                "count" => ctx.count.to_string(),
                "total" => ctx.total.to_string(),
                "fanin" => ctx.fanin.to_string(),
                "index" => ctx.index.to_string(),
                "lang" => ctx.lang.to_string(),
                "each" => ctx
                    .each
                    .ok_or_else(|| {
                        format!("{{each}} outside a for_each_language expectation in '{template}'")
                    })?
                    .to_string(),
                _ => return Err(format!("unknown placeholder {{{key}}} in '{template}'")),
            },
            Some(("lang", slot)) => ctx
                .slots
                .get(slot)
                .cloned()
                .ok_or_else(|| format!("unknown slot '{slot}' in '{template}'"))?,
            Some(("ch", name)) => format!("{}{name}", ctx.ch_prefix),
            Some(("path", spec)) => {
                let (bin, slot) = spec
                    .split_once('@')
                    .ok_or_else(|| format!("{{path:BIN@SLOT}} expected in '{template}'"))?;
                let lang = ctx
                    .slots
                    .get(slot)
                    .ok_or_else(|| format!("unknown slot '{slot}' in '{template}'"))?;
                (ctx.paths)(bin, lang)
                    .ok_or_else(|| format!("no binary '{bin}' for {lang} in '{template}'"))?
                    .display()
                    .to_string()
            }
            _ => return Err(format!("unknown placeholder {{{key}}} in '{template}'")),
        };
        out.push_str(&if escape { regex::escape(&value) } else { value });
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

fn compile(pattern: &str) -> Result<Regex, String> {
    Regex::new(pattern).map_err(|e| format!("bad pattern '{pattern}': {e}"))
}

/// The binary `bin` of `lang` for `demo`, if the language dir is set and ships it.
fn resolve_bin(
    dirs: &BTreeMap<String, PathBuf>,
    demo: &Demo,
    bin: &str,
    lang: &str,
) -> Option<PathBuf> {
    let file = demo.bins.get(bin)?.get(lang)?;
    let path = dirs.get(lang)?.join(file);
    is_executable(&path).then_some(path)
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

/// Every assignment of a language of `langs[i]` to each `slots[i]`, in
/// lexicographic order.
fn product(slots: &[String], langs: &[&[String]]) -> Vec<BTreeMap<String, String>> {
    let mut out = vec![BTreeMap::new()];
    for (slot, langs) in slots.iter().zip(langs) {
        let mut next = Vec::with_capacity(out.len() * langs.len());
        for partial in &out {
            for lang in langs.iter() {
                let mut a = partial.clone();
                a.insert(slot.clone(), lang.clone());
                next.push(a);
            }
        }
        out = next;
    }
    out
}

pub fn plan(file: &DemoFile, filter: &[String]) -> Result<DemoPlan, String> {
    let mut notes = Vec::new();
    let mut dirs: BTreeMap<String, PathBuf> = BTreeMap::new();
    for (lang, cfg) in &file.languages {
        match expand_env(&cfg.dir) {
            Ok(dir) => {
                dirs.insert(lang.clone(), PathBuf::from(dir));
            }
            Err(var) => notes.push(PlanNote {
                scenario: "*".into(),
                lang: lang.clone(),
                reason: format!("unavailable: environment variable ${{{var}}} unset"),
            }),
        }
    }

    let mut cases = Vec::new();
    let mut coverage: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (name, demo) in &file.demos {
        if !filter.is_empty() && !filter.iter().any(|f| f == name) {
            continue;
        }
        // Each slot, and the `each_language` roles together, takes the
        // languages that ship every binary its processes run here, so a port
        // of only one role (an FFI service) can fill that role's slot. A
        // language that declares such a binary without shipping it is noted.
        let mut groups: Vec<(Option<&String>, Vec<&String>)> = Vec::new();
        for p in &demo.procs {
            match groups.iter_mut().find(|(slot, _)| *slot == p.slot.as_ref()) {
                Some((_, bins)) if !bins.contains(&&p.bin) => bins.push(&p.bin),
                Some(_) => {}
                None => groups.push((p.slot.as_ref(), vec![&p.bin])),
            }
        }
        let mut group_langs: BTreeMap<Option<&String>, Vec<String>> = BTreeMap::new();
        let mut skipped: BTreeMap<&String, Vec<&String>> = BTreeMap::new();
        for (slot, bins) in &groups {
            let mut ok = Vec::new();
            for lang in dirs.keys() {
                if !demo.languages.is_empty() && !demo.languages.contains(lang) {
                    continue;
                }
                if !bins.iter().any(|bin| demo.bins[*bin].contains_key(lang)) {
                    continue; // no port of this role in that language
                }
                let missing: Vec<&String> = bins
                    .iter()
                    .copied()
                    .filter(|bin| resolve_bin(&dirs, demo, bin, lang).is_none())
                    .collect();
                if missing.is_empty() {
                    ok.push(lang.clone());
                } else {
                    let all = skipped.entry(lang).or_default();
                    all.extend(
                        missing
                            .into_iter()
                            .filter(|m| !all.contains(m))
                            .collect::<Vec<_>>(),
                    );
                }
            }
            group_langs.insert(*slot, ok);
        }
        for (lang, missing) in &skipped {
            notes.push(PlanNote {
                scenario: name.clone(),
                lang: (*lang).clone(),
                reason: format!(
                    "skipped: binary {} not built",
                    missing
                        .iter()
                        .map(|m| m.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            });
        }
        if group_langs.values().any(|l| l.is_empty()) {
            notes.push(PlanNote {
                scenario: name.clone(),
                lang: "*".into(),
                reason: "no language ships this demo here".into(),
            });
            continue;
        }
        let mut present: Vec<&String> = group_langs.values().flatten().collect();
        present.sort();
        present.dedup();
        for lang in present {
            coverage.entry(lang.clone()).or_default().push(name.clone());
        }

        let mut slots: Vec<String> = Vec::new();
        for p in &demo.procs {
            if let Some(s) = &p.slot {
                if !slots.contains(s) {
                    slots.push(s.clone());
                }
            }
        }
        let each_langs: &[String] = group_langs.get(&None).map(Vec::as_slice).unwrap_or(&[]);
        let fan_in = demo.procs.iter().filter(|p| p.each_language).count() * each_langs.len();
        let total = if fan_in > 0 {
            demo.count * fan_in
        } else {
            demo.count
        };
        let paths = |bin: &str, lang: &str| resolve_bin(&dirs, demo, bin, lang);
        let slot_langs: Vec<&[String]> = slots
            .iter()
            .map(|s| group_langs[&Some(s)].as_slice())
            .collect();

        for (i, assign) in product(&slots, &slot_langs).into_iter().enumerate() {
            let ch_prefix = format!("dm{}_{name}_{i}_", std::process::id());
            let mut id_parts: Vec<String> =
                slots.iter().map(|s| format!("{s}={}", assign[s])).collect();
            if fan_in > 0 {
                id_parts.push(format!("+ each of {}", each_langs.join(",")));
            }
            let id = id_parts.join(" ");

            let mut procs = Vec::new();
            for spec in demo.procs.iter().filter(|p| p.spawned_by.is_none()) {
                let run_langs: Vec<&String> = match &spec.slot {
                    Some(s) => vec![&assign[s]],
                    None => each_langs.iter().collect(),
                };
                for (index, lang) in run_langs.into_iter().enumerate() {
                    procs.push(
                        case_proc(
                            spec,
                            demo,
                            &dirs,
                            lang,
                            each_langs,
                            &Ctx {
                                count: demo.count,
                                total,
                                fanin: fan_in,
                                index,
                                lang,
                                slots: &assign,
                                ch_prefix: &ch_prefix,
                                each: None,
                                paths: &paths,
                            },
                        )
                        .map_err(|e| format!("demo '{name}': {e}"))?,
                    );
                }
            }
            // The clear verb runs with the main binary of the first language in
            // the case that has one.
            let clear = (!demo.clear.is_empty())
                .then(|| {
                    slots
                        .iter()
                        .map(|s| &assign[s])
                        .chain(each_langs)
                        .find_map(|lang| {
                            resolve_bin(&dirs, demo, "main", lang)
                                .map(|bin| (bin, demo.clear.clone()))
                        })
                })
                .flatten();
            cases.push(DemoCase {
                demo: name.clone(),
                xfail: demo.xfail.iter().any(|x| id.contains(x.as_str())),
                id,
                serial_group: demo.serial.then(|| name.clone()),
                clear,
                procs,
            });
        }
    }
    Ok(DemoPlan {
        cases,
        notes,
        coverage,
    })
}

fn case_proc(
    spec: &ProcSpec,
    demo: &Demo,
    dirs: &BTreeMap<String, PathBuf>,
    lang: &str,
    each_langs: &[String],
    ctx: &Ctx,
) -> Result<CaseProc, String> {
    let ctx = Ctx { lang, ..*ctx };
    let bin = resolve_bin(dirs, demo, &spec.bin, lang)
        .ok_or_else(|| format!("role '{}': no binary for {lang}", spec.role))?;
    let args = spec
        .args
        .iter()
        .map(|a| expand(a, &ctx, false))
        .collect::<Result<Vec<_>, _>>()?;
    let ready = spec
        .ready
        .as_deref()
        .map(|r| expand(r, &ctx, true).and_then(|p| compile(&p)))
        .transpose()?;
    let mut expect = Vec::new();
    for e in &spec.expect {
        let each: Vec<Option<&str>> = if e.for_each_language {
            each_langs.iter().map(|l| Some(l.as_str())).collect()
        } else {
            vec![None]
        };
        for each in each {
            let ctx = Ctx { each, ..ctx };
            let count = e
                .count
                .as_deref()
                .map(|c| {
                    let c = expand(c, &ctx, false)?;
                    c.parse::<usize>()
                        .map_err(|_| format!("count '{c}' is not a number"))
                })
                .transpose()?;
            expect.push(LineExpect {
                pattern: compile(&expand(&e.line, &ctx, true)?)?,
                count,
            });
        }
    }
    Ok(CaseProc {
        label: format!("{}[{lang}]", spec.role),
        bin,
        args,
        ready,
        exit: spec.exit,
        expect,
    })
}
