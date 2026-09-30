// The part of TOML that bolt.toml and bolt.lock use: [tables], [[arrays of tables]], dotted
// headers, key = value with strings ("basic" and 'literal'), integers, booleans, arrays (can span
// lines) and inline tables. Errors name the line.
use std::collections::BTreeMap;

/// a TOML value (only the kinds bolt uses)
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Str(String),
    Int(i64),
    Bool(bool),
    Array(Vec<Value>),
    Table(Table),
}

pub type Table = BTreeMap<String, Value>;

impl Value {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }
    pub fn as_table(&self) -> Option<&Table> {
        match self {
            Value::Table(t) => Some(t),
            _ => None,
        }
    }
    pub fn as_array(&self) -> Option<&[Value]> {
        match self {
            Value::Array(a) => Some(a),
            _ => None,
        }
    }
}

/// the parser: the bytes, the position, and the line number for errors
struct P<'a> {
    s: &'a [u8],
    i: usize,
    line: usize,
}

type R<T> = Result<T, String>;

impl P<'_> {
    fn err<T>(&self, msg: &str) -> R<T> {
        Err(format!("line {}: {msg}", self.line))
    }
    fn peek(&self) -> Option<u8> {
        self.s.get(self.i).copied()
    }
    /// spaces, tabs and comments; newlines too when `lines`
    fn skip(&mut self, lines: bool) {
        while let Some(c) = self.peek() {
            match c {
                b' ' | b'\t' | b'\r' => self.i += 1,
                b'\n' if lines => {
                    self.i += 1;
                    self.line += 1;
                }
                b'#' => {
                    while self.peek().is_some_and(|c| c != b'\n') {
                        self.i += 1;
                    }
                }
                _ => break,
            }
        }
    }
    fn eat(&mut self, c: u8) -> bool {
        if self.peek() == Some(c) {
            self.i += 1;
            true
        } else {
            false
        }
    }
    /// a bare or quoted key
    fn key(&mut self) -> R<String> {
        self.skip(false);
        match self.peek() {
            Some(b'"') | Some(b'\'') => self.string(),
            _ => {
                let st = self.i;
                while self.peek().is_some_and(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-') {
                    self.i += 1;
                }
                if st == self.i {
                    return self.err("expected a key");
                }
                Ok(String::from_utf8_lossy(&self.s[st..self.i]).into_owned())
            }
        }
    }
    /// a.b.c
    fn dotted(&mut self) -> R<Vec<String>> {
        let mut out = vec![self.key()?];
        loop {
            self.skip(false);
            if !self.eat(b'.') {
                return Ok(out);
            }
            out.push(self.key()?);
        }
    }
    /// a quoted string: basic ("...", with escapes) or literal ('...'); both end on their line
    fn string(&mut self) -> R<String> {
        let q = self.peek().unwrap();
        self.i += 1;
        let mut out = Vec::new();
        loop {
            let Some(c) = self.peek() else { return self.err("unterminated string") };
            self.i += 1;
            match c {
                _ if c == q => return Ok(String::from_utf8_lossy(&out).into_owned()),
                b'\n' => return self.err("strings end on the line they start"),
                b'\\' if q == b'"' => {
                    let Some(e) = self.peek() else { return self.err("unterminated string") };
                    self.i += 1;
                    match e {
                        b'n' => out.push(b'\n'),
                        b't' => out.push(b'\t'),
                        b'r' => out.push(b'\r'),
                        b'"' => out.push(b'"'),
                        b'\\' => out.push(b'\\'),
                        b'u' => {
                            let hex = self.s.get(self.i..self.i + 4).ok_or(format!("line {}: bad \\u escape", self.line))?;
                            let cp = u32::from_str_radix(&String::from_utf8_lossy(hex), 16).map_err(|_| format!("line {}: bad \\u escape", self.line))?;
                            let ch = char::from_u32(cp).ok_or(format!("line {}: bad \\u escape", self.line))?;
                            out.extend(ch.to_string().bytes());
                            self.i += 4;
                        }
                        _ => return self.err("unknown escape"),
                    }
                }
                _ => out.push(c),
            }
        }
    }
    /// one value; an array may span lines, an inline table may not
    fn value(&mut self) -> R<Value> {
        self.skip(false);
        match self.peek() {
            Some(b'"') | Some(b'\'') => Ok(Value::Str(self.string()?)),
            Some(b'[') => {
                self.i += 1;
                let mut items = Vec::new();
                loop {
                    self.skip(true);
                    if self.eat(b']') {
                        return Ok(Value::Array(items));
                    }
                    items.push(self.value()?);
                    self.skip(true);
                    if !self.eat(b',') {
                        self.skip(true);
                        if !self.eat(b']') {
                            return self.err("expected , or ] in the array");
                        }
                        return Ok(Value::Array(items));
                    }
                }
            }
            Some(b'{') => {
                self.i += 1;
                let mut t = Table::new();
                self.skip(false);
                if self.eat(b'}') {
                    return Ok(Value::Table(t));
                }
                loop {
                    let path = self.dotted()?;
                    self.skip(false);
                    if !self.eat(b'=') {
                        return self.err("expected = in the inline table");
                    }
                    let v = self.value()?;
                    insert(&mut t, &path, v).map_err(|e| format!("line {}: {e}", self.line))?;
                    self.skip(false);
                    if self.eat(b'}') {
                        return Ok(Value::Table(t));
                    }
                    if !self.eat(b',') {
                        return self.err("expected , or } in the inline table");
                    }
                }
            }
            _ => {
                let st = self.i;
                while self.peek().is_some_and(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-' || c == b'+') {
                    self.i += 1;
                }
                let word = String::from_utf8_lossy(&self.s[st..self.i]).into_owned();
                match word.as_str() {
                    "true" => Ok(Value::Bool(true)),
                    "false" => Ok(Value::Bool(false)),
                    w => match w.replace('_', "").parse::<i64>() {
                        Ok(n) => Ok(Value::Int(n)),
                        Err(_) => self.err(&format!("expected a value, found '{w}'")),
                    },
                }
            }
        }
    }
}

