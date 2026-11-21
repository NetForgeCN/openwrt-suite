//! Data model mirroring the Go implementation one-for-one.

use crate::json::{self, Json};

/// All runtime knobs. The OpenWrt init script passes every value as a flag, so
/// this binary reads no libuci and no config.yaml of its own.
#[derive(Clone, Debug)]
pub struct Config {
    pub api_base: String,
    pub api_user: String,
    pub api_pass: String,
    pub cache_tag: String,
    pub dns_target: String,
    pub watch_list: String,
    pub mode: String,          // "list" or "all"
    pub tick_sec: i64,
    pub grace_sec: i64,
    pub refresh_delay_ms: i64,
    pub min_ttl_sec: i64,
    pub min_interval_sec: i64,
    pub max_interval_sec: i64,
    pub jitter_sec: i64,
    pub retry_base_sec: i64,
    pub retry_max_sec: i64,
    pub retry_max_count: i64,
    pub status_file: String,
    pub log_level: String,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            api_base: "http://127.0.0.1:9199/".into(),
            api_user: String::new(),
            api_pass: String::new(),
            cache_tag: "cache_main".into(),
            dns_target: "127.0.0.1:5333".into(),
            watch_list: "/etc/oxidnsplus/watch.list".into(),
            mode: "list".into(),
            tick_sec: 5,
            grace_sec: 3,
            refresh_delay_ms: 1200,
            min_ttl_sec: 30,
            min_interval_sec: 10,
            max_interval_sec: 3600,
            jitter_sec: 5,
            retry_base_sec: 15,
            retry_max_sec: 300,
            retry_max_count: 8,
            status_file: "/tmp/oxidnsplus.status.json".into(),
            log_level: "info".into(),
        }
    }
}

/// One row of GET /api/plugins/<tag>/entries.
#[derive(Clone, Debug)]
pub struct CacheEntry {
    pub domain: String,
    pub record_type: String,
    pub ttl: i64,
    pub remaining_ttl: i64,
    pub answers: Json,          // raw answers_json value (string or array)
    #[allow(dead_code)]          // parsed for wire-format parity; not used for judgement
    pub last_access_ms: i64,
}

/// Decode answers_json in every wire form OxiDNS has shipped: a JSON array,
/// a JSON string containing that array, or the same string encoded twice.
fn answer_objects(raw: &Json) -> Vec<Json> {
    let mut cur = raw.clone();
    for _ in 0..2 {
        if let Some(s) = cur.as_str() {
            match json::parse(s) {
                Ok(j) => { cur = j; continue; }
                Err(_) => return Vec::new(),
            }
        }
        break;
    }
    match cur {
        Json::Arr(a) => a,
        _ => Vec::new(),
    }
}

impl CacheEntry {
    pub fn from_json(v: &Json) -> Option<CacheEntry> {
        let domain = v.get("domain")?.as_str()?.to_string();
        let record_type = v.get("record_type").and_then(|x| x.as_str()).unwrap_or("").to_string();
        let ttl = v.get("ttl").and_then(|x| x.as_i64()).unwrap_or(0);
        let remaining_ttl = v.get("remaining_ttl").and_then(|x| x.as_i64()).unwrap_or(0);
        let last_access_ms = v.get("last_access_unix_ms").and_then(|x| x.as_i64()).unwrap_or(0);
        let answers = v.get("answers_json").cloned().unwrap_or(Json::Null);
        Some(CacheEntry { domain, record_type, ttl, remaining_ttl, answers, last_access_ms })
    }

    pub fn normalized_domain(&self) -> String {
        let d = self.domain.trim_end_matches('.').to_lowercase();
        d
    }

    /// True only when the row carries a real A/AAAA answer. Negative / black-hole
    /// rows (0.0.0.0, ::) have no meaningful TTL lifecycle to prewarm.
    pub fn has_usable_answer(&self) -> bool {
        let q = self.record_type.to_uppercase();
        if q != "A" && q != "AAAA" {
            return false;
        }
        let answers = answer_objects(&self.answers);
        if answers.is_empty() {
            return false;
        }
        for a in &answers {
            for k in ["address", "data", "ip", "value"] {
                if let Some(v) = a.get(k).and_then(|x| x.as_str()) {
                    let t = v.trim().to_lowercase();
                    if t.is_empty() || t == "0.0.0.0" || t == "::" {
                        continue;
                    }
                    return true;
                }
            }
            if let Some(tv) = a.get("type") {
                let ts = match tv {
                    Json::Str(s) => s.to_uppercase(),
                    Json::Num(n) => format!("{}", *n as i64),
                    _ => String::new(),
                };
                let qnum = if q == "A" { "1" } else { "28" };
                if ts == q || ts == qnum {
                    // a parsed non-empty row with matching qtype is usable
                    if let Json::Obj(items) = a {
                        if items.len() > 1 { return true; }
                    }
                }
            }
        }
        false
    }
}

pub fn normalize_qtype(s: &str) -> String {
    if s.is_empty() {
        return "A".into();
    }
    match s.as_bytes()[0] {
        b'a' | b'A' => "A".into(),
        _ => "AAAA".into(),
    }
}

/// (domain, qtype) uniquely identifies a scheduled task.
#[derive(Clone, Debug, Eq, PartialEq, Hash, PartialOrd, Ord)]
pub struct Key {
    pub domain: String,
    pub qtype: String,
}

impl Key {
    pub fn new(domain: &str, qtype: &str) -> Key {
        Key { domain: domain.to_string(), qtype: qtype.to_string() }
    }
    pub fn text(&self) -> String {
        format!("{}|{}", self.domain, self.qtype)
    }
}

