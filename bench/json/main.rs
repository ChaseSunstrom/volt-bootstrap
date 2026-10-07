// json: generate a JSON array of n objects (nested arrays and objects, escaped strings, ints and
// decimals) as text, parse it into a tree, then walk the tree for counts and sums; Rust hand-writes a
// recursive-descent parser into an enum tree (String, Vec, members in order), numbers by str::parse,
// failures as None, and walks with a match
use std::fmt::Write;

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
}

// ---------- the text ----------

const WORDS: [&str; 8] = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"];
const ESCAPES: [&str; 5] = ["\\\"", "\\\\", "\\n", "\\t", "\\u00e9"];

// a string of 2 to 5 pieces, a quarter of them escapes
fn put_name(out: &mut String, rng: &mut Rng) {
    out.push('"');
    let pieces = 2 + rng.next() % 4;
    for _ in 0..pieces {
        if rng.next() % 4 == 0 {
            out.push_str(ESCAPES[(rng.next() % 5) as usize]);
        } else {
            out.push_str(WORDS[(rng.next() % 8) as usize]);
        }
    }
    out.push('"');
}

fn put_object(out: &mut String, rng: &mut Rng, i: i64) {
    write!(out, "{{\"id\":{i},\"name\":").unwrap();
    put_name(out, rng);
    let cents = rng.next() % 1000000;
    write!(out, ",\"score\":{}.{:02},\"tags\":[", cents / 100, cents % 100).unwrap();
    let tags = rng.next() % 5;
    for k in 0..tags {
        if k > 0 {
            out.push(',');
        }
        out.push('"');
        out.push_str(WORDS[(rng.next() % 8) as usize]);
        out.push('"');
    }
    out.push_str("],\"pos\":[");
    for k in 0..3 {
        if k > 0 {
            out.push(',');
        }
        write!(out, "{}", (rng.next() % 2000001) as i64 - 1000000).unwrap();
    }
    out.push_str(if rng.next() % 2 != 0 { "],\"active\":true" } else { "],\"active\":false" });
    write!(out, ",\"meta\":{{\"level\":{}", rng.next() % 10).unwrap();
    write!(out, ",\"ratio\":0.{:03},\"note\":", rng.next() % 1000).unwrap();
    if rng.next() % 3 == 0 {
        out.push_str("null");
    } else {
        put_name(out, rng);
    }
    out.push_str("}}");
}

// ---------- the tree ----------

enum Value {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Value>),
    Obj(Vec<(String, Value)>),
}

impl Value {
    // an object's member called key
    fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Obj(members) => members.iter().find(|(name, _)| name == key).map(|(_, v)| v),
            _ => None,
        }
    }
}

// ---------- parsing: None for text that isn't JSON ----------

struct Parser<'a> {
    s: &'a [u8],
    p: usize,
}

fn hex4(s: &[u8]) -> Option<u32> {
    s.iter().try_fold(0, |v, &c| Some(v << 4 | (c as char).to_digit(16)?))
}

