//! Adaptive prewarmer core. One independent deadline per (domain, qtype).
//! It never stores answers and never queries an upstream: it only (1) reads TTL
//! truth from the OxiDNS cache API and (2) fires a DNS query at OxiDNS's own
//! listener so the native lazy cache refreshes.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::api::EntrySource;
use crate::dns::Prober;
use crate::model::*;

pub fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as i64
}

/// RFC3339 UTC timestamp (e.g. 2026-11-21T08:12:33Z) from epoch millis.
/// JS `new Date(iso)` parses this form directly.
pub fn rfc3339(ms: i64) -> String {
    if ms <= 0 {
        return "-".into();
    }
    let secs = ms / 1000;
    let days = secs.div_euclid(86400);
    let sod = secs.rem_euclid(86400);
    let (y, mo, d) = civil_from_days(days);
    let hh = sod / 3600;
    let mm = (sod % 3600) / 60;
    let ss = sod % 60;
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, mo, d, hh, mm, ss)
}

/// Howard Hinnant's civil_from_days algorithm.
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;                       // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0,399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0,365]
    let mp = (5 * doy + 2) / 153;                     // [0,11]
    let d = doy - (153 * mp + 2) / 5 + 1;             // [1,31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 };    // [1,12]
    (if m <= 2 { y + 1 } else { y }, m, d)
}

// Deterministic PRNG (xorshift64) for jitter, seeded once from time. No rand crate.
struct Rng(u64);
impl Rng {
    fn new() -> Rng {
        Rng(now_ms() as u64 ^ 0x9E3779B97F4A7C15)
    }
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
    fn below(&mut self, n: i64) -> i64 {
        if n <= 0 { return 0; }
        (self.next() % n as u64) as i64
    }
}

struct ProbeResult {
    key: Key,
    old_remain: i64,
    new_remain: i64,
    new_ttl: i64,
    had_entry: bool,
    now_entry: bool,
    err: Option<String>,
    finished_ms: i64,
}

pub struct Scheduler {
    cfg: Config,
    src: Arc<dyn EntrySource>,
    prober: Arc<dyn Prober>,
    watched: Vec<Key>,
    tasks: HashMap<Key, TaskState>,
    stats: Stats,
    started_ms: i64,
    results_tx: Sender<ProbeResult>,
    results_rx: Receiver<ProbeResult>,
    stop: Arc<AtomicBool>,
    rng: Rng,
    snapshot: Option<Arc<Mutex<Option<Status>>>>,
}

pub type Snapshot = Arc<Mutex<Option<Status>>>;

impl Scheduler {
    pub fn new(cfg: Config, src: Arc<dyn EntrySource>, prober: Arc<dyn Prober>, watched: Vec<Key>) -> Scheduler {
        let (tx, rx) = channel();
        Scheduler {
            cfg, src, prober, watched,
            tasks: HashMap::new(),
            stats: Stats::default(),
            started_ms: now_ms(),
            results_tx: tx,
            results_rx: rx,
            stop: Arc::new(AtomicBool::new(false)),
            rng: Rng::new(),
            snapshot: None,
        }
    }

    pub fn stop_flag(&self) -> Arc<AtomicBool> {
        self.stop.clone()
    }

    /// Attach a shared status snapshot that `run()` refreshes each cycle.
    pub fn set_snapshot(&mut self, s: Snapshot) {
        self.snapshot = Some(s);
    }

    /// TTL lead policy: short TTL -> fixed minimum lead; otherwise expire at
    /// the observed remaining TTL plus grace (land inside stale), plus jitter.
    fn lead_for(&mut self, ttl: i64, remaining: i64) -> (i64, &'static str) {
        let grace = self.cfg.grace_sec;
        let jitter = self.rng.below(self.cfg.jitter_sec + 1);
        let base = remaining.max(0);
        if ttl > 0 && ttl < self.cfg.min_ttl_sec {
            let mut fixed = self.cfg.min_interval_sec;
            if fixed < grace + 1 {
                fixed = grace + 1;
            }
            (fixed, "short-ttl-fixed")
        } else {
            (base + grace + jitter, "adaptive")
        }
    }

