// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception OR MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya and thoth-ipc contributors
//
// Case planning: expand scenarios into concrete writer x reader cases. Each
// case gets a channel name unique to this run, so cases are independent and
// safe to execute in parallel.

use std::collections::BTreeMap;
use std::path::PathBuf;

use crate::config::{FileConfig, Mode};
use crate::harness::{Harness, required_caps};

#[derive(Debug, Clone)]
pub struct Endpoint {
    pub lang: String,
    pub bin: PathBuf,
}

impl From<&Harness> for Endpoint {
    fn from(h: &Harness) -> Self {
        Self {
            lang: h.name.clone(),
            bin: h.bin.clone(),
        }
    }
}

/// One process of a case: a harness binary plus its full argument vector.
#[derive(Debug, Clone)]
pub struct Proc {
    pub endpoint: Endpoint,
    pub args: Vec<String>,
}

impl Proc {
    fn new(h: &Harness, args: Vec<String>) -> Self {
        Self {
            endpoint: Endpoint::from(h),
            args,
        }
    }
}

/// A probe process run after the holder is READY; its trimmed stdout must
/// equal `expect`.
#[derive(Debug, Clone)]
pub struct Probe {
    pub proc: Proc,
    pub expect: String,
}

#[derive(Debug, Clone)]
pub enum CaseKind {
    /// Readers start first; after the warmup delay all writers start. Every
    /// process must exit 0. Covers 1:1 pairs, 1:N fanout and N:1 multi-writer.
    Group {
        readers: Vec<Proc>,
        writers: Vec<Proc>,
    },
    /// A holder acquires a shared resource (receiver slot, mutex, ...) and
    /// prints READY; optionally it is SIGKILLed; then each probe runs in order
    /// and its stdout is checked; finally an optional reader/writer group must
    /// round-trip on the same (uncleared) channel. Covers reaping, dead-holder
    /// recovery and traffic-after-reap.
    HoldProbe {
        holder: Proc,
        kill_holder: bool,
        probes: Vec<Probe>,
        then_group: Option<(Vec<Proc>, Vec<Proc>)>,
    },
}

#[derive(Debug, Clone, Default)]
pub struct Case {
    pub scenario: String,
    pub id: String,
    pub channel: String,
    pub kind: CaseKind,
    /// Failure is expected (known library gap); does not fail the run, and a
    /// pass is flagged so the expectation gets flipped when the gap closes.
    pub xfail: bool,
}

impl Default for CaseKind {
    fn default() -> Self {
        CaseKind::Group {
            readers: Vec::new(),
            writers: Vec::new(),
        }
    }
}

/// A language excluded from a scenario at planning time, and why.
#[derive(Debug)]
pub struct PlanNote {
    pub scenario: String,
    pub lang: String,
    pub reason: String,
}

pub struct Plan {
    pub cases: Vec<Case>,
    pub notes: Vec<PlanNote>,
}

pub const SCENARIOS: &[&str] = &[
    "sync",
    "async",
    "fanout",
    "channel",
    "reap",
    "primitives",
    "typed",
    "secure",
    "secure-badkey",
    "secure-negative",
];

struct Namer {
    pid: u32,
    seq: usize,
}

impl Namer {
    fn next(&mut self, tag: &str) -> String {
        self.seq += 1;
        format!("x{}_{}_{}", tag, self.pid, self.seq)
    }
}

fn rw_args(verb: &str, channel: &str, count: usize, size: usize, extra: &[&str]) -> Vec<String> {
    let mut args = vec![
        verb.to_string(),
        channel.to_string(),
        count.to_string(),
        size.to_string(),
    ];
    args.extend(extra.iter().map(|e| e.to_string()));
    args
}

