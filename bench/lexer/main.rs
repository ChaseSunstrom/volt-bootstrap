// lexer: generate a large source text in a C-like toy language, tokenize it ten times, and count the
// tokens by kind (plus a checksum of the identifiers' lengths); Rust scans a byte slice by index in a
// Lexer that's an Iterator, and a token is an enum kind plus a slice of its text
use std::fmt::Write;

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Ident,
    Keyword,
    Int,
    Float,
    Str,
    Op,
    Punct,
    Comment,
    Error,
}

const KIND_NAMES: [&str; 9] = ["ident", "keyword", "int", "float", "string", "op", "punct", "comment", "error"];
const KEYWORDS: [&[u8]; 10] = [b"fn", b"let", b"if", b"else", b"while", b"for", b"return", b"struct", b"true", b"false"];

struct Token<'a> {
    kind: Kind,
    text: &'a [u8],
}

struct Lexer<'a> {
    src: &'a [u8],
    p: usize,
}

fn is_alpha(c: u8) -> bool {
    c.is_ascii_alphabetic() || c == b'_'
}

impl<'a> Iterator for Lexer<'a> {
    type Item = Token<'a>;

    fn next(&mut self) -> Option<Token<'a>> {
        let s = self.src;
        let end = s.len();
        let mut p = self.p;
        while p < end && matches!(s[p], b' ' | b'\t' | b'\n' | b'\r') {
            p += 1;
        }
        let start = p;
        if p == end {
            return None;
        }
        let c = s[p];
        p += 1;
        let digit_at = |i: usize| i < end && s[i].is_ascii_digit();
        let kind = if is_alpha(c) {
            while p < end && (is_alpha(s[p]) || s[p].is_ascii_digit()) {
                p += 1;
            }
            if KEYWORDS.contains(&&s[start..p]) { Kind::Keyword } else { Kind::Ident }
        } else if c.is_ascii_digit() {
            let mut k = Kind::Int;
            while digit_at(p) {
                p += 1;
            }
            if p + 1 < end && s[p] == b'.' && s[p + 1].is_ascii_digit() {
                k = Kind::Float;
                p += 1;
                while digit_at(p) {
                    p += 1;
                }
            }
            if p < end && (s[p] == b'e' || s[p] == b'E') {
                let mut q = p + 1;
                if q < end && (s[q] == b'+' || s[q] == b'-') {
                    q += 1;
                }
                if digit_at(q) {
                    k = Kind::Float;
                    p = q;
                    while digit_at(p) {
                        p += 1;
                    }
                }
            }
            k
        } else if c == b'"' {
            while p < end && s[p] != b'"' {
                p += if s[p] == b'\\' && p + 1 < end { 2 } else { 1 };
            }
            if p < end {
                p += 1;
            }
            Kind::Str
        } else if c == b'/' && p < end && s[p] == b'/' {
            while p < end && s[p] != b'\n' {
                p += 1;
            }
            Kind::Comment
        } else if c == b'/' && p < end && s[p] == b'*' {
            p += 1;
            while p + 1 < end && !(s[p] == b'*' && s[p + 1] == b'/') {
                p += 1;
            }
            p = if p + 1 < end { p + 2 } else { end };
            Kind::Comment
        } else {
            match c {
                b'(' | b')' | b'{' | b'}' | b'[' | b']' | b';' | b',' | b'.' => Kind::Punct,
                // ==, !=, <=, >=, +=, *=, /=, %=
                b'=' | b'!' | b'<' | b'>' | b'+' | b'*' | b'/' | b'%' => {
                    if p < end && s[p] == b'=' {
                        p += 1;
                    }
                    Kind::Op
                }
                b'-' => {
                    if p < end && (s[p] == b'=' || s[p] == b'>') {
                        p += 1;
                    }
                    Kind::Op
                }
                // && and ||
                b'&' | b'|' => {
                    if p < end && s[p] == c {
                        p += 1;
                    }
                    Kind::Op
                }
                _ => Kind::Error,
            }
        };
        self.p = p;
        Some(Token { kind, text: &s[start..p] })
    }
}

// ---- the source text ----

const NAMES: [&str; 16] = ["count", "index", "value", "node", "buf", "len", "total", "x", "y", "result", "item", "next_one", "left", "right", "data", "i"];
const WORDS: [&str; 8] = ["the", "loop", "ends", "when", "it", "reaches", "zero", "todo"];
const PIECES: [&str; 8] = ["hello", "world", "\\n", "\\t", "\\\"", "\\\\", " ", "value: "];
const OPS: [&str; 5] = ["+", "-", "*", "/", "%"];
const CMPS: [&str; 6] = ["==", "!=", "<", "<=", ">", ">="];