    pub fn run(&mut self, log: &dyn Fn(&str)) {
        let tick = if self.cfg.tick_sec > 0 { self.cfg.tick_sec } else { 1 };
        self.reconcile(log);
        while !self.stop.load(Ordering::Relaxed) {
            // Drain all pending results first (non-blocking).
            while let Ok(r) = self.results_rx.try_recv() {
                self.apply_result(r, log);
            }
            self.publish();
            thread::sleep(Duration::from_secs(tick as u64));
            if self.stop.load(Ordering::Relaxed) { break; }
            self.reconcile(log);
            self.dispatch(log);
            while let Ok(r) = self.results_rx.try_recv() {
                self.apply_result(r, log);
            }
            self.publish();
        }
    }

    /// Publish a status snapshot for the writer thread (no-op if unattached).
    fn publish(&self) {
        if let Some(h) = &self.snapshot {
            if let Ok(mut guard) = h.lock() {
                *guard = Some(self.status());
            }
        }
    }

    fn find_entry<'a>(&self, list: &'a [CacheEntry], key: &Key) -> Option<&'a CacheEntry> {
        list.iter().find(|e| {
            e.normalized_domain() == key.domain && normalize_qtype(&e.record_type) == key.qtype
        })
    }

    fn reconcile(&mut self, log: &dyn Fn(&str)) {
        let mut desired: HashMap<Key, bool> = HashMap::new();
        for k in &self.watched {
            desired.insert(k.clone(), true);
        }

        let mut observed: HashMap<Key, CacheEntry> = HashMap::new();
        if self.cfg.mode == "all" {
            match self.src.entries("", 5000) {
                Ok(list) => {
                    for e in &list {
                        let k = Key::new(&e.normalized_domain(), &normalize_qtype(&e.record_type));
                        if k.domain.is_empty() || !e.has_usable_answer() { continue; }
                        observed.insert(k.clone(), e.clone());
                        desired.insert(k, false);
                    }
                }
                Err(e) => log(&format!("reconcile: entries(all) failed: {}", e)),
            }
        } else {
            for k in &self.watched {
                match self.src.entries(&k.domain, 50) {
                    Ok(list) => {
                        if let Some(e) = self.find_entry(&list, k) {
                            if e.has_usable_answer() {
                                observed.insert(k.clone(), e.clone());
                            }
                        }
                    }
                    Err(e) => log(&format!("reconcile: entries({}) failed: {}", k.domain, e)),
                }
            }
        }

        let now = now_ms();
        let watched_set: HashMap<Key, bool> = self.watched.iter().map(|k| (k.clone(), true)).collect();

        let keys: Vec<Key> = desired.keys().cloned().collect();
        for k in keys {
            let watch = *watched_set.get(&k).unwrap_or(&false);

            // Ensure the task exists first (separate borrow), then read the
            // small set of values we need to decide the new deadline.
            self.tasks.entry(k.clone()).or_insert_with(|| TaskState::new(k.clone(), now));
            let (last_remaining, inflight, deadline_ms) = {
                let t = self.tasks.get(&k).unwrap();
                (t.last_remaining, t.inflight, t.deadline_ms)
            };

            // Compute lead (advances RNG) before borrowing the task mutably.
            let mut new_deadline: Option<i64> = None;
            let mut changed = false;
            let mut short_ttl = false;
            let (rem, ttl) = match observed.get(&k) {
                None => {
                    if deadline_ms == 0 { new_deadline = Some(now); }
                    (-1i64, 0i64) // sentinel: no observed entry
                }
                Some(e) => {
                    let rem = e.remaining_ttl.max(0);
                    let ttl = e.ttl;
                    if rem > last_remaining + 2 && last_remaining > 0 && !inflight {
                        let (lead, _) = self.lead_for(ttl, rem);
                        new_deadline = Some(now + lead * 1000);
                        changed = true;
                    }
                    if deadline_ms == 0 && new_deadline.is_none() {
                        let (lead, kind) = self.lead_for(ttl, rem);
                        new_deadline = Some(now + lead * 1000);
                        if kind == "short-ttl-fixed" { short_ttl = true; }
                    }
                    (rem, ttl)
                }
            };

            // Now the single mutable write-back.
            {
                let t = self.tasks.get_mut(&k).unwrap();
                t.in_watch_list = watch;
                if rem < 0 {
                    t.last_result = "seed".into();
                    if let Some(d) = new_deadline { t.deadline_ms = d; }
                    continue;
                }
                if let Some(d) = new_deadline { t.deadline_ms = d; }
                if changed {
                    t.backoff = 0;
                    t.last_result = "ttl-changed".into();
                }
                if short_ttl {
                    t.last_result = "short-ttl-fixed".into();
                    self.stats.skipped_short += 1;
                }
                t.last_ttl = ttl;
                t.last_remaining = rem;
                t.updated_ms = now;
            }
        }

        // Remove tasks no longer desired (only relevant in "all" mode).
        let gone: Vec<Key> = self.tasks.iter()
            .filter(|(k, t)| !desired.contains_key(*k) && !t.inflight)
            .map(|(k, _)| k.clone()).collect();
        for k in gone {
            self.tasks.remove(&k);
        }
    }

    fn dispatch(&mut self, log: &dyn Fn(&str)) {
        let now = now_ms();
        let min_interval_ms = self.cfg.min_interval_sec * 1000;
        let mut due: Vec<TaskState> = Vec::new();
        for t in self.tasks.values_mut() {
            if t.inflight || t.deadline_ms == 0 || now < t.deadline_ms {
                continue;
            }
            if t.last_probe_ms != 0 && now - t.last_probe_ms < min_interval_ms {
                t.deadline_ms = t.last_probe_ms + min_interval_ms;
                continue;
            }
            t.inflight = true;
            t.last_probe_ms = now;
            due.push(t.clone());
        }

        for t in due {
            let src = self.src.clone();
            let prober = self.prober.clone();
            let tx = self.results_tx.clone();
            let cfg = self.cfg.clone();
            thread::spawn(move || {
                let r = probe_task(&t, &cfg, src.as_ref(), prober.as_ref());
                let _ = tx.send(r);
            });
        }
        let _ = log; // reserved
    }

    fn backoff_delay(&self, n: i64) -> i64 {
        let n = if n <= 0 { 1 } else { n };
        let max = self.cfg.retry_max_sec;
        let mut d = self.cfg.retry_base_sec;
        for _ in 1..n {
            d *= 2;
            if d >= max { return max; }
        }
        d.min(max)
    }

    fn apply_result(&mut self, r: ProbeResult, log: &dyn Fn(&str)) {
        let now = r.finished_ms;
        let key = r.key.clone();

        // Compute every self-dependent value BEFORE taking the mutable task
        // borrow (lead_for advances the RNG; backoff_delay reads config).
        let err = r.err.clone();
        let is_seed = err.is_none() && !r.had_entry && r.now_entry;
        let is_refresh = err.is_none() && r.now_entry && r.new_remain > r.old_remain + 2;
        let seed_lead = if is_seed { self.lead_for(r.new_ttl, r.new_remain).0 } else { 0 };
        let refresh_lead = if is_refresh { self.lead_for(r.new_ttl, r.new_remain).0 } else { 0 };

        let cur_backoff = match self.tasks.get(&key) {
            Some(t) => t.backoff,
            None => return,
        };
        let next_backoff = cur_backoff + 1;
        let retry_delay = self.backoff_delay(next_backoff);

        // Now take one mutable borrow and write everything back.
        let t = self.tasks.get_mut(&key).unwrap();
        t.inflight = false;
        self.stats.probes += 1;

        if let Some(err) = err {
            self.stats.refresh_failed += 1;
            t.last_result = "failed".into();
            t.last_error = err.clone();
            t.backoff = next_backoff;
            t.deadline_ms = now + retry_delay * 1000;
            log(&format!("probe {}: trigger error: {} -> retry in {}s", key.text(), err, retry_delay));
            return;
        }

        if is_seed {
            self.stats.seeds += 1;
            t.last_result = "seeded".into();
            t.last_error.clear();
            t.backoff = 0;
            t.deadline_ms = now + seed_lead * 1000;
            log(&format!("seed {}: cached ttl={} remaining={} -> next in {}s",
                key.text(), r.new_ttl, r.new_remain, seed_lead));
            return;
        }

        if is_refresh {
            self.stats.refresh_ok += 1;
            t.last_result = "refresh-ok".into();
            t.last_error.clear();
            t.backoff = 0;
            t.deadline_ms = now + refresh_lead * 1000;
            t.last_ttl = r.new_ttl;
            t.last_remaining = r.new_remain;
            log(&format!("refresh {}: ttl={} remaining {}->{} -> next in {}s",
                key.text(), r.new_ttl, r.old_remain, r.new_remain, refresh_lead));
            return;
        }

        // No jump inside the wait window: keep the OLD cache (OxiDNS still
        // serves it stale) and retry with backoff.
        self.stats.refresh_failed += 1;
        t.last_result = "refresh-failed".into();
        t.last_error = "remaining_ttl did not recover".into();
        t.backoff = next_backoff;
        t.deadline_ms = now + retry_delay * 1000;
        log(&format!("refresh {}: no ttl recovery (remain {}->{}) -> retry in {}s",
            key.text(), r.old_remain, r.new_remain, retry_delay));
    }

    pub fn status(&self) -> Status {
        let mut tasks: Vec<TaskView> = self.tasks.values().map(|t| TaskView {
            domain: t.key.domain.clone(),
            qtype: t.key.qtype.clone(),
            ttl: t.last_ttl,
            remaining_ttl: t.last_remaining,
            next_probe: rfc3339(t.deadline_ms),
            source: if t.in_watch_list { "watch-list".into() } else { "auto-discovered".into() },
            last_result: t.last_result.clone(),
            last_error: t.last_error.clone(),
            backoff: t.backoff,
        }).collect();
        tasks.sort_by(|a, b| a.domain.cmp(&b.domain).then(a.qtype.cmp(&b.qtype)));
        Status {
            enabled: true,
            mode: self.cfg.mode.clone(),
            api_base: self.cfg.api_base.clone(),
            dns_target: self.cfg.dns_target.clone(),
            started_at: rfc3339(self.started_ms),
            updated_at: rfc3339(now_ms()),
            tasks,
            stats: self.stats.clone(),
        }
    }
}

