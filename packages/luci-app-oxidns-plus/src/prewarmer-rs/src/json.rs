//! Minimal JSON parser + serializer, standard library only.
//!
//! OxiDNS replies are small and well-formed; we only need objects, arrays,
//! numbers, strings and bools. TTL-like fields may arrive as either a JSON
//! number or a JSON string ("120") across releases, so `as_i64` accepts both.

#[derive(Clone, Debug, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl Json {
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(items) => items.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&Vec<Json>> {
        match self {
            Json::Arr(a) => Some(a),
            _ => None,
        }
    }

    /// Accept a JSON number, a numeric string, or a float like 120.0.
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Json::Num(n) => Some(*n as i64),
            Json::Str(s) => {
                let t = s.trim();
                if t.is_empty() || t == "null" {
                    Some(0)
                } else if let Ok(v) = t.parse::<i64>() {
                    Some(v)
                } else {
                    t.parse::<f64>().ok().map(|v| v as i64)
                }
            }
            _ => None,
        }
    }

}

pub struct Parser<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> Parser<'a> {
    pub fn new(s: &'a str) -> Self {
        Parser { b: s.as_bytes(), i: 0 }
    }

    pub fn parse(mut self) -> Result<Json, String> {
        self.ws();
        let v = self.value()?;
        self.ws();
        if self.i != self.b.len() {
            return Err(format!("trailing bytes at {}", self.i));
        }
        Ok(v)
    }

    fn ws(&mut self) {
        while self.i < self.b.len() && matches!(self.b[self.i], b' ' | b'\n' | b'\r' | b'\t') {
            self.i += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }

    fn value(&mut self) -> Result<Json, String> {
        self.ws();
        match self.peek() {
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'"') => Ok(Json::Str(self.string()?)),
            Some(b't') => { self.lit(b"true")?; Ok(Json::Bool(true)) }
            Some(b'f') => { self.lit(b"false")?; Ok(Json::Bool(false)) }
            Some(b'n') => { self.lit(b"null")?; Ok(Json::Null) }
            Some(b'-') | Some(b'0'..=b'9') => self.number(),
            other => Err(format!("unexpected token {:?} at {}", other, self.i)),
        }
    }

    fn lit(&mut self, word: &[u8]) -> Result<(), String> {
        if self.b.get(self.i..self.i + word.len()) == Some(word) {
            self.i += word.len();
            Ok(())
        } else {
            Err(format!("bad literal at {}", self.i))
        }
    }

    fn object(&mut self) -> Result<Json, String> {
        self.i += 1; // {
        let mut items = Vec::new();
        self.ws();
        if self.peek() == Some(b'}') {
            self.i += 1;
            return Ok(Json::Obj(items));
        }
        loop {
            self.ws();
            if self.peek() != Some(b'"') {
                return Err(format!("object key expected at {}", self.i));
            }
            let key = self.string()?;
            self.ws();
            if self.peek() != Some(b':') {
                return Err(format!("colon expected at {}", self.i));
            }
            self.i += 1;
            let val = self.value()?;
            items.push((key, val));
            self.ws();
            match self.peek() {
                Some(b',') => { self.i += 1; }
                Some(b'}') => { self.i += 1; break; }
                _ => return Err(format!("comma or }} expected at {}", self.i)),
            }
        }
        Ok(Json::Obj(items))
    }

    fn array(&mut self) -> Result<Json, String> {
        self.i += 1; // [
        let mut items = Vec::new();
        self.ws();
        if self.peek() == Some(b']') {
            self.i += 1;
            return Ok(Json::Arr(items));
        }
        loop {
            let val = self.value()?;
            items.push(val);
            self.ws();
            match self.peek() {
                Some(b',') => { self.i += 1; }
                Some(b']') => { self.i += 1; break; }
                _ => return Err(format!("comma or ] expected at {}", self.i)),
            }
        }
        Ok(Json::Arr(items))
    }

    fn string(&mut self) -> Result<String, String> {
        self.i += 1; // opening quote
        let mut out = String::new();
        while self.i < self.b.len() {
            let c = self.b[self.i];
            self.i += 1;
            match c {
                b'"' => return Ok(out),
                b'\\' => {
                    if self.i >= self.b.len() {
                        return Err("dangling escape".into());
                    }
                    let e = self.b[self.i];
                    self.i += 1;
                    match e {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{0008}'),
                        b'f' => out.push('\u{000C}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            if self.i + 4 > self.b.len() {
                                return Err("bad unicode escape".into());
                            }
                            let hex = std::str::from_utf8(&self.b[self.i..self.i + 4])
                                .map_err(|_| "bad unicode escape")?;
                            let cp = u32::from_str_radix(hex, 16).map_err(|_| "bad unicode escape")?;
                            self.i += 4;
                            if let Some(ch) = char::from_u32(cp) {
                                out.push(ch);
                            }
                        }
                        _ => return Err(format!("bad escape \\{}", e as char)),
                    }
                }
                _ => {
                    // Preserve raw UTF-8 bytes; collect a full codepoint.
                    let start = self.i - 1;
                    if c < 0x80 {
                        out.push(c as char);
                    } else {
                        let width = if c & 0xE0 == 0xC0 { 2 } else if c & 0xF0 == 0xE0 { 3 } else { 4 };
                        let end = (start + width).min(self.b.len());
                        let s = std::str::from_utf8(&self.b[start..end]).map_err(|_| "bad utf8")?;
                        out.push_str(s);
                        self.i = end;
                    }
                }
            }
        }
        Err("unterminated string".into())
    }

    fn number(&mut self) -> Result<Json, String> {
        let start = self.i;
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        while matches!(self.peek(), Some(b'0'..=b'9') | Some(b'.') | Some(b'e') | Some(b'E') | Some(b'+') | Some(b'-')) {
            self.i += 1;
        }
        let s = std::str::from_utf8(&self.b[start..self.i]).map_err(|_| "bad number")?;
        s.parse::<f64>().map(Json::Num).map_err(|_| format!("bad number {}", s))
    }
}