struct Gen {
    out: String,
    x: u64,
}

impl Gen {
    fn next(&mut self) -> u64 {
        self.x ^= self.x << 13;
        self.x ^= self.x >> 7;
        self.x ^= self.x << 17;
        self.x
    }

    fn put(&mut self, s: &str) {
        self.out.push_str(s);
    }

    fn put_uint(&mut self, v: u64) {
        write!(self.out, "{v}").unwrap();
    }

    fn ident(&mut self) {
        let r = self.next();
        self.put(NAMES[(r % 16) as usize]);
        if (r >> 8) % 4 == 0 {
            self.put("_");
            self.put_uint((r >> 16) % 1000);
        }
    }

    fn int(&mut self) {
        let v = self.next() % 100000;
        self.put_uint(v);
    }

    fn float(&mut self) {
        let r = self.next();
        self.put_uint(r % 1000);
        self.put(".");
        self.put_uint((r >> 20) % 1000);
        if (r >> 40) % 4 == 0 {
            self.put("e");
            self.put_uint((r >> 50) % 20);
        }
    }

    fn string(&mut self) {
        let r = self.next();
        self.put("\"");
        for k in 0..1 + r % 4 {
            self.put(PIECES[((r >> (8 + 3 * k)) % 8) as usize]);
        }
        self.put("\"");
    }

    fn words(&mut self) {
        let r = self.next();
        for k in 0..2 + r % 6 {
            self.put(" ");
            self.put(WORDS[((r >> (8 + 3 * k)) % 8) as usize]);
        }
    }

    fn expr(&mut self) {
        let r = self.next();
        match r % 4 {
            0 => self.ident(),
            1 => self.int(),
            2 => self.float(),
            _ => {
                self.ident();
                self.put(" ");
                self.put(OPS[((r >> 8) % 5) as usize]);
                self.put(" ");
                self.int();
            }
        }
    }

    fn statement(&mut self) {
        let r = self.next();
        let cmp = CMPS[((r >> 8) % 6) as usize];
        match r % 8 {
            0 => {
                self.put("let "); self.ident(); self.put(" = "); self.expr(); self.put(";\n");
            }
            1 => {
                self.put("if ("); self.expr(); self.put(" "); self.put(cmp); self.put(" "); self.expr();
                self.put(") {\n    "); self.ident(); self.put(" = "); self.expr();
                self.put(";\n} else {\n    return "); self.expr(); self.put(";\n}\n");
            }
            2 => {
                self.put("while ("); self.ident(); self.put(" "); self.put(cmp); self.put(" "); self.int();
                self.put(" && "); self.ident(); self.put(" != "); self.int(); self.put(" || !"); self.ident();
                self.put(") {\n    "); self.ident(); self.put(" += "); self.int(); self.put(";\n}\n");
            }
            3 => {
                self.put("return "); self.string(); self.put(";\n");
            }
            4 => {
                self.put("//"); self.words(); self.put("\n");
            }
            5 => {
                self.put("/*"); self.words(); self.put(" */\n");
            }
            6 => {
                self.ident(); self.put("("); self.expr(); self.put(", "); self.expr(); self.put(");\n");
            }
            _ => {
                self.put("fn "); self.ident(); self.put("("); self.ident(); self.put(", "); self.ident(); self.put(") -> ");
                self.ident(); self.put(" {\n    let "); self.ident(); self.put(" = "); self.float(); self.put(" * ");
                self.ident(); self.put(" - "); self.int(); self.put(";\n}\n");
            }
        }
    }
}

fn main() {
    let n: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(32 << 20);
    let mut g = Gen { out: String::new(), x: 88172645463325252 };
    while g.out.len() < n {
        g.statement();
    }
    let src = g.out.as_bytes();
    let mut counts = [0usize; 9];
    let mut total = 0;
    let mut check: u64 = 0;
    for _ in 0..10 {
        for t in (Lexer { src, p: 0 }) {
            counts[t.kind as usize] += 1;
            total += 1;
            if t.kind == Kind::Ident {
                check = check.wrapping_mul(31).wrapping_add(t.text.len() as u64);
            }
        }
    }
    println!("{} bytes, {total} tokens", src.len());
    for (name, count) in KIND_NAMES.iter().zip(counts) {
        println!("{name} {count}");
    }
    println!("identifier checksum {check}");
}
