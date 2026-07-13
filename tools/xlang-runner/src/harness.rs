// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// A harness is one per-language endpoint binary implementing the uniform CLI
// contract (write/read/aread/swrite/sread/.../clear/caps). Capabilities are
// negotiated at startup via the `caps` verb so scenarios can skip or fail fast
// instead of hanging on a harness built without a feature.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

use crate::config::{self, LanguageConfig, Mode};
use crate::exec::wait_with_timeout;

#[derive(Debug, Clone)]
pub struct Harness {
    pub name: String,
    pub bin: PathBuf,
    pub modes: BTreeSet<Mode>,
    pub caps: BTreeSet<String>,
}

impl Harness {
    pub fn has_caps(&self, required: &[String]) -> bool {
        required.iter().all(|c| self.caps.contains(c))
    }
}

/// A configured language that is not usable on this host, and why.
#[derive(Debug)]
pub struct Unavailable {
    pub name: String,
    pub reason: String,
}

pub struct ResolvedLanguages {
    pub ready: BTreeMap<String, Harness>,
    pub unavailable: Vec<Unavailable>,
}

pub fn resolve(languages: &BTreeMap<String, LanguageConfig>) -> ResolvedLanguages {
    let mut ready = BTreeMap::new();
    let mut unavailable = Vec::new();
    for (name, lang) in languages {
        let path = match config::expand_env(&lang.bin) {
            Ok(p) => PathBuf::from(p),
            Err(var) => {
                unavailable.push(Unavailable {
                    name: name.clone(),
                    reason: format!("environment variable ${{{var}}} unset"),
                });
                continue;
            }
        };
        if !path.is_file() {
            unavailable.push(Unavailable {
                name: name.clone(),
                reason: format!("binary not found: {}", path.display()),
            });
            continue;
        }
        let caps = probe_caps(&path);
        ready.insert(
            name.clone(),
            Harness {
                name: name.clone(),
                bin: path,
                modes: lang.modes.iter().copied().collect(),
                caps,
            },
        );
    }
    ResolvedLanguages { ready, unavailable }
}

/// Capabilities the harness reports via its `caps` verb (e.g. "notify async
/// secure secure:aes256gcm"). A harness that predates the verb exits non-zero
/// with no stdout, which correctly yields the empty set.
fn probe_caps(bin: &PathBuf) -> BTreeSet<String> {
    let child = Command::new(bin)
        .args(["caps", "_"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .stdin(Stdio::null())
        .spawn();
    let Ok(child) = child else {
        return BTreeSet::new();
    };
    match wait_with_timeout(child, Duration::from_secs(10)) {
        Ok(output) => String::from_utf8_lossy(&output.stdout)
            .split_whitespace()
            .map(str::to_string)
            .collect(),
        Err(_) => BTreeSet::new(),
    }
}

/// Caps a harness must report to participate in a mode. The async matrix would
/// hang (not fail) on a harness built without notify/async, hence the up-front
/// gate; same for secure without the crypto backend.
pub fn required_caps(mode: Mode, secure_algorithms: &[String], typed_codecs: &[String]) -> Vec<String> {
    match mode {
        Mode::Sync | Mode::Channel | Mode::Reap => Vec::new(),
        Mode::Primitives => vec!["prim".into()],
        Mode::Async => vec!["notify".into(), "async".into()],
        Mode::Typed => typed_codecs.iter().map(|c| format!("typed:{c}")).collect(),
        Mode::Secure => {
            let mut caps = vec!["secure".to_string()];
            caps.extend(secure_algorithms.iter().map(|a| format!("secure:{a}")));
            caps
        }
    }
}