pub fn parse(s: &str) -> Result<Json, String> {
    Parser::new(s).parse()
}

/// Escape a string for embedding in a JSON string literal (with surrounding quotes).
pub fn quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{0008}' => out.push_str("\\b"),
            '\u{000C}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_basic() {
        let v = parse(r#"{"domain":"a.com","ttl":120,"remaining_ttl":"96"}"#).unwrap();
        assert_eq!(v.get("domain").unwrap().as_str(), Some("a.com"));
        assert_eq!(v.get("ttl").unwrap().as_i64(), Some(120));
        assert_eq!(v.get("remaining_ttl").unwrap().as_i64(), Some(96));
    }

    #[test]
    fn parse_escaped_string() {
        let v = parse(r#"{"x":"a\"b\\c\n"}"#).unwrap();
        assert_eq!(v.get("x").unwrap().as_str(), Some("a\"b\\c\n"));
    }

    #[test]
    fn nested_double_encoded_answers() {
        let inner = r#"[{"address":"1.2.3.4"}]"#;
        let encoded = quote(inner);
        let encoded2 = quote(&encoded);
        let doc = format!(r#"{{"answers_json":{}}}"#, encoded2);
        let v = parse(&doc).unwrap();
        let mut s = v.get("answers_json").unwrap().as_str().unwrap().to_string();
        // mirror the two-layer unwrap done in model.rs
        for _ in 0..2 {
            if let Ok(j) = parse(&s) {
                if let Some(x) = j.as_str() {
                    s = x.to_string();
                    continue;
                }
                let arr = j.as_array().unwrap();
                assert_eq!(arr[0].get("address").unwrap().as_str(), Some("1.2.3.4"));
                break;
            }
            break;
        }
    }

    #[test]
    fn quote_roundtrip() {
        let q = quote("a\"b\\c\n");
        let v = parse(&q).unwrap();
        assert_eq!(v.as_str(), Some("a\"b\\c\n"));
    }
}