fn probe_task(t: &TaskState, cfg: &Config, src: &dyn EntrySource, prober: &dyn Prober) -> ProbeResult {
    let mut old_remain = t.last_remaining;
    let had_entry = old_remain > 0 || t.last_ttl > 0;

    let mut now_entry = false;
    if let Ok(list) = src.entries(&t.key.domain, 50) {
        if let Some(e) = find_in(&list, &t.key) {
            now_entry = true;
            old_remain = e.remaining_ttl;
        }
    }
    // hadEntry is determined from the state we started with, before our probe.
    let had_entry = had_entry || now_entry;

    if let Err(e) = prober.probe(&cfg.dns_target, &t.key.domain, &t.key.qtype) {
        return ProbeResult {
            key: t.key.clone(), old_remain, new_remain: 0, new_ttl: 0,
            had_entry, now_entry: false, err: Some(e), finished_ms: now_ms(),
        };
    }

    if cfg.refresh_delay_ms > 0 {
        thread::sleep(Duration::from_millis(cfg.refresh_delay_ms as u64));
    }

    let mut new_remain = 0;
    let mut new_ttl = 0;
    let mut now_entry_after = false;
    if let Ok(list) = src.entries(&t.key.domain, 50) {
        if let Some(e) = find_in(&list, &t.key) {
            now_entry_after = true;
            new_remain = e.remaining_ttl;
            new_ttl = e.ttl;
        }
    }
    ProbeResult {
        key: t.key.clone(), old_remain, new_remain, new_ttl,
        had_entry, now_entry: now_entry_after, err: None, finished_ms: now_ms(),
    }
}