pub fn plan(cfg: &FileConfig, ready: &BTreeMap<String, Harness>, filter: &[String]) -> Plan {
    let mut cases = Vec::new();
    let mut notes = Vec::new();
    let mut namer = Namer {
        pid: std::process::id(),
        seq: 0,
    };

    let enabled = |name: &str| filter.is_empty() || filter.iter().any(|f| f == name);

    // Languages participating in `mode`, split into capable / lacking caps.
    let participants = |scenario: &str, mode: Mode, notes: &mut Vec<PlanNote>| -> Vec<&Harness> {
        let need = required_caps(
            mode,
            &cfg.scenarios.secure.algorithms,
            &cfg.scenarios.typed.codecs,
        );
        let mut langs = Vec::new();
        for h in ready.values() {
            if !h.modes.contains(&mode) {
                continue;
            }
            if h.has_caps(&need) {
                langs.push(h);
            } else {
                let missing: Vec<_> = need
                    .iter()
                    .filter(|c| !h.caps.contains(*c))
                    .cloned()
                    .collect();
                notes.push(PlanNote {
                    scenario: scenario.to_string(),
                    lang: h.name.clone(),
                    reason: format!("missing caps [{}]", missing.join(", ")),
                });
            }
        }
        langs
    };

    if enabled("sync") {
        let langs = participants("sync", Mode::Sync, &mut notes);
        let sc = &cfg.scenarios.sync;
        for w in &langs {
            for r in &langs {
                for &size in &sc.sizes {
                    let channel = namer.next("s");
                    cases.push(Case {
                        scenario: "sync".into(),
                        id: format!("{} -> {} {}B", w.name, r.name, size),
                        kind: CaseKind::Group {
                            readers: vec![Proc::new(r, rw_args("read", &channel, sc.count, size, &[]))],
                            writers: vec![Proc::new(w, rw_args("write", &channel, sc.count, size, &[]))],
                        },
                        channel,
                        xfail: false,
                    });
                }
            }
        }
    }

    if enabled("async") {
        let langs = participants("async", Mode::Async, &mut notes);
        let sc = &cfg.scenarios.async_;
        for w in &langs {
            for r in &langs {
                for &size in &sc.sizes {
                    let channel = namer.next("a");
                    cases.push(Case {
                        scenario: "async".into(),
                        id: format!("{} -> {} {}B", w.name, r.name, size),
                        kind: CaseKind::Group {
                            readers: vec![Proc::new(r, rw_args("aread", &channel, sc.count, size, &[]))],
                            writers: vec![Proc::new(w, rw_args("write", &channel, sc.count, size, &[]))],
                        },
                        channel,
                        xfail: false,
                    });
                }
            }
        }
    }

    // Broadcast fan-out: one writer, every participating language reading the
    // same channel concurrently — each receiver must get every message
    // (exercises the rc_ read-counter bitmask with N > 1 cross-language).
    if enabled("fanout") {
        let langs = participants("fanout", Mode::Sync, &mut notes);
        let sc = &cfg.scenarios.fanout;
        if langs.len() >= 2 {
            for w in &langs {
                for &size in &sc.sizes {
                    let channel = namer.next("f");
                    let readers: Vec<Proc> = langs
                        .iter()
                        .map(|r| Proc::new(r, rw_args("read", &channel, sc.count, size, &[])))
                        .collect();
                    let minrecv = readers.len().to_string();
                    let reader_names: Vec<&str> =
                        langs.iter().map(|r| r.name.as_str()).collect();
                    cases.push(Case {
                        scenario: "fanout".into(),
                        id: format!("{} -> [{}] {}B", w.name, reader_names.join("+"), size),
                        kind: CaseKind::Group {
                            readers,
                            writers: vec![Proc::new(
                                w,
                                rw_args("write", &channel, sc.count, size, &[&minrecv]),
                            )],
                        },
                        channel,
                        xfail: false,
                    });
                }
            }
        }
    }

    // Multi-writer ipc::channel: two concurrent senders of DIFFERENT languages
    // into one reader (multi-producer claim/CAS + cc_id self-filtering; the
    // reader expects 2 x count messages).
    if enabled("channel") {
        let langs = participants("channel", Mode::Channel, &mut notes);
        let sc = &cfg.scenarios.channel;
        for (i, w1) in langs.iter().enumerate() {
            for w2 in langs.iter().skip(i + 1) {
                for r in &langs {
                    for &size in &sc.sizes {
                        let channel = namer.next("c");
                        cases.push(Case {
                            scenario: "channel".into(),
                            id: format!("{}+{} -> {} {}B", w1.name, w2.name, r.name, size),
                            kind: CaseKind::Group {
                                readers: vec![Proc::new(
                                    r,
                                    rw_args("cread", &channel, 2 * sc.count, size, &[]),
                                )],
                                writers: vec![
                                    Proc::new(w1, rw_args("cwrite", &channel, sc.count, size, &[])),
                                    Proc::new(w2, rw_args("cwrite", &channel, sc.count, size, &[])),
                                ],
                            },
                            channel,
                            xfail: sc.xfail,
                        });
                    }
                }
            }
        }
    }

    if enabled("reap") {
        let langs = participants("reap", Mode::Reap, &mut notes);
        for h in &langs {
            for r in &langs {
                // dead: the holder is SIGKILLed; a connecting receiver must
                // reclaim its slot (count 1). live: it must NOT be reaped
                // (count 2, proving the start token matches cross-language).
                for dead in [true, false] {
                    let kind = if dead { "dead" } else { "live" };
                    let ch = namer.next("r");
                    cases.push(Case {
                        scenario: "reap".into(),
                        id: format!("{} hold -> {} reap {}", h.name, r.name, kind),
                        kind: CaseKind::HoldProbe {
                            holder: Proc::new(h, vec!["hold".into(), ch.clone(), "20".into()]),
                            kill_holder: dead,
                            probes: vec![Probe {
                                proc: Proc::new(r, vec!["count".into(), ch.clone()]),
                                expect: (if dead { "1" } else { "2" }).into(),
                            }],
                            then_group: None,
                        },
                        channel: ch,
                        xfail: false,
                    });
                }
                // A SENDER must observe the dead slot without reaping or
                // claiming it (probe), and only a receiver connect reaps.
                let ch = namer.next("r");
                cases.push(Case {
                    scenario: "reap".into(),
                    id: format!("{} hold -> {} probe-noreap dead", h.name, r.name),
                    kind: CaseKind::HoldProbe {
                        holder: Proc::new(h, vec!["hold".into(), ch.clone(), "20".into()]),
                        kill_holder: true,
                        probes: vec![
                            Probe {
                                proc: Proc::new(r, vec!["probe".into(), ch.clone()]),
                                expect: "1".into(),
                            },
                            Probe {
                                proc: Proc::new(r, vec!["count".into(), ch.clone()]),
                                expect: "1".into(),
                            },
                        ],
                        then_group: None,
                    },
                    channel: ch,
                    xfail: false,
                });
                // After a holder dies, a normal round-trip on the SAME channel
                // must still work: the phantom slot may not stall the ring.
                let ch = namer.next("r");
                cases.push(Case {
                    scenario: "reap".into(),
                    id: format!("{} hold dead -> {} <-> {} traffic", h.name, h.name, r.name),
                    kind: CaseKind::HoldProbe {
                        holder: Proc::new(h, vec!["hold".into(), ch.clone(), "20".into()]),
                        kill_holder: true,
                        probes: Vec::new(),
                        then_group: Some((
                            vec![Proc::new(r, rw_args("read", &ch, 5, 200, &[]))],
                            vec![Proc::new(h, rw_args("write", &ch, 5, 200, &[]))],
                        )),
                    },
                    channel: ch,
                    xfail: false,
                });
            }
        }
    }

    // Cross-language sync primitives: mutex contention + robust dead-holder
    // recovery, semaphore count exactness, condition wakeup.
    if enabled("primitives") {
        let langs = participants("primitives", Mode::Primitives, &mut notes);
        for a in &langs {
            for b in &langs {
                let ch = namer.next("p");
                cases.push(Case {
                    scenario: "primitives".into(),
                    id: format!("{} holds mutex -> {} try busy", a.name, b.name),
                    kind: CaseKind::HoldProbe {
                        holder: Proc::new(a, vec!["mhold".into(), ch.clone(), "20".into()]),
                        kill_holder: false,
                        probes: vec![Probe {
                            proc: Proc::new(b, vec!["mtry".into(), ch.clone()]),
                            expect: "busy".into(),
                        }],
                        then_group: None,
                    },
                    channel: ch,
                    xfail: false,
                });
                // The holder dies while holding: the peer's timed lock must
                // recover via dead-holder detection (robust mutex parity).
                let ch = namer.next("p");
                cases.push(Case {
                    scenario: "primitives".into(),
                    id: format!("{} killed holding mutex -> {} lock recovers", a.name, b.name),
                    kind: CaseKind::HoldProbe {
                        holder: Proc::new(a, vec!["mhold".into(), ch.clone(), "20".into()]),
                        kill_holder: true,
                        probes: vec![Probe {
                            proc: Proc::new(b, vec!["mlock".into(), ch.clone(), "5000".into()]),
                            expect: "acquired".into(),
                        }],
                        then_group: None,
                    },
                    channel: ch,
                    xfail: false,
                });
                // Semaphore: exactly 3 posts arrive, no surplus token remains.
                let ch = namer.next("p");
                cases.push(Case {
                    scenario: "primitives".into(),
                    id: format!("{} posts 3 -> {} sem waits 3", a.name, b.name),
                    kind: CaseKind::Group {
                        readers: vec![Proc::new(
                            b,
                            vec!["swait".into(), ch.clone(), "3".into(), "8000".into()],
                        )],
                        writers: vec![Proc::new(a, vec!["spost".into(), ch.clone(), "3".into()])],
                    },
                    channel: ch,
                    xfail: false,
                });
                // Condition: a broadcast in one language wakes a waiter in another.
                let ch = namer.next("p");
                cases.push(Case {
                    scenario: "primitives".into(),
                    id: format!("{} broadcasts -> {} cond wakes", a.name, b.name),
                    kind: CaseKind::Group {
                        readers: vec![Proc::new(
                            b,
                            vec!["cvwait".into(), ch.clone(), "8000".into()],
                        )],
                        writers: vec![Proc::new(a, vec!["cvnotify".into(), ch.clone()])],
                    },
                    channel: ch,
                    xfail: false,
                });
            }
        }
    }

    if enabled("secure") || enabled("secure-badkey") {
        let langs = participants("secure", Mode::Secure, &mut notes);
        let sc = &cfg.scenarios.secure;
        for alg in &sc.algorithms {
            for w in &langs {
                for r in &langs {
                    if enabled("secure") {
                        for &size in &sc.sizes {
                            let channel = namer.next("e");
                            cases.push(Case {
                                scenario: "secure".into(),
                                id: format!("{} -> {} {}B {alg}", w.name, r.name, size),
                                kind: CaseKind::Group {
                                    readers: vec![Proc::new(
                                        r,
                                        rw_args("sread", &channel, sc.count, size, &[alg]),
                                    )],
                                    writers: vec![Proc::new(
                                        w,
                                        rw_args("swrite", &channel, sc.count, size, &[alg]),
                                    )],
                                },
                                channel,
                                xfail: false,
                            });
                        }
                    }
                    // A reader keyed differently must reject every message
                    // (fail-closed), whoever sealed them.
                    if enabled("secure-badkey") {
                        let channel = namer.next("b");
                        cases.push(Case {
                            scenario: "secure-badkey".into(),
                            id: format!("{} -> {} {}B {alg}", w.name, r.name, sc.badkey_size),
                            kind: CaseKind::Group {
                                readers: vec![Proc::new(
                                    r,
                                    rw_args("sread-badkey", &channel, sc.count, sc.badkey_size, &[alg]),
                                )],
                                writers: vec![Proc::new(
                                    w,
                                    rw_args("swrite", &channel, sc.count, sc.badkey_size, &[alg]),
                                )],
                            },
                            channel,
                            xfail: false,
                        });
                    }
                }
            }
        }
    }

    // Typed protocol layer: the codec-wrapped route (twrite/tread) with
    // field-level verification, per configured codec.
    if enabled("typed") {
        let langs = participants("typed", Mode::Typed, &mut notes);
        let sc = &cfg.scenarios.typed;
        for codec in &sc.codecs {
            for w in &langs {
                for r in &langs {
                    for &size in &sc.sizes {
                        let channel = namer.next("t");
                        cases.push(Case {
                            scenario: "typed".into(),
                            id: format!("{} -> {} {}B {codec}", w.name, r.name, size),
                            kind: CaseKind::Group {
                                readers: vec![Proc::new(
                                    r,
                                    rw_args("tread", &channel, sc.count, size, &[codec]),
                                )],
                                writers: vec![Proc::new(
                                    w,
                                    rw_args("twrite", &channel, sc.count, size, &[codec]),
                                )],
                            },
                            channel,
                            xfail: false,
                        });
                    }
                }
            }
        }
    }

    // Secure fail-closed negatives beyond wrong key material: a tampered tag
    // and a wrong key id must be rejected by a correctly keyed reader, and an
    // envelope sealed under one algorithm must be rejected by a reader keyed
    // for another.
    if enabled("secure-negative") {
        let langs = participants("secure-negative", Mode::Secure, &mut notes);
        let sc = &cfg.scenarios.secure;
        let (count, size) = (sc.count, sc.badkey_size);
        let mut push_neg = |label: String,
                            w: &Harness,
                            r: &Harness,
                            write_args: Vec<String>,
                            read_args: Vec<String>,
                            channel: String| {
            cases.push(Case {
                scenario: "secure-negative".into(),
                id: label,
                kind: CaseKind::Group {
                    readers: vec![Proc::new(r, read_args)],
                    writers: vec![Proc::new(w, write_args)],
                },
                channel,
                xfail: false,
            });
        };
        for (ai, alg) in sc.algorithms.iter().enumerate() {
            for w in &langs {
                for r in &langs {
                    let ch = namer.next("n");
                    push_neg(
                        format!("{} -> {} tamper {alg}", w.name, r.name),
                        w,
                        r,
                        rw_args("swrite-tamper", &ch, count, size, &[alg]),
                        rw_args("sread-reject", &ch, count, size, &[alg]),
                        ch,
                    );
                    let ch = namer.next("n");
                    push_neg(
                        format!("{} -> {} keyid {alg}", w.name, r.name),
                        w,
                        r,
                        rw_args("swrite", &ch, count, size, &[alg]),
                        rw_args("sread-badkeyid", &ch, count, size, &[alg]),
                        ch,
                    );
                    if sc.algorithms.len() >= 2 {
                        let other = &sc.algorithms[(ai + 1) % sc.algorithms.len()];
                        let ch = namer.next("n");
                        push_neg(
                            format!("{} -> {} algmix {alg}->{other}", w.name, r.name),
                            w,
                            r,
                            rw_args("swrite", &ch, count, size, &[alg]),
                            rw_args("sread-reject", &ch, count, size, &[other]),
                            ch,
                        );
                    }
                }
            }
        }
    }

    // Apply the config's known-gap list: matching cases become expected-fail.
    for case in &mut cases {
        if case.xfail {
            continue;
        }
        let key = format!("{}:{}", case.scenario, case.id);
        if cfg.run.xfail.iter().any(|e| key.contains(e.as_str())) {
            case.xfail = true;
        }
    }

    Plan { cases, notes }
}
