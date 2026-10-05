// Source text to tokens: identifiers (keywords included), numbers, chars, strings, @builtins and
// punctuation, longest match first. Whitespace and comments are skipped; each token records whether
// it touches the previous one (`glued`), which the parser needs to read `>>` as two closing `>`.
use crate::diag::{Res, Span, err};

/// a token's kind and value. Int holds the digits' value only (`-` is a separate Punct), Str the bytes after
/// escapes, Char a code point, Punct one of PUNCTS
#[derive(Clone, Debug, PartialEq)]
pub enum Tok {
    Ident(String),
    Int(u128),
    Float(f64),
    Char(u32),
    Str(Vec<u8>),
    Builtin(String), // @name
    Punct(&'static str),
    Eof,
}

#[derive(Clone, Debug)]
pub struct Token {
    pub tok: Tok,
    pub span: Span,
    pub glued: bool, // no whitespace between this token and the previous one
}

// longest first. ">>" and ">>=" are left out on purpose: the parser joins glued '>' tokens,
// so `box<box<T>>` closes two generic lists
const PUNCTS: &[&str] = &[
    "...", "..=", "<<=", "+%=", "-%=", "*%=", "::", "->", "=>", "..", "==", "!=", "<=", ">=", "&&", "||", "<<",
    "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "++", "--", "+%", "-%", "*%", "??", "(", ")", "{", "}", "[",
    "]", "<", ">", ",", ";", ":", ".", "=", "+", "-", "*", "/", "%", "&", "|", "^", "~", "!", "?", "$",
];

/// tokenizes a whole file; the result always ends with Eof. Fails at the first bad character or literal
pub fn lex(src: &str, file: u32) -> Res<Vec<Token>> {
    let b = src.as_bytes();
    let mut i = 0;
    let mut out: Vec<Token> = Vec::new();
    let mut glued = false;
    let sp = |lo: usize, hi: usize| Span { file, lo: lo as u32, hi: hi as u32 };
    while i < b.len() {
        let c = b[i];
        if c.is_ascii_whitespace() {
            i += 1;
            glued = false;
            continue;
        }
        if c == b'/' && b.get(i + 1) == Some(&b'/') {
            while i < b.len() && b[i] != b'\n' {
                i += 1;
            }
            glued = false;
            continue;
        }
        if c == b'/' && b.get(i + 1) == Some(&b'*') {
            let start = i;
            i += 2;
            while i + 1 < b.len() && !(b[i] == b'*' && b[i + 1] == b'/') {
                i += 1;
            }
            if i + 1 >= b.len() {
                return err(sp(start, start + 2), "unterminated block comment");
            }
            i += 2;
            glued = false;
            continue;
        }
        // one token; its kind is decided by the first byte
        let start = i;
        let tok = if c == b'r' && b.get(i + 1) == Some(&b'"') {
            // r"..." and r"""...""": raw, backslashes stay as written
            i += 1;
            string(b, &mut i, start, true, &sp)?
        } else if c.is_ascii_alphabetic() || c == b'_' {
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                i += 1;
            }
            Tok::Ident(src[start..i].to_string())
        } else if c == b'@' {
            i += 1;
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                i += 1;
            }
            if i == start + 1 {
                return err(sp(start, i), "expected a builtin name after @");
            }
            Tok::Builtin(src[start + 1..i].to_string())
        } else if c.is_ascii_digit() {
            // after '.', only integers (t.0.1 is two tuple indexes, not a float)
            let after_dot = matches!(out.last(), Some(Token { tok: Tok::Punct("."), .. }));
            lex_number(b, &mut i, after_dot).map_err(|m| crate::diag::Diag::new(sp(start, i), m))?
        } else if c == b'"' {
            string(b, &mut i, start, false, &sp)?
        } else if c == b'\'' {
            i += 1;
            let v: u32 = match b.get(i) {
                Some(b'\\') => {
                    let bytes = escape(b, &mut i).map_err(|m| crate::diag::Diag::new(sp(i, i + 1), m))?;
                    std::str::from_utf8(&bytes).ok().and_then(|s| s.chars().next()).map(|c| c as u32).unwrap_or(bytes[0] as u32)
                }
                Some(_) => {
                    let ch = src[i..].chars().next().unwrap();
                    i += ch.len_utf8();
                    ch as u32
                }
                None => return err(sp(start, i), "unterminated char literal"),
            };
            if b.get(i) != Some(&b'\'') {
                return err(sp(start, i), "expected ' to close char literal");
            }
            i += 1;
            Tok::Char(v)
        } else {
            let rest = &src[i..];
            match PUNCTS.iter().find(|p| rest.starts_with(**p)) {
                Some(p) => {
                    i += p.len();
                    Tok::Punct(p)
                }
                None => return err(sp(i, i + 1), format!("unexpected character '{}'", rest.chars().next().unwrap())),
            }
        };
        out.push(Token { tok, span: sp(start, i), glued });
        glued = true;
    }
    out.push(Token { tok: Tok::Eof, span: sp(b.len(), b.len()), glued: false });
    Ok(out)
}

