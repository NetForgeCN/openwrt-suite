//! DNS prober. The point is NOT to read the answer: it is to make OxiDNS see a
//! query for a stale entry so its native lazy cache fires a background refresh.
//! We never cache, never store IPs, never touch an upstream ourselves.

use std::net::UdpSocket;
use std::time::Duration;

pub trait Prober: Send + Sync {
    fn probe(&self, target: &str, domain: &str, qtype: &str) -> Result<(), String>;
}

pub struct UdpProber {
    timeout: Duration,
}

impl UdpProber {
    pub fn new(timeout: Duration) -> UdpProber {
        UdpProber { timeout }
    }
}

impl Prober for UdpProber {
    fn probe(&self, target: &str, domain: &str, qtype: &str) -> Result<(), String> {
        let qt = if qtype.eq_ignore_ascii_case("AAAA") { 28u16 } else { 1u16 };
        let packet = build_query(domain, qt)?;
        let socket = UdpSocket::bind("0.0.0.0:0").map_err(|e| format!("bind: {}", e))?;
        socket.set_read_timeout(Some(self.timeout)).ok();
        socket.set_write_timeout(Some(self.timeout)).ok();
        socket.send_to(&packet, target).map_err(|e| format!("dns send: {}", e))?;
        let mut buf = [0u8; 512];
        let n = socket.recv(&mut buf).map_err(|e| format!("dns recv: {}", e))?;
        if n < 12 {
            return Err(format!("short dns reply ({} bytes)", n));
        }
        // Any response (even REFUSED/SERVFAIL/NXDOMAIN) means the trigger landed.
        // Only a totally absent reply counts as a transport failure.
        Ok(())
    }
}

/// A standards-compliant DNS question: RD set, one question, no EDNS/DO.
pub fn build_query(domain: &str, qtype: u16) -> Result<Vec<u8>, String> {
    let domain = domain.trim().trim_end_matches('.');
    if domain.is_empty() {
        return Err("empty domain".into());
    }
    let mut buf: Vec<u8> = Vec::with_capacity(12 + domain.len() + 6);

    // Header: ID (odd), flags=RD, QDCOUNT=1.
    let seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH).unwrap_or_default().subsec_nanos();
    let id = ((seed & 0xffff) | 1) as u16;
    buf.extend_from_slice(&id.to_be_bytes());
    buf.extend_from_slice(&0x0100u16.to_be_bytes());
    buf.extend_from_slice(&1u16.to_be_bytes());
    buf.extend_from_slice(&0u16.to_be_bytes());
    buf.extend_from_slice(&0u16.to_be_bytes());
    buf.extend_from_slice(&0u16.to_be_bytes());

    for label in domain.split('.') {
        if label.len() > 63 {
            return Err(format!("label too long: {}", label));
        }
        buf.push(label.len() as u8);
        buf.extend_from_slice(label.as_bytes());
    }
    buf.push(0); // root label
    buf.extend_from_slice(&qtype.to_be_bytes());
    buf.extend_from_slice(&1u16.to_be_bytes()); // IN
    Ok(buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_structure() {
        let p = build_query("a.example.com", 1).unwrap();
        assert_eq!(p.len(), 12 + 1 + 1 + 7 + 1 + 3 + 1 + 1 + 4);
        assert_eq!(&p[2..4], &[0x01, 0x00]); // RD
        assert_eq!(&p[4..6], &[0x00, 0x01]); // QD=1
        // labels: 1 a, 7 example, 3 com, 0 root
        assert_eq!(p[12], 1);
        assert_eq!(&p[13..14], b"a");
        assert_eq!(p[14], 7);
        assert_eq!(&p[15..22], b"example");
        assert_eq!(p[22], 3);
        assert_eq!(&p[23..26], b"com");
        assert_eq!(p[26], 0);
        assert_eq!(&p[27..29], &[0x00, 0x01]); // A
        assert_eq!(&p[29..31], &[0x00, 0x01]); // IN
    }

    #[test]
    fn empty_domain_rejected() {
        assert!(build_query("", 1).is_err());
    }
}