fn find_in<'a>(list: &'a [CacheEntry], key: &Key) -> Option<&'a CacheEntry> {
    list.iter().find(|e| {
        e.normalized_domain() == key.domain && normalize_qtype(&e.record_type) == key.qtype
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_dates() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(rfc3339(0), "-");
        assert_eq!(rfc3339(1000), "1970-01-01T00:00:01Z");
        assert_eq!(rfc3339(1763712000000), "2025-11-21T08:00:00Z");
    }

    #[test]
    fn backoff_doubling_and_cap() {
        let cfg = Config { retry_base_sec: 15, retry_max_sec: 300, ..Config::default() };
        let s = Scheduler::new(cfg, Arc::new(FakeSrc), Arc::new(FakeProber), vec![]);
        assert_eq!(s.backoff_delay(1), 15);
        assert_eq!(s.backoff_delay(2), 30);
        assert_eq!(s.backoff_delay(3), 60);
        assert_eq!(s.backoff_delay(10), 300);
    }

    struct FakeSrc;
    impl EntrySource for FakeSrc {
        fn entries(&self, _q: &str, _l: i64) -> Result<Vec<CacheEntry>, String> { Ok(vec![]) }
    }
    struct FakeProber;
    impl Prober for FakeProber {
        fn probe(&self, _t: &str, _d: &str, _q: &str) -> Result<(), String> { Ok(()) }
    }
}