/// reads an int or float literal at b[*i] and moves *i past it. Takes 0x/0b/0o prefixes and drops `_`;
/// with int_only (right after a `.`) it never reads a fraction or exponent
fn lex_number(b: &[u8], i: &mut usize, int_only: bool) -> Result<Tok, String> {
    let start = *i;
    let radix = if b[*i] == b'0' && matches!(b.get(*i + 1), Some(b'x' | b'b' | b'o')) {
        let r = match b[*i + 1] {
            b'x' => 16,
            b'b' => 2,
            _ => 8,
        };
        *i += 2;
        r
    } else {
        10
    };
    let digits_start = *i;
    while *i < b.len() && (b[*i].is_ascii_alphanumeric() || b[*i] == b'_') {
        // a decimal literal stops at `e` so the exponent is read below; other letters are kept and fail the
        // digit parse
        if radix == 10 && (b[*i] == b'e' || b[*i] == b'E') {
            break;
        }
        *i += 1;
    }
    let mut is_float = false;
    if radix == 10 && !int_only {
        if b.get(*i) == Some(&b'.') && b.get(*i + 1).is_some_and(|c| c.is_ascii_digit()) {
            is_float = true;
            *i += 1;
            while *i < b.len() && (b[*i].is_ascii_digit() || b[*i] == b'_') {
                *i += 1;
            }
        }
        if matches!(b.get(*i), Some(b'e' | b'E')) {
            let mut j = *i + 1;
            if matches!(b.get(j), Some(b'+' | b'-')) {
                j += 1;
            }
            if b.get(j).is_some_and(|c| c.is_ascii_digit()) {
                is_float = true;
                *i = j;
                while *i < b.len() && b[*i].is_ascii_digit() {
                    *i += 1;
                }
            }
        }
    }
    let text: String = std::str::from_utf8(&b[digits_start..*i]).unwrap().chars().filter(|c| *c != '_').collect();
    if is_float {
        let full: String = std::str::from_utf8(&b[start..*i]).unwrap().chars().filter(|c| *c != '_').collect();
        return full.parse::<f64>().map(Tok::Float).map_err(|e| e.to_string());
    }
    u128::from_str_radix(&text, radix).map(Tok::Int).map_err(|_| format!("bad number literal '{text}'"))
}

/// a string literal from its opening quote at b[*i] (the token starts at `start`, before an r): "..." on
/// one line, or """ multi-line. A raw one keeps its backslashes
fn string(b: &[u8], i: &mut usize, start: usize, raw: bool, sp: &impl Fn(usize, usize) -> Span) -> Res<Tok> {
    if b[*i..].starts_with(b"\"\"\"") {
        return multiline(b, i, start, raw, sp).map(Tok::Str);
    }
    *i += 1;
    let mut s = Vec::new();
    loop {
        match b.get(*i) {
            None | Some(b'\n') => return err(sp(start, *i), "unterminated string"),
            Some(b'"') => {
                *i += 1;
                return Ok(Tok::Str(s));
            }
            Some(b'\\') if !raw => s.extend(escape(b, i).map_err(|m| crate::diag::Diag::new(sp(*i, *i + 1), m))?),
            Some(&ch) => {
                s.push(ch);
                *i += 1;
            }
        }
    }
}