impl Parser<'_> {
    fn skip_space(&mut self) {
        while self.p < self.s.len() && matches!(self.s[self.p], b' ' | b'\t' | b'\n' | b'\r') {
            self.p += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.s.get(self.p).copied()
    }

    // the string literal at p (its opening quote), unescaped: escapes only shrink, so the raw length
    // is enough
    fn string(&mut self) -> Option<String> {
        let s = self.s;
        let mut i = self.p + 1;
        let mut e = i;
        while e < s.len() && s[e] != b'"' {
            e += if s[e] == b'\\' { 2 } else { 1 };
        }
        if e >= s.len() {
            return None;
        }
        let mut o = Vec::with_capacity(e - i);
        while i < e {
            let c = s[i];
            if c < 0x20 {
                return None;
            }
            if c != b'\\' {
                o.push(c);
                i += 1;
                continue;
            }
            let esc = s[i + 1];
            i += 2;
            match esc {
                b'n' => o.push(b'\n'),
                b't' => o.push(b'\t'),
                b'r' => o.push(b'\r'),
                b'b' => o.push(8),
                b'f' => o.push(12),
                b'"' | b'\\' | b'/' => o.push(esc),
                b'u' => {
                    if e - i < 4 {
                        return None;
                    }
                    let mut cp = hex4(&s[i..i + 4])?;
                    i += 4;
                    // a surrogate pair is one code point
                    if (0xD800..0xDC00).contains(&cp) && e - i >= 6 && s[i] == b'\\' && s[i + 1] == b'u' {
                        if let Some(lo @ 0xDC00..0xE000) = hex4(&s[i + 2..i + 6]) {
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            i += 6;
                        }
                    }
                    o.extend_from_slice(char::from_u32(cp)?.encode_utf8(&mut [0; 4]).as_bytes());
                }
                _ => return None,
            }
        }
        self.p = e + 1;
        String::from_utf8(o).ok()
    }

    fn word(&mut self, w: &[u8]) -> bool {
        let found = self.s[self.p..].starts_with(w);
        if found {
            self.p += w.len();
        }
        found
    }

    fn value(&mut self, depth: u32) -> Option<Value> {
        if depth > 512 {
            return None;
        }
        self.skip_space();
        match self.peek()? {
            b'[' => {
                self.p += 1;
                let mut items = Vec::new();
                self.skip_space();
                if self.peek() == Some(b']') {
                    self.p += 1;
                    return Some(Value::Arr(items));
                }
                loop {
                    items.push(self.value(depth + 1)?);
                    self.skip_space();
                    match self.peek()? {
                        b',' => self.p += 1,
                        b']' => {
                            self.p += 1;
                            return Some(Value::Arr(items));
                        }
                        _ => return None,
                    }
                }
            }
            b'{' => {
                self.p += 1;
                let mut members = Vec::new();
                self.skip_space();
                if self.peek() == Some(b'}') {
                    self.p += 1;
                    return Some(Value::Obj(members));
                }
                loop {
                    self.skip_space();
                    if self.peek()? != b'"' {
                        return None;
                    }
                    let name = self.string()?;
                    self.skip_space();
                    if self.peek()? != b':' {
                        return None;
                    }
                    self.p += 1;
                    members.push((name, self.value(depth + 1)?));
                    self.skip_space();
                    match self.peek()? {
                        b',' => self.p += 1,
                        b'}' => {
                            self.p += 1;
                            return Some(Value::Obj(members));
                        }
                        _ => return None,
                    }
                }
            }
            b'"' => self.string().map(Value::Str),
            _ if self.word(b"true") => Some(Value::Bool(true)),
            _ if self.word(b"false") => Some(Value::Bool(false)),
            _ if self.word(b"null") => Some(Value::Null),
            _ => {
                let len = self.s[self.p..].iter().take_while(|c| matches!(c, b'0'..=b'9' | b'-' | b'+' | b'.' | b'e' | b'E')).count();
                let text = std::str::from_utf8(&self.s[self.p..self.p + len]).ok()?;
                let num = text.parse().ok()?;
                self.p += len;
                Some(Value::Num(num))
            }
        }
    }
}

fn json_parse(text: &str) -> Option<Value> {
    let mut ps = Parser { s: text.as_bytes(), p: 0 };
    let v = ps.value(0)?;
    ps.skip_space();
    (ps.p == ps.s.len()).then_some(v)
}

// ---------- walking ----------

#[derive(Default)]
struct Stats {
    objects: i64,
    arrays: i64,
    strings: i64,
    numbers: i64,
    trues: i64,
    nulls: i64,
    string_bytes: usize,
}

fn walk(v: &Value, s: &mut Stats) {
    match v {
        Value::Null => s.nulls += 1,
        Value::Bool(b) => s.trues += *b as i64,
        Value::Num(_) => s.numbers += 1,
        Value::Str(t) => {
            s.strings += 1;
            s.string_bytes += t.len();
        }
        Value::Arr(items) => {
            s.arrays += 1;
            items.iter().for_each(|item| walk(item, s));
        }
        Value::Obj(members) => {
            s.objects += 1;
            members.iter().for_each(|(_, item)| walk(item, s));
        }
    }
}

fn main() {
    let n: i64 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(400000);
    let mut rng = Rng(88172645463325252);
    let mut text = String::from("[");
    for i in 0..n {
        if i > 0 {
            text.push_str(",\n");
        }
        put_object(&mut text, &mut rng, i);
    }
    text.push_str("]\n");
    let Some(doc) = json_parse(&text) else {
        eprintln!("not JSON");
        std::process::exit(1);
    };
    let mut s = Stats::default();
    walk(&doc, &mut s);
    let (mut ids, mut cents) = (0i64, 0i64);
    if let Value::Arr(items) = &doc {
        for item in items {
            if let Some(Value::Num(id)) = item.get("id") {
                ids += *id as i64;
            }
            if let Some(Value::Num(score)) = item.get("score") {
                cents += (score * 100.0 + 0.5) as i64;
            }
        }
    }
    println!("{} bytes: {} objects, {} arrays, {} strings, {} numbers", text.len(), s.objects, s.arrays, s.strings, s.numbers);
    println!("{} string bytes, {} true, {} null", s.string_bytes, s.trues, s.nulls);
    println!("{ids} {cents}");
}
