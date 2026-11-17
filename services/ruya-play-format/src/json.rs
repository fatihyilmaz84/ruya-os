//! A small scan of JSON text for what `serde_json::Value` cannot tell: an object that names one key
//! twice. `Value` keeps the last, so a second reader of the same file (the launcher in the sandbox)
//! could see another value than this crate validated; the format refuses such a file.

use crate::problem::pointer_join;
use std::collections::HashSet;

/// The deepest nesting the scan follows (the manifest depth limit is checked before it runs).
const MAX_SCAN_DEPTH: usize = 64;

struct Scan<'a> {
    b: &'a [u8],
    i: usize,
}

impl Scan<'_> {
    fn ws(&mut self) {
        while self.i < self.b.len() && matches!(self.b[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }

    fn hex4(&mut self) -> Option<u32> {
        let h = self.b.get(self.i..self.i + 4)?;
        self.i += 4;
        u32::from_str_radix(std::str::from_utf8(h).ok()?, 16).ok()
    }

    /// A JSON string, decoded (so `"a"` and `"a"` are the same key).
    fn string(&mut self) -> Option<String> {
        if self.peek()? != b'"' {
            return None;
        }
        self.i += 1;
        let mut out: Vec<u8> = Vec::new();
        loop {
            let c = self.peek()?;
            self.i += 1;
            match c {
                b'"' => return String::from_utf8(out).ok(),
                b'\\' => {
                    let e = self.peek()?;
                    self.i += 1;
                    let ch = match e {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => {
                            let hi = self.hex4()?;
                            if (0xD800..0xDC00).contains(&hi) {
                                if self.b.get(self.i..self.i + 2)? != b"\\u" {
                                    return None;
                                }
                                self.i += 2;
                                let lo = self.hex4()?;
                                if !(0xDC00..0xE000).contains(&lo) {
                                    return None;
                                }
                                char::from_u32(0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00))?
                            } else {
                                char::from_u32(hi)?
                            }
                        }
                        _ => return None,
                    };
                    let mut buf = [0u8; 4];
                    out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                }
                _ => out.push(c),
            }
        }
    }

    /// Scan one value. `Ok(Some(pointer))` is the object that repeats a key; `Err` means the text
    /// is not JSON this scan understands (the real parser reports that).
    fn value(&mut self, at: &str, depth: usize) -> Result<Option<String>, ()> {
        if depth > MAX_SCAN_DEPTH {
            return Err(());
        }
        self.ws();
        match self.peek().ok_or(())? {
            b'{' => {
                self.i += 1;
                let mut seen: HashSet<String> = HashSet::new();
                self.ws();
                if self.peek() == Some(b'}') {
                    self.i += 1;
                    return Ok(None);
                }
                loop {
                    self.ws();
                    let key = self.string().ok_or(())?;
                    if !seen.insert(key.clone()) {
                        return Ok(Some(at.to_string()));
                    }
                    self.ws();
                    if self.peek() != Some(b':') {
                        return Err(());
                    }
                    self.i += 1;
                    if let Some(found) = self.value(&pointer_join(at, &key), depth + 1)? {
                        return Ok(Some(found));
                    }
                    self.ws();
                    match self.peek().ok_or(())? {
                        b',' => self.i += 1,
                        b'}' => {
                            self.i += 1;
                            return Ok(None);
                        }
                        _ => return Err(()),
                    }
                }
            }
            b'[' => {
                self.i += 1;
                self.ws();
                if self.peek() == Some(b']') {
                    self.i += 1;
                    return Ok(None);
                }
                let mut n = 0usize;
                loop {
                    if let Some(found) = self.value(&format!("{at}/{n}"), depth + 1)? {
                        return Ok(Some(found));
                    }
                    n += 1;
                    self.ws();
                    match self.peek().ok_or(())? {
                        b',' => self.i += 1,
                        b']' => {
                            self.i += 1;
                            return Ok(None);
                        }
                        _ => return Err(()),
                    }
                }
            }
            b'"' => {
                self.string().ok_or(())?;
                Ok(None)
            }
            _ => {
                while self.i < self.b.len()
                    && !matches!(
                        self.b[self.i],
                        b',' | b'}' | b']' | b' ' | b'\t' | b'\n' | b'\r'
                    )
                {
                    self.i += 1;
                }
                Ok(None)
            }
        }
    }
}

/// The JSON pointer of the first object in `bytes` that names a key twice, comparing keys after
/// their `\uXXXX` escapes are decoded. `None` when there is none (or the text is not JSON; the
/// real parser reports that).
pub fn find_duplicate_key(bytes: &[u8]) -> Option<String> {
    Scan { b: bytes, i: 0 }.value("", 0).ok().flatten()
}