/// Per-key adaptive scheduling state. Instants are stored as epoch millis so
/// the struct stays Copy-friendly and easy to snapshot.
#[derive(Clone, Debug)]
pub struct TaskState {
    pub key: Key,
    pub deadline_ms: i64,       // 0 = unset
    pub last_ttl: i64,
    pub last_remaining: i64,
    pub backoff: i64,
    pub inflight: bool,
    pub last_probe_ms: i64,
    pub last_result: String,
    pub last_error: String,
    pub updated_ms: i64,
    pub in_watch_list: bool,
}

impl TaskState {
    pub fn new(key: Key, now_ms: i64) -> TaskState {
        TaskState {
            key,
            deadline_ms: 0,
            last_ttl: 0,
            last_remaining: 0,
            backoff: 0,
            inflight: false,
            last_probe_ms: 0,
            last_result: String::new(),
            last_error: String::new(),
            updated_ms: now_ms,
            in_watch_list: false,
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Stats {
    pub probes: i64,
    pub refresh_ok: i64,
    pub refresh_failed: i64,
    pub seeds: i64,
    pub skipped_short: i64,
}

#[derive(Clone, Debug)]
pub struct TaskView {
    pub domain: String,
    pub qtype: String,
    pub ttl: i64,
    pub remaining_ttl: i64,
    pub next_probe: String,
    pub source: String,      // "watch-list" / "auto-discovered"
    pub last_result: String,
    pub last_error: String,
    pub backoff: i64,
}

#[derive(Clone, Debug)]
pub struct Status {
    pub enabled: bool,
    pub mode: String,
    pub api_base: String,
    pub dns_target: String,
    pub started_at: String,  // RFC3339
    pub updated_at: String,
    pub tasks: Vec<TaskView>,
    pub stats: Stats,
}

impl Status {
    /// Serialize to the exact JSON shape the LuCI page consumes.
    pub fn to_json(&self) -> String {
        let mut s = String::new();
        s.push('{');
        s.push_str(&format!("\"enabled\":{},", self.enabled));
        s.push_str(&format!("\"mode\":{},", json::quote(&self.mode)));
        s.push_str(&format!("\"api_base\":{},", json::quote(&self.api_base)));
        s.push_str(&format!("\"dns_target\":{},", json::quote(&self.dns_target)));
        s.push_str(&format!("\"started_at\":{},", json::quote(&self.started_at)));
        s.push_str(&format!("\"updated_at\":{},", json::quote(&self.updated_at)));
        s.push_str("\"tasks\":[");
        for (i, t) in self.tasks.iter().enumerate() {
            if i > 0 { s.push(','); }
            s.push('{');
            s.push_str(&format!("\"domain\":{},", json::quote(&t.domain)));
            s.push_str(&format!("\"qtype\":{},", json::quote(&t.qtype)));
            s.push_str(&format!("\"ttl\":{},", t.ttl));
            s.push_str(&format!("\"remaining_ttl\":{},", t.remaining_ttl));
            s.push_str(&format!("\"next_probe\":{},", json::quote(&t.next_probe)));
            s.push_str(&format!("\"in\":{},", json::quote(&t.source)));
            s.push_str(&format!("\"last_result\":{},", json::quote(&t.last_result)));
            s.push_str(&format!("\"last_error\":{},", json::quote(&t.last_error)));
            s.push_str(&format!("\"backoff\":{}", t.backoff));
            s.push('}');
        }
        s.push_str("],\"stats\":{");
        s.push_str(&format!("\"probes\":{},", self.stats.probes));
        s.push_str(&format!("\"refresh_ok\":{},", self.stats.refresh_ok));
        s.push_str(&format!("\"refresh_failed\":{},", self.stats.refresh_failed));
        s.push_str(&format!("\"seeds\":{},", self.stats.seeds));
        s.push_str(&format!("\"skipped_short_ttl\":{}", self.stats.skipped_short));
        s.push_str("}}");
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(rt: &str, answers: &str) -> CacheEntry {
        CacheEntry {
            domain: "A.example.com.".into(),
            record_type: rt.into(),
            ttl: 120,
            remaining_ttl: 100,
            answers: json::parse(answers).unwrap(),
            last_access_ms: 0,
        }
    }

    #[test]
    fn normalized_domain() {
        assert_eq!(entry("A", "[]").normalized_domain(), "a.example.com");
    }

    #[test]
    fn usable_answer_array() {
        assert!(entry("A", r#"[{"address":"1.2.3.4"}]"#).has_usable_answer());
        assert!(!entry("A", r#"[{"address":"0.0.0.0"}]"#).has_usable_answer());
        assert!(!entry("AAAA", r#"[{"address":"::"}]"#).has_usable_answer());
        assert!(!entry("MX", r#"[{"address":"1.2.3.4"}]"#).has_usable_answer());
    }

    #[test]
    fn usable_answer_double_string() {
        let inner = r#"[{"address":"1.2.3.4"}]"#;
        let e1 = json::quote(inner);
        let e2 = json::quote(&e1);
        let ent = entry("A", &e2);
        assert!(ent.has_usable_answer());
    }

    #[test]
    fn status_json_shape() {
        let st = Status {
            enabled: true, mode: "list".into(), api_base: "http://x".into(),
            dns_target: "127.0.0.1:5333".into(), started_at: "t0".into(), updated_at: "t1".into(),
            tasks: vec![], stats: Stats::default(),
        };
        let j = st.to_json();
        let v = json::parse(&j).unwrap();
        assert_eq!(v.get("enabled").unwrap(), &Json::Bool(true));
        assert_eq!(v.get("mode").unwrap().as_str(), Some("list"));
        assert!(v.get("tasks").unwrap().as_array().unwrap().is_empty());
    }
}