/// a """ string: the lines after the opening quotes up to a closing """ with only whitespace before it
/// on its line. That whitespace comes off the start of every line (a line of only whitespace may have
/// less), and the lines are joined with \n; a \r\n line ending counts as \n
fn multiline(b: &[u8], i: &mut usize, start: usize, raw: bool, sp: &impl Fn(usize, usize) -> Span) -> Res<Vec<u8>> {
    *i += 3;
    let open = *i;
    while matches!(b.get(*i), Some(b' ' | b'\t' | b'\r')) {
        *i += 1;
    }
    match b.get(*i) {
        Some(b'\n') => *i += 1,
        None => return err(sp(start, open), "unterminated multi-line string"),
        _ => return err(sp(start, *i + 1), "a multi-line string starts on the line after its \"\"\""),
    }
    // each line: where it starts and ends in the source, and its bytes after escapes
    let mut lines: Vec<(usize, usize, Vec<u8>)> = Vec::new();
    loop {
        let at = *i;
        let mut text = Vec::new();
        let end = loop {
            match b.get(*i) {
                None => return err(sp(start, open), "unterminated multi-line string"),
                Some(b'\n') => break *i,
                Some(b'\r') if b.get(*i + 1) == Some(&b'\n') => {
                    *i += 1;
                    break *i - 1;
                }
                Some(b'"') if b[*i..].starts_with(b"\"\"\"") => {
                    let indent = &b[at..*i];
                    if !indent.iter().all(|c| matches!(c, b' ' | b'\t')) {
                        return err(sp(*i, *i + 3), "the closing \"\"\" goes on a line of its own");
                    }
                    *i += 3;
                    let mut out = Vec::new();
                    for (n, (from, to, text)) in lines.iter().enumerate() {
                        if n > 0 {
                            out.push(b'\n');
                        }
                        if b[*from..*to].starts_with(indent) {
                            out.extend_from_slice(&text[indent.len()..]);
                        } else if !b[*from..*to].iter().all(|c| matches!(c, b' ' | b'\t')) {
                            return err(sp(*from, *to), "this line is indented less than the closing \"\"\"");
                        }
                    }
                    return Ok(out);
                }
                Some(b'\\') if !raw => text.extend(escape(b, i).map_err(|m| crate::diag::Diag::new(sp(*i, *i + 1), m))?),
                Some(&ch) => {
                    text.push(ch);
                    *i += 1;
                }
            }
        };
        *i += 1;
        lines.push((at, end, text));
    }
}

/// decodes the backslash escape at b[*i] and moves *i past it; returns its bytes (`\u{...}` as UTF-8)
fn escape(b: &[u8], i: &mut usize) -> Result<Vec<u8>, String> {
    *i += 1; // backslash
    let c = *b.get(*i).ok_or("unterminated escape")?;
    *i += 1;
    Ok(match c {
        b'n' => vec![b'\n'],
        b't' => vec![b'\t'],
        b'r' => vec![b'\r'],
        b'0' => vec![0],
        b'\\' => vec![b'\\'],
        b'"' => vec![b'"'],
        b'\'' => vec![b'\''],
        b'x' => {
            let h = std::str::from_utf8(b.get(*i..*i + 2).ok_or("bad \\x escape")?).map_err(|_| "bad \\x escape")?;
            *i += 2;
            vec![u8::from_str_radix(h, 16).map_err(|_| "bad \\x escape")?]
        }
        b'u' => {
            if b.get(*i) != Some(&b'{') {
                return Err("expected \\u{...}".into());
            }
            let end = b[*i..].iter().position(|c| *c == b'}').ok_or("unterminated \\u{")? + *i;
            let h = std::str::from_utf8(&b[*i + 1..end]).unwrap();
            *i = end + 1;
            let ch = u32::from_str_radix(h, 16).ok().and_then(char::from_u32).ok_or("bad \\u escape")?;
            ch.to_string().into_bytes()
        }
        _ => return Err(format!("unknown escape \\{}", c as char)),
    })
}
