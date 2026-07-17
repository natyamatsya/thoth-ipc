// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Declarative matrix configuration. One config file serves every OS/CI job:
// binary paths reference environment variables (`bin = "${XLANG_CPP_BIN}"`),
// and a language whose variable is unset is simply not present on this host.

use std::collections::BTreeMap;
use std::fmt;

use serde::Deserialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Sync,
    Async,
    Channel,
    Reap,
    Secure,
    Primitives,
    Typed,
}

impl fmt::Display for Mode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            Mode::Sync => "sync",
            Mode::Async => "async",
            Mode::Channel => "channel",
            Mode::Reap => "reap",
            Mode::Secure => "secure",
            Mode::Primitives => "primitives",
            Mode::Typed => "typed",
        };
        f.write_str(s)
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileConfig {
    #[serde(default)]
    pub run: RunConfig,
    pub languages: BTreeMap<String, LanguageConfig>,
    #[serde(default)]
    pub scenarios: ScenariosConfig,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct RunConfig {
    /// Cases executed concurrently. Every case uses its own uniquely named
    /// channel, so parallel cases never share shm segments.
    pub jobs: usize,
    /// Re-run a failed case up to this many extra times ("flaky" if it then passes).
    pub retries: u32,
    /// Hard per-process deadline within a case.
    pub pair_timeout_secs: u64,
    /// Delay between starting the reader and the writer, giving the reader
    /// time to create the ring and register its receiver slot.
    pub reader_warmup_ms: u64,
    /// Known cross-language gaps: any case whose "scenario:id" contains one of
    /// these substrings runs as expected-fail (documented in every run, not
    /// fatal, and flagged when it unexpectedly passes).
    pub xfail: Vec<String>,
}

impl Default for RunConfig {
    fn default() -> Self {
        Self {
            jobs: 1,
            retries: 0,
            pair_timeout_secs: 30,
            reader_warmup_ms: 400,
            xfail: Vec::new(),
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LanguageConfig {
    /// Path to the harness binary; `${VAR}` is expanded from the environment.
    pub bin: String,
    /// Which scenarios this harness participates in.
    pub modes: Vec<Mode>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct ScenariosConfig {
    pub sync: PairScenarioConfig,
    #[serde(rename = "async")]
    pub async_: PairScenarioConfig,
    pub fanout: FanoutScenarioConfig,
    pub channel: ChannelScenarioConfig,
    pub reap: ReapScenarioConfig,
    pub secure: SecureScenarioConfig,
    pub primitives: PrimitivesScenarioConfig,
    pub typed: TypedScenarioConfig,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct TypedScenarioConfig {
    pub sizes: Vec<usize>,
    pub count: usize,
    /// Typed codecs to pair; each needs the `typed:<codec>` capability.
    pub codecs: Vec<String>,
}

impl Default for TypedScenarioConfig {
    fn default() -> Self {
        Self {
            sizes: vec![40, 200, 3000],
            count: 5,
            codecs: vec!["protobuf".into()],
        }
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct PrimitivesScenarioConfig {}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct FanoutScenarioConfig {
    pub sizes: Vec<usize>,
    pub count: usize,
}

impl Default for FanoutScenarioConfig {
    fn default() -> Self {
        Self {
            sizes: vec![65, 3000],
            count: 5,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct ChannelScenarioConfig {
    pub sizes: Vec<usize>,
    /// Messages per writer; the reader expects 2 x count.
    pub count: usize,
    /// Failures are expected and do not fail the run (flip once the ports
    /// implement the C++ multi-producer broadcast layout — see the matrix
    /// finding: C++ channel uses 96B slots + f_ct_ commit flags, the ports
    /// reuse the 88B route layout, and port senders draw msg ids from a
    /// process-local counter instead of the shared AC_CONN counter).
    pub xfail: bool,
}

impl Default for ChannelScenarioConfig {
    fn default() -> Self {
        Self {
            sizes: vec![40, 65, 3000],
            count: 10,
            xfail: true,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct PairScenarioConfig {
    pub sizes: Vec<usize>,
    pub count: usize,
}

impl Default for PairScenarioConfig {
    fn default() -> Self {
        // Sizes exercise the single-fragment (<=64B), multi-fragment and
        // chunk-storage wire paths; see tools/xlang_matrix.py history.
        Self {
            sizes: vec![40, 65, 200, 3000],
            count: 5,
        }
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct ReapScenarioConfig {}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct SecureScenarioConfig {
    pub sizes: Vec<usize>,
    pub count: usize,
    /// AEAD algorithms to pair; each needs the `secure:<alg>` capability.
    pub algorithms: Vec<String>,
    /// Payload size for the wrong-key fail-closed cases.
    pub badkey_size: usize,
}

impl Default for SecureScenarioConfig {
    fn default() -> Self {
        Self {
            sizes: vec![40, 200, 3000],
            count: 5,
            algorithms: vec!["aes256gcm".into(), "chacha20poly1305".into()],
            badkey_size: 200,
        }
    }
}

/// Expand `${VAR}` references. Returns Err(var_name) on the first unset variable.
pub fn expand_env(input: &str) -> Result<String, String> {
    let mut out = String::with_capacity(input.len());
    let mut rest = input;
    while let Some(start) = rest.find("${") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        let Some(end) = after.find('}') else {
            out.push_str(&rest[start..]);
            return Ok(out);
        };
        let var = &after[..end];
        match std::env::var(var) {
            Ok(v) if !v.is_empty() => out.push_str(&v),
            _ => return Err(var.to_string()),
        }
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

pub fn load(path: &std::path::Path) -> Result<FileConfig, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("cannot read config {}: {e}", path.display()))?;
    toml::from_str(&text).map_err(|e| format!("bad config {}: {e}", path.display()))
}