/// sets t[a][b]...[last] = v, making the tables on the way; setting a key twice is an error
fn insert(t: &mut Table, path: &[String], v: Value) -> Result<(), String> {
    let (last, parents) = path.split_last().unwrap();
    let mut cur = t;
    for k in parents {
        let e = cur.entry(k.clone()).or_insert_with(|| Value::Table(Table::new()));
        match e {
            Value::Table(inner) => cur = inner,
            _ => return Err(format!("'{k}' is not a table")),
        }
    }
    if cur.contains_key(last) {
        return Err(format!("'{last}' is set twice"));
    }
    cur.insert(last.clone(), v);
    Ok(())
}

/// the table a [header] or [[header]] points at, creating it
fn table_at<'a>(root: &'a mut Table, path: &[String], array: bool) -> Result<&'a mut Table, String> {
    let (last, parents) = path.split_last().unwrap();
    let mut cur = root;
    for k in parents {
        let e = cur.entry(k.clone()).or_insert_with(|| Value::Table(Table::new()));
        cur = match e {
            Value::Table(t) => t,
            Value::Array(a) => match a.last_mut() {
                Some(Value::Table(t)) => t,
                _ => return Err(format!("'{k}' is not a table")),
            },
            _ => return Err(format!("'{k}' is not a table")),
        };
    }
    if array {
        let e = cur.entry(last.clone()).or_insert_with(|| Value::Array(Vec::new()));
        let Value::Array(a) = e else { return Err(format!("'{last}' is not an array of tables")) };
        a.push(Value::Table(Table::new()));
        let Some(Value::Table(t)) = a.last_mut() else { unreachable!() };
        return Ok(t);
    }
    let e = cur.entry(last.clone()).or_insert_with(|| Value::Table(Table::new()));
    match e {
        Value::Table(t) => Ok(t),
        _ => Err(format!("'{last}' is not a table")),
    }
}

/// a whole document as its root table
pub fn parse(src: &str) -> R<Table> {
    let mut root = Table::new();
    let mut p = P { s: src.as_bytes(), i: 0, line: 1 };
    // the last [header] (and whether it was [[header]]): key = value lines go in its table
    let mut header: (Vec<String>, bool) = (Vec::new(), false);
    loop {
        p.skip(true);
        let Some(c) = p.peek() else { return Ok(root) };
        if c == b'[' {
            p.i += 1;
            let array = p.eat(b'[');
            let path = p.dotted()?;
            p.skip(false);
            if !p.eat(b']') || (array && !p.eat(b']')) {
                return p.err("expected ] after the table name");
            }
            table_at(&mut root, &path, array).map_err(|e| format!("line {}: {e}", p.line))?;
            header = (path, array);
        } else {
            let key = p.dotted()?;
            p.skip(false);
            if !p.eat(b'=') {
                return p.err("expected = after the key");
            }
            let v = p.value()?;
            let line = p.line;
            // re-find the current table: [[x]] headers mean "the last element"
            let t = if header.0.is_empty() { &mut root } else { current(&mut root, &header.0).map_err(|e| format!("line {line}: {e}"))? };
            insert(t, &key, v).map_err(|e| format!("line {line}: {e}"))?;
        }
        p.skip(false);
        if p.peek().is_some_and(|c| c != b'\n') {
            return p.err("expected the end of the line");
        }
    }
}

/// the table under a header's path, following an array of tables to its last element
fn current<'a>(root: &'a mut Table, path: &[String]) -> Result<&'a mut Table, String> {
    let mut cur = root;
    for k in path {
        cur = match cur.get_mut(k) {
            Some(Value::Table(t)) => t,
            Some(Value::Array(a)) => match a.last_mut() {
                Some(Value::Table(t)) => t,
                _ => return Err(format!("'{k}' is not a table")),
            },
            _ => return Err(format!("'{k}' is not a table")),
        };
    }
    Ok(cur)
}

/// write a string as a TOML basic string
pub fn quote(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
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
    fn manifest() {
        let t = parse(
            r#"
# comment
[package]
name = "app"   # trailing
version = '0.1.0'

[[bin]]
name = "app"
path = "src"

[[bin]]
name = "tool"

[dependencies]
geo = { path = "../geo" }
json = { git = "https://x/y.git", rev = "abc" }

[std]
none = false
flags = ["a",
         "b"]
n = 1_000
"#,
        )
        .unwrap();
        assert_eq!(t["package"].as_table().unwrap()["name"], Value::Str("app".into()));
        let bins = t["bin"].as_array().unwrap();
        assert_eq!(bins.len(), 2);
        assert_eq!(bins[1].as_table().unwrap()["name"], Value::Str("tool".into()));
        let deps = t["dependencies"].as_table().unwrap();
        assert_eq!(deps["json"].as_table().unwrap()["rev"], Value::Str("abc".into()));
        assert_eq!(t["std"].as_table().unwrap()["flags"].as_array().unwrap().len(), 2);
        assert_eq!(t["std"].as_table().unwrap()["n"], Value::Int(1000));
        assert!(parse("[a]\nx = 1\nx = 2").unwrap_err().contains("line 3"));
        assert!(parse("x = \"open").is_err());
    }
}
