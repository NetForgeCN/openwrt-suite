//! oxidns-prewarmer - TTL-adaptive stale-hit prewarming for OxiDNS.
//!
//! Only two things: read TTL truth from the OxiDNS cache API, and send a DNS
//! query to OxiDNS's own listener at expire+grace so its native lazy cache
//! refreshes. No cache deletion, no upstream queries, no config writes.

mod api;
mod dns;
mod json;
mod model;
mod scheduler;

use std::collections::HashSet;
use std::fs;
use std::path::Path;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use api::OxiApi;
use dns::UdpProber;
use model::*;
use scheduler::{Scheduler, Snapshot};

fn parse_args() -> Config {
    let mut c = Config::default();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        let k = args[i].clone();
        let take = |i: &mut usize| -> String {
            if *i + 1 < args.len() {
                *i += 1;
                args[*i].clone()
            } else {
                String::new()
            }
        };
        match k.as_str() {
            "-api" | "--api" => c.api_base = take(&mut i),
            "-api-user" | "--api-user" => c.api_user = take(&mut i),
            "-api-pass" | "--api-pass" => c.api_pass = take(&mut i),
            "-cache-tag" | "--cache-tag" => c.cache_tag = take(&mut i),
            "-dns" | "--dns" => c.dns_target = take(&mut i),
            "-watch-list" | "--watch-list" => c.watch_list = take(&mut i),
            "-mode" | "--mode" => c.mode = take(&mut i),
            "-tick" | "--tick" => c.tick_sec = num(&take(&mut i), c.tick_sec),
            "-grace" | "--grace" => c.grace_sec = num(&take(&mut i), c.grace_sec),
            "-refresh-delay" | "--refresh-delay" => c.refresh_delay_ms = num(&take(&mut i), c.refresh_delay_ms),
            "-min-ttl" | "--min-ttl" => c.min_ttl_sec = num(&take(&mut i), c.min_ttl_sec),
            "-min-interval" | "--min-interval" => c.min_interval_sec = num(&take(&mut i), c.min_interval_sec),
            "-max-interval" | "--max-interval" => c.max_interval_sec = num(&take(&mut i), c.max_interval_sec),
            "-jitter" | "--jitter" => c.jitter_sec = num(&take(&mut i), c.jitter_sec),
            "-retry-base" | "--retry-base" => c.retry_base_sec = num(&take(&mut i), c.retry_base_sec),
            "-retry-max" | "--retry-max" => c.retry_max_sec = num(&take(&mut i), c.retry_max_sec),
            "-retry-max-count" | "--retry-max-count" => c.retry_max_count = num(&take(&mut i), c.retry_max_count),
            "-status-file" | "--status-file" => c.status_file = take(&mut i),
            "-log-level" | "--log-level" => c.log_level = take(&mut i),
            _ => {}
        }
        i += 1;
    }
    c
}

fn num(s: &str, default: i64) -> i64 {
    s.trim().parse::<i64>().unwrap_or(default)
}

fn logf(msg: &str) {
    eprintln!("[prewarmer] {}", msg);
}

fn load_watch_list(path: &str) -> Vec<Key> {
    let text = match fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) => {
            if !Path::new(path).exists() {
                logf(&format!("watch list not found ({}), starting empty", path));
            } else {
                logf(&format!("watch list: {}", e));
            }
            return Vec::new();
        }
    };
    let mut out = Vec::new();
    let mut seen: HashSet<Key> = HashSet::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let fields: Vec<&str> = line.split_whitespace().collect();
        let domain = fields[0].trim_end_matches('.').to_lowercase();
        if domain.is_empty() {
            continue;
        }
        let qtypes: Vec<String> = if fields.len() >= 2 {
            vec![normalize_qtype(fields[1])]
        } else {
            vec!["A".into(), "AAAA".into()]
        };
        for q in qtypes {
            let k = Key::new(&domain, &q);
            if seen.insert(k.clone()) {
                out.push(k);
            }
        }
    }
    out
}

fn write_status(path: &str, snap: &Snapshot) {
    if path.is_empty() {
        return;
    }
    let guard = match snap.lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    let st = match guard.as_ref() {
        Some(s) => s,
        None => return,
    };
    let body = st.to_json();
    let tmp = format!("{}.tmp", path);
    if let Err(e) = fs::write(&tmp, body.as_bytes()) {
        logf(&format!("status write failed: {}", e));
        return;
    }
    if let Err(e) = fs::rename(&tmp, path) {
        logf(&format!("status rename failed: {}", e));
    }
}

fn main() {
    let mut cfg = parse_args();
    // env var fallback for API password (same source as v9's OXIDNS_API_PASS)
    if cfg.api_pass.is_empty() {
        if let Ok(p) = std::env::var("OXIDNS_API_PASS") {
            cfg.api_pass = p;
        }
    }

    let watched = load_watch_list(&cfg.watch_list);
    let watched_count = watched.len();
    if cfg.mode == "list" && watched.is_empty() {
        logf("watch list is empty and mode=list: nothing to prewarm");
    }

    let api = Arc::new(OxiApi::new(&cfg.api_base, &cfg.api_user, &cfg.api_pass, &cfg.cache_tag));
    let prober = Arc::new(UdpProber::new(Duration::from_secs(2)));
    let mut sched = Scheduler::new(cfg.clone(), api, prober, watched);

    let snap: Snapshot = Arc::new(Mutex::new(None));
    sched.set_snapshot(snap.clone());

    // Status writer thread: snapshot every 2s, atomic rename.
    let status_path = cfg.status_file.clone();
    let writer_snap = snap.clone();
    thread::spawn(move || loop {
        write_status(&status_path, &writer_snap);
        thread::sleep(Duration::from_secs(2));
    });

    // Signal handling without a libc crate: install SIGTERM/SIGINT via raw
    // signal(2) using an extern declaration (works on musl/glibc Linux).
    let stop = sched.stop_flag();
    unsafe { install_signals(); }
    let stop_watch = stop.clone();
    thread::spawn(move || loop {
        if STOP_FLAG.load(Ordering::Relaxed) {
            logf("signal received, stopping");
            stop_watch.store(true, Ordering::Relaxed);
            break;
        }
        thread::sleep(Duration::from_millis(300));
    });

    logf(&format!("starting: api={} dns={} mode={} watched={} cache={} grace={}s",
        cfg.api_base, cfg.dns_target, cfg.mode, watched_count, cfg.cache_tag, cfg.grace_sec));

    sched.run(&|m| logf(m));
}

use std::sync::atomic::AtomicBool;
static STOP_FLAG: AtomicBool = AtomicBool::new(false);

extern "C" fn on_signal(_sig: i32) {
    STOP_FLAG.store(true, Ordering::Relaxed);
}

#[cfg(target_os = "linux")]
extern "C" {
    fn signal(sig: i32, handler: extern "C" fn(i32)) -> usize;
}

#[cfg(target_os = "linux")]
unsafe fn install_signals() {
    signal(15, on_signal); // SIGTERM
    signal(2, on_signal);  // SIGINT
}

#[cfg(not(target_os = "linux"))]
unsafe fn install_signals() {}
