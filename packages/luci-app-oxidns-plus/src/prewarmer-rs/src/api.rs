//! Minimal HTTP/1.1 client for the OxiDNS management API. The API is plain
//! HTTP on loopback/LAN with optional Basic auth, so a raw TcpStream is enough
//! and keeps the binary dependency-free.

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

use crate::json::{self, Json};
use crate::model::CacheEntry;

/// Narrow trait so tests can inject a fake source without a live OxiDNS.
pub trait EntrySource: Send + Sync {
    fn entries(&self, qname: &str, limit: i64) -> Result<Vec<CacheEntry>, String>;
}

pub struct OxiApi {
    base: String,
    user: String,
    pass: String,
    tag: String,
}

impl OxiApi {
    pub fn new(base: &str, user: &str, pass: &str, tag: &str) -> OxiApi {
        let mut b = base.trim_end_matches('/').to_string();
        if !b.contains("://") {
            b = format!("http://{}", b);
        }
        OxiApi { base: b, user: user.into(), pass: pass.into(), tag: tag.into() }
    }

    fn http_get(&self, path_query: &str) -> Result<(i32, String), String> {
        // base is http://host:port (no trailing slash after new())
        let scheme_end = self.base.find("://").ok_or("bad api base")? + 3;
        let authority = &self.base[scheme_end..];
        let (host, port) = match authority.rfind(':') {
            Some(p) => (&authority[..p], authority[p + 1..].parse::<u16>().map_err(|_| "bad port")?),
            None => (authority, 80u16),
        };

        let addr = (host, port).to_socket_addrs().map_err(|e| format!("resolve: {}", e))?.next()
            .ok_or("no address")?;
        let mut stream = TcpStream::connect_timeout(&addr, Duration::from_secs(4))
            .map_err(|e| format!("connect: {}", e))?;
        stream.set_read_timeout(Some(Duration::from_secs(6))).ok();
        stream.set_write_timeout(Some(Duration::from_secs(6))).ok();

        let mut req = format!("GET {} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n", path_query, authority);
        if !self.user.is_empty() {
            req.push_str(&format!("Authorization: Basic {}\r\n", base64_encode(&format!("{}:{}", self.user, self.pass))));
        }
        req.push_str("\r\n");
        stream.write_all(req.as_bytes()).map_err(|e| format!("write: {}", e))?;

        let mut raw = Vec::new();
        stream.read_to_end(&mut raw).map_err(|e| format!("read: {}", e))?;
        if raw.len() > 8 * 1024 * 1024 {
            raw.truncate(8 * 1024 * 1024);
        }
        let text = String::from_utf8_lossy(&raw).to_string();

        let split = text.find("\r\n\r\n").ok_or("no http header terminator")?;
        let head = &text[..split];
        let body = &text[split + 4..];
        let status = head.lines().next().and_then(|l| l.split_whitespace().nth(1))
            .and_then(|c| c.parse::<i32>().ok()).ok_or("no http status")?;
        Ok((status, body.to_string()))
    }
}

impl EntrySource for OxiApi {
    fn entries(&self, qname: &str, limit: i64) -> Result<Vec<CacheEntry>, String> {
        let lim = if limit <= 0 { 1000 } else { limit };
        let mut pq = format!("/api/plugins/{}/entries?", self.tag);
        if !qname.is_empty() {
            pq.push_str(&format!("qname={}&", url_encode(qname)));
        }
        pq.push_str(&format!("limit={}", lim));

        let (status, body) = self.http_get(&pq)?;
        if status < 200 || status >= 300 {
            return Err(format!("api status {}", status));
        }
        let top = json::parse(&body).map_err(|e| format!("bad json: {}", e))?;

        // {"entries":[...]}  or  {"ok":true,"entries":{"entries":[...]}}
        if let Some(e) = top.get("entries") {
            if let Some(arr) = e.as_array() {
                return Ok(parse_rows(arr));
            }
            if let Some(inner) = e.get("entries").and_then(|x| x.as_array()) {
                return Ok(parse_rows(inner));
            }
        }
        Err(format!("unexpected entries envelope: {}", &body[..body.len().min(120)]))
    }
}

fn parse_rows(arr: &[Json]) -> Vec<CacheEntry> {
    arr.iter().filter_map(CacheEntry::from_json).collect()
}

fn url_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

fn base64_encode(s: &str) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let b = s.as_bytes();
    let mut out = String::new();
    let mut i = 0;
    while i < b.len() {
        let n0 = b[i] as u32;
        let n1 = if i + 1 < b.len() { b[i + 1] as u32 } else { 0 };
        let n2 = if i + 2 < b.len() { b[i + 2] as u32 } else { 0 };
        let n = (n0 << 16) | (n1 << 8) | n2;
        out.push(T[((n >> 18) & 63) as usize] as char);
        out.push(T[((n >> 12) & 63) as usize] as char);
        out.push(if i + 1 < b.len() { T[((n >> 6) & 63) as usize] as char } else { '=' });
        out.push(if i + 2 < b.len() { T[(n & 63) as usize] as char } else { '=' });
        i += 3;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basic_auth_encoding() {
        // "admin:secret" -> YWRtaW46c2VjcmV0
        assert_eq!(base64_encode("admin:secret"), "YWRtaW46c2VjcmV0");
        assert_eq!(base64_encode("a"), "YQ==");
    }

    #[test]
    fn url_encoding() {
        assert_eq!(url_encode("a b.com"), "a%20b.com");
        assert_eq!(url_encode("a.example.com"), "a.example.com");
    }

    struct Fake {
        rows: Vec<CacheEntry>,
    }
    impl EntrySource for Fake {
        fn entries(&self, _q: &str, _l: i64) -> Result<Vec<CacheEntry>, String> {
            Ok(self.rows.clone())
        }
    }

    #[test]
    fn envelope_parsing() {
        let doc = r#"{"entries":[{"domain":"a.com","record_type":"A","ttl":120,"remaining_ttl":"90","answers_json":"[{\"address\":\"1.2.3.4\"}]"}]}"#;
        let v = json::parse(doc).unwrap();
        let arr = v.get("entries").unwrap().as_array().unwrap();
        let rows = parse_rows(arr);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].normalized_domain(), "a.com");
        assert_eq!(rows[0].ttl, 120);
        assert_eq!(rows[0].remaining_ttl, 90);
        assert!(rows[0].has_usable_answer());
        let _f = Fake { rows };
    }
}
