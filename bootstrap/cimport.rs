// C header import: `use { "stdio.h" } as c;` runs the C preprocessor over the headers and reads
// back what maps to Volt: functions (static inline ones too), structs, enum constants, numeric
// #defines and extern variables, as ordinary items of namespace `c`. The headers are #included in
// the generated C, so calls go through C's own prototypes and structs keep C's layout. A union is a
// struct whose fields share offset 0; a bitfield gets two static inline C functions, S_get_F and
// S_set_F, next to the #include. The parser is tolerant: a declaration it can't read or map (long
// double, va_list...) is skipped, not an error. C pointers can be null: raw T*, a char* is a cstr?,
// a function pointer an optional fn.
use crate::ast::*;
use crate::diag::{err, Res, Span};
use std::collections::HashMap;
use std::path::Path as FsPath;
use std::process::{Command, Stdio};

/// a C token; a string literal keeps no text (it only needs skipping)
#[derive(Clone, Debug, PartialEq)]
enum Tok {
    Id(String),
    Num(String),
    Str,
    Chr(u32),
    P(&'static str),
}

/// C punctuators, longest first so the first match is the whole one
const PUNCT: [&str; 34] = [
    "...", "<<", ">>", "->", "&&", "||", "==", "!=", "<=", ">=", "++", "--", "*", "(", ")", "[", "]", "{", "}", ",", ";", "=", ":", "?", "<", ">",
    "+", "-", "~", "!", "&", "|", "^", "/",
];

/// tokens of preprocessed C; `#` lines are skipped, and any character that isn't a punctuator
/// (`%`, `.`, ...) becomes `%`, the only one of them the evaluator uses
fn lex(src: &str) -> Vec<Tok> {
    let b = src.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        if c.is_ascii_whitespace() {
            i += 1;
        } else if c == b'#' {
            while i < b.len() && b[i] != b'\n' {
                i += 1;
            }
        } else if c.is_ascii_alphabetic() || c == b'_' {
            let s = i;
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                i += 1;
            }
            out.push(Tok::Id(src[s..i].to_string()));
        } else if c.is_ascii_digit() || (c == b'.' && b.get(i + 1).is_some_and(|d| d.is_ascii_digit())) {
            let s = i;
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'.' || b[i] == b'_' || ((b[i] == b'+' || b[i] == b'-') && matches!(b[i - 1], b'e' | b'E' | b'p' | b'P'))) {
                i += 1;
            }
            out.push(Tok::Num(src[s..i].to_string()));
        } else if c == b'"' || c == b'\'' {
            let s = i + 1;
            i += 1;
            while i < b.len() && b[i] != c {
                i += if b[i] == b'\\' { 2 } else { 1 };
            }
            let body = &src[s..i.min(b.len())];
            i += 1;
            out.push(if c == b'"' { Tok::Str } else { Tok::Chr(char_value(body)) });
        } else {
            match PUNCT.iter().find(|p| src[i..].starts_with(**p)) {
                Some(p) => {
                    out.push(Tok::P(p));
                    i += p.len();
                }
                None => {
                    out.push(Tok::P("%"));
                    i += 1;
                }
            }
        }
    }
    out
}

/// the value of a character literal's body (the text between the quotes)
fn char_value(body: &str) -> u32 {
    let b = body.as_bytes();
    match b {
        [b'\\', b'n'] => 10,
        [b'\\', b't'] => 9,
        [b'\\', b'r'] => 13,
        [b'\\', b'0'..=b'7', ..] => u32::from_str_radix(&body[1..], 8).unwrap_or(0),
        [b'\\', b'x', ..] => u32::from_str_radix(&body[2..], 16).unwrap_or(0),
        [b'\\', c] => *c as u32,
        [c, ..] => *c as u32,
        [] => 0,
    }
}

// ---------- constant expressions (enum values, #defines, array lengths) ----------

#[derive(Clone, Copy, Debug)]
enum Num {
    Int(i128, bool, bool), // value, unsigned, long
    Float(f64),
}

/// a C number literal: an int with its u/l suffixes, or a float; None if it isn't one
fn parse_num(s: &str) -> Option<Num> {
    let l = s.to_ascii_lowercase();
    let hex = l.starts_with("0x");
    if l.contains('.') || (!hex && l.contains('e')) || (hex && l.contains('p')) {
        let t = l.trim_end_matches(['f', 'l']);
        return t.parse::<f64>().ok().map(Num::Float);
    }
    let digits = l.trim_end_matches(['u', 'l']);
    let suffix = &l[digits.len()..];
    let (unsigned, long) = (suffix.contains('u'), suffix.contains('l'));
    let v = if hex {
        i128::from_str_radix(&digits[2..], 16).ok()?
    } else if let Some(bin) = digits.strip_prefix("0b") {
        i128::from_str_radix(bin, 2).ok()?
    } else if digits.len() > 1 && digits.starts_with('0') {
        i128::from_str_radix(&digits[1..], 8).ok()?
    } else {
        digits.parse().ok()?
    };
    Some(Num::Int(v, unsigned, long))
}

/// precedence climbing over a constant expression's tokens; env holds the constants known so far
struct Eval<'a> {
    t: &'a [Tok],
    i: usize,
    env: &'a HashMap<String, Num>,
}

impl Eval<'_> {
    fn peek(&self) -> Option<&Tok> {
        self.t.get(self.i)
    }
    /// a binary operator's precedence (higher binds tighter); None if it isn't one
    fn prec(op: &str) -> Option<u8> {
        Some(match op {
            "||" => 1,
            "&&" => 2,
            "|" => 3,
            "^" => 4,
            "&" => 5,
            "==" | "!=" => 6,
            "<" | ">" | "<=" | ">=" => 7,
            "<<" | ">>" => 8,
            "+" | "-" => 9,
            "*" | "/" | "%" => 10,
            _ => return None,
        })
    }
    /// an expression whose operators bind at least as tight as `min`
    fn expr(&mut self, min: u8) -> Option<Num> {
        let mut lhs = self.unary()?;
        while let Some(Tok::P(op)) = self.peek().cloned() {
            let Some(p) = Self::prec(op) else { break };
            if p < min {
                break;
            }
            self.i += 1;
            let rhs = self.expr(p + 1)?;
            lhs = binop(op, lhs, rhs)?;
        }
        Some(lhs)
    }
    fn unary(&mut self) -> Option<Num> {
        let t = self.peek()?.clone();
        self.i += 1;
        match t {
            Tok::Num(s) => parse_num(&s),
            Tok::Chr(c) => Some(Num::Int(c as i128, false, false)),
            Tok::Id(n) => self.env.get(&n).copied(),
            Tok::P("-") => match self.unary()? {
                Num::Int(v, u, l) => Some(Num::Int(-v, u, l)),
                Num::Float(f) => Some(Num::Float(-f)),
            },
            Tok::P("+") => self.unary(),
            Tok::P("~") => match self.unary()? {
                Num::Int(v, u, l) => Some(Num::Int(!v, u, l)),
                _ => None,
            },
            Tok::P("!") => match self.unary()? {
                Num::Int(v, ..) => Some(Num::Int((v == 0) as i128, false, false)),
                _ => None,
            },
            Tok::P("(") => {
                // a cast like (int) or (unsigned long): skip it
                if matches!(self.peek(), Some(Tok::Id(n)) if TYPE_WORDS.contains(&n.as_str())) {
                    while matches!(self.peek(), Some(Tok::Id(_))) {
                        self.i += 1;
                    }
                    if self.peek() != Some(&Tok::P(")")) {
                        return None;
                    }
                    self.i += 1;
                    return self.unary();
                }
                let v = self.expr(0)?;
                if self.peek() != Some(&Tok::P(")")) {
                    return None;
                }
                self.i += 1;
                Some(v)
            }
            _ => None,
        }
    }
}

/// type names that can start a cast in a constant expression
const TYPE_WORDS: [&str; 13] = ["int", "unsigned", "signed", "long", "short", "char", "float", "double", "size_t", "int32_t", "uint32_t", "int64_t", "uint64_t"];

/// a C operator on two constants: ints in i128 (None on overflow or division by zero), unsigned or long
/// if either side is; anything with a float as f64 (+ - * / only)
fn binop(op: &str, a: Num, b: Num) -> Option<Num> {
    if let (Num::Int(x, ua, la), Num::Int(y, ub, lb)) = (a, b) {
        let (u, l) = (ua || ub, la || lb);
        let v = match op {
            "+" => x.checked_add(y)?,
            "-" => x.checked_sub(y)?,
            "*" => x.checked_mul(y)?,
            "/" => x.checked_div(y)?,
            "%" => x.checked_rem(y)?,
            "<<" => x.checked_shl(u32::try_from(y).ok()?)?,
            ">>" => x.checked_shr(u32::try_from(y).ok()?)?,
            "&" => x & y,
            "|" => x | y,
            "^" => x ^ y,
            "&&" => (x != 0 && y != 0) as i128,
            "||" => (x != 0 || y != 0) as i128,
            "==" => (x == y) as i128,
            "!=" => (x != y) as i128,
            "<" => (x < y) as i128,
            ">" => (x > y) as i128,
            "<=" => (x <= y) as i128,
            ">=" => (x >= y) as i128,
            _ => return None,
        };
        return Some(Num::Int(v, u, l));
    }
    let f = |n: Num| match n {
        Num::Int(v, ..) => v as f64,
        Num::Float(f) => f,
    };
    let (x, y) = (f(a), f(b));
    Some(Num::Float(match op {
        "+" => x + y,
        "-" => x - y,
        "*" => x * y,
        "/" => x / y,
        _ => return None,
    }))
}

/// value of a C constant expression (numbers, enum constants, operators); None if it isn't one
fn const_eval(t: &[Tok], env: &HashMap<String, Num>) -> Option<Num> {
    let mut e = Eval { t, i: 0, env };
    let v = e.expr(0)?;
    (e.i == t.len()).then_some(v)
}

// ---------- declarations ----------

/// a C type as the declaration parser reads it
#[derive(Clone, Debug)]
enum CT {
    Void,
    Bool,
    Char,
    Prim(&'static str), // a Volt primitive name
    Named(String),      // a typedef name
    Struct(String),     // by tag (anonymous ones get a made-up tag)
    Ptr(Box<CT>),
    Array(Box<CT>, Option<u64>),
    Func(Vec<CT>, Box<CT>, bool),
    Bad, // long double, va_list...: can't be used by value
}

/// a C struct or union read from the headers
struct CStruct {
    tag: String,
    fields: Option<Vec<(String, CT)>>, // None: only declared
    union: bool,
    /// its bitfields: name, the C text of its type (for their accessors)
    bits: Vec<(String, String)>,
}

/// a struct's fields and bitfields, as fields() reads them
type Fields = (Vec<(String, CT)>, Vec<(String, String)>);

/// everything read from the preprocessed headers
#[derive(Default)]
struct Decls {
    typedefs: HashMap<String, CT>,
    structs: Vec<CStruct>,
    typedef_of: HashMap<String, String>, // struct tag -> first typedef naming it
    anon_in: HashMap<String, (String, String)>, // anonymous tag -> the struct tag and named field it types
    /// enum constants and numeric #defines, in order
    consts: Vec<(String, Num)>,
    /// every constant by name, for evaluating later ones
    env: HashMap<String, Num>,
    /// name, params (name, type), return type, variadic
    fns: Vec<(String, Vec<(Option<String>, CT)>, CT, bool)>,
    vars: Vec<(String, CT)>,
    /// counter for made-up tags of anonymous structs
    anon: u32,
    last_params: Vec<Option<String>>, // names in the param list read last (the declared fn's own)
}

impl Decls {
    /// records a struct tag; a later definition fills in the fields of an earlier declaration
    fn define_struct(&mut self, tag: &str, fields: Option<Fields>, union: bool) {
        let (fields, bits) = match fields {
            Some((f, b)) => (Some(f), b),
            None => (None, Vec::new()),
        };
        match self.structs.iter_mut().find(|s| s.tag == tag) {
            Some(s) => {
                if fields.is_some() {
                    s.fields = fields;
                    s.bits = bits;
                    s.union = union;
                }
            }
            None => self.structs.push(CStruct { tag: tag.to_string(), fields, union, bits }),
        }
    }
}

/// a parser over one declaration's tokens, adding what it reads to `d`
struct DeclParser<'a> {
    t: &'a [Tok],
    i: usize,
    d: &'a mut Decls,
}

/// None: the declaration can't be read (it is skipped)
type PRes<T> = Option<T>;

impl DeclParser<'_> {
    fn peek(&self) -> Option<&Tok> {
        self.t.get(self.i)
    }
    fn is(&self, p: &str) -> bool {
        matches!(self.peek(), Some(Tok::P(x)) if *x == p)
    }
    fn eat(&mut self, p: &str) -> bool {
        if self.is(p) {
            self.i += 1;
            true
        } else {
            false
        }
    }
    fn expect(&mut self, p: &str) -> PRes<()> {
        self.eat(p).then_some(())
    }
    /// skip a balanced (...) / [...] / {...} starting at the current token
    fn skip_group(&mut self) -> PRes<()> {
        let mut depth = 0i32;
        loop {
            match self.peek()? {
                Tok::P("(" | "[" | "{") => depth += 1,
                Tok::P(")" | "]" | "}") => depth -= 1,
                _ => {}
            }
            self.i += 1;
            if depth == 0 {
                return Some(());
            }
        }
    }
    /// __attribute__((...)), __asm__("..."), and other noise that carries no type information
    fn skip_noise(&mut self) -> PRes<bool> {
        let Some(Tok::Id(n)) = self.peek() else { return Some(false) };
        match n.as_str() {
            "__attribute__" | "__attribute" | "__asm__" | "__asm" | "asm" | "__declspec" | "_Alignas" | "__typeof__" => {
                self.i += 1;
                if self.is("(") {
                    self.skip_group()?;
                }
                Some(true)
            }
            "const" | "__const" | "volatile" | "__volatile__" | "restrict" | "__restrict" | "__restrict__" | "inline" | "__inline" | "__inline__" | "extern"
            | "register" | "_Noreturn" | "__extension__" | "auto" | "_Nonnull" | "_Nullable" | "_Null_unspecified" => {
                self.i += 1;
                Some(true)
            }
            _ => Some(false),
        }
    }

    /// declaration specifiers -> base type; sets `stat` for static/thread-local storage
    fn specs(&mut self, stat: &mut bool) -> PRes<CT> {
        let (mut signed, mut unsigned, mut short, mut longs, mut int) = (false, false, false, 0, false);
        let mut base: Option<CT> = None;
        loop {
            if self.skip_noise()? {
                continue;
            }
            let Some(Tok::Id(n)) = self.peek().cloned() else { break };
            let seen = base.is_some() || signed || unsigned || short || longs > 0 || int;
            match n.as_str() {
                "static" | "_Thread_local" | "__thread" => *stat = true,
                "signed" | "__signed__" | "__signed" => signed = true,
                "unsigned" => unsigned = true,
                "short" => short = true,
                "long" => longs += 1,
                "int" => int = true,
                "char" => base = Some(CT::Char),
                "void" => base = Some(CT::Void),
                "_Bool" | "bool" => base = Some(CT::Bool),
                "float" | "_Float32" => base = Some(CT::Prim("f32")),
                "double" | "_Float64" => base = Some(CT::Prim("f64")),
                "_Float128" | "__float128" => base = Some(CT::Prim("f128")),
                "__int128" | "__int128_t" => base = Some(CT::Prim("i128")),
                "__uint128_t" => base = Some(CT::Prim("u128")),
                "_Complex" | "__builtin_va_list" | "_Float32x" | "_Float64x" | "_Float128x" | "_Float16" => base = Some(CT::Bad),
                "struct" | "union" => {
                    self.i += 1;
                    while self.skip_noise()? {}
                    let tag = match self.peek() {
                        Some(Tok::Id(t)) => {
                            let t = t.clone();
                            self.i += 1;
                            Some(t)
                        }
                        _ => None,
                    };
                    while self.skip_noise()? {}
                    let union = n == "union";
                    let tag = tag.unwrap_or_else(|| {
                        self.d.anon += 1;
                        format!("#anon{}", self.d.anon)
                    });
                    if self.is("{") {
                        let fields = self.fields(&tag);
                        self.d.define_struct(&tag, fields, union);
                    } else {
                        self.d.define_struct(&tag, None, union);
                    }
                    base = Some(CT::Struct(tag));
                    continue;
                }
                "enum" => {
                    self.i += 1;
                    while self.skip_noise()? {}
                    if matches!(self.peek(), Some(Tok::Id(_))) {
                        self.i += 1;
                    }
                    if self.is("{") {
                        self.enumerators()?;
                    }
                    base = Some(CT::Prim("i32"));
                    continue;
                }
                _ if !seen && (self.d.typedefs.contains_key(&n) || KNOWN_TYPEDEFS.iter().any(|(k, _)| *k == n)) => base = Some(CT::Named(n.clone())),
                _ => break,
            }
            self.i += 1;
        }
        if let Some(b) = base {
            return Some(match (b, unsigned, signed) {
                (CT::Char, true, _) => CT::Prim("u8"),
                (CT::Char, _, true) => CT::Prim("i8"),
                (CT::Prim("f64"), ..) if longs > 0 => CT::Bad, // long double
                (b, ..) => b,
            });
        }
        if !(signed || unsigned || short || longs > 0 || int) {
            return None;
        }
        let bits = if short { 16 } else if longs > 0 { 64 } else { 32 };
        Some(CT::Prim(match (unsigned, bits) {
            (false, 16) => "i16",
            (true, 16) => "u16",
            (false, 32) => "i32",
            (true, 32) => "u32",
            (false, _) => "i64",
            (true, _) => "u64",
        }))
    }

    /// `{ int a; char b[4]; ... }` of struct or union `tag`: fields that can't be read are dropped,
    /// bitfields are kept apart (for their accessors), and an anonymous struct or union member's
    /// fields are the outer one's, as in C
    fn fields(&mut self, tag: &str) -> Option<Fields> {
        let open = self.i;
        self.skip_group()?;
        let end = self.i - 1;
        let (mut out, mut bits) = (Vec::new(), Vec::new());
        let mut i = open + 1;
        while i < end {
            let stop = decl_end(self.t, i).min(end);
            let mut sub = DeclParser { t: &self.t[i..stop], i: 0, d: self.d };
            let mut stat = false;
            if let Some(base) = sub.specs(&mut stat) {
                let spec_end = sub.i;
                loop {
                    let Some((name, ty)) = sub.declarator(base.clone()) else { break };
                    let bitfield = sub.eat(":");
                    if bitfield {
                        while sub.peek().is_some() && !sub.is(",") {
                            sub.i += 1;
                        }
                    }
                    let anon = match &ty {
                        CT::Struct(t) if t.starts_with('#') => Some(t.clone()),
                        _ => None,
                    };
                    match (name, bitfield, anon) {
                        (Some(n), true, _) => {
                            if let Some(t) = text_of(&sub.t[..spec_end]) {
                                bits.push((n, t));
                            }
                        }
                        (None, false, Some(a)) => {
                            if let Some(s) = sub.d.structs.iter().find(|s| s.tag == a) {
                                out.extend(s.fields.iter().flatten().cloned());
                                bits.extend(s.bits.iter().cloned());
                            }
                        }
                        (Some(n), false, anon) => {
                            if let Some(a) = anon {
                                sub.d.anon_in.insert(a, (tag.to_string(), n.clone()));
                            }
                            out.push((n, ty));
                        }
                        _ => {}
                    }
                    if !sub.eat(",") {
                        break;
                    }
                }
            }
            i = stop + 1;
        }
        Some((out, bits))
    }

    /// `{ A, B = 5, ... }`: each constant goes into consts and env
    fn enumerators(&mut self) -> PRes<()> {
        self.expect("{")?;
        let mut next = Num::Int(0, false, false);
        while !self.eat("}") {
            let Some(Tok::Id(name)) = self.peek().cloned() else { return None };
            self.i += 1;
            while self.skip_noise()? {}
            let mut value = Some(next);
            if self.eat("=") {
                let s = self.i;
                let mut depth = 0;
                while let Some(t) = self.peek() {
                    match t {
                        Tok::P("(") => depth += 1,
                        Tok::P(")") => depth -= 1,
                        Tok::P("," | "}") if depth == 0 => break,
                        _ => {}
                    }
                    self.i += 1;
                }
                value = const_eval(&self.t[s..self.i], &self.d.env);
            }
            if let Some(v) = value {
                self.d.env.insert(name.clone(), v);
                self.d.consts.push((name, v));
                next = binop("+", v, Num::Int(1, false, false))?;
            }
            self.eat(",");
        }
        Some(())
    }

    /// pointers, a name or a (nested declarator), then [N] / (params) suffixes
    fn declarator(&mut self, base: CT) -> PRes<(Option<String>, CT)> {
        let mut ty = base;
        loop {
            if self.eat("*") {
                ty = CT::Ptr(Box::new(ty));
            } else if !self.skip_noise()? {
                break;
            }
        }
        // `(*name)(...)`: a nested declarator, which applies after the suffixes that follow it
        let nested = self.is("(") && matches!(self.t.get(self.i + 1), Some(Tok::P("*" | "(")) | Some(Tok::Id(_))) && !self.starts_params();
        if nested {
            let open = self.i;
            self.skip_group()?;
            let close = self.i;
            let outer = self.suffixes(ty)?;
            let after = self.i;
            let mut inner = DeclParser { t: &self.t[open + 1..close - 1], i: 0, d: self.d };
            let r = inner.declarator(outer)?;
            if inner.peek().is_some() {
                return None;
            }
            self.i = after;
            return Some(r);
        }
        let name = match self.peek() {
            Some(Tok::Id(n)) => {
                let n = n.clone();
                self.i += 1;
                Some(n)
            }
            _ => None,
        };
        while self.skip_noise()? {}
        Some((name, self.suffixes(ty)?))
    }

    /// does the `(` here start a parameter list (rather than a nested declarator)?
    fn starts_params(&self) -> bool {
        match self.t.get(self.i + 1) {
            Some(Tok::P(")")) | Some(Tok::P("...")) => true,
            Some(Tok::Id(n)) => {
                self.d.typedefs.contains_key(n)
                    || KNOWN_TYPEDEFS.iter().any(|(k, _)| k == n)
                    || matches!(
                        n.as_str(),
                        "void" | "char" | "short" | "int" | "long" | "float" | "double" | "signed" | "unsigned" | "_Bool" | "struct" | "union" | "enum" | "const" | "volatile"
                            | "__const" | "__extension__" | "__attribute__" | "__builtin_va_list" | "__signed__" | "__int128" | "_Float128" | "__restrict"
                    )
            }
            _ => false,
        }
    }

    /// array and parameter-list suffixes; `x[2][3]` is an array of 2 arrays of 3. An array length that
    /// isn't a constant makes the type Bad
    fn suffixes(&mut self, ty: CT) -> PRes<CT> {
        if self.is("[") {
            let s = self.i + 1;
            self.skip_group()?;
            let len_toks = &self.t[s..self.i - 1];
            let len = if len_toks.is_empty() {
                None
            } else {
                match const_eval(len_toks, &self.d.env) {
                    Some(Num::Int(n, ..)) if n >= 0 => Some(n as u64),
                    _ => return Some(CT::Bad),
                }
            };
            let inner = self.suffixes(ty)?;
            return Some(CT::Array(Box::new(inner), len));
        }
        if self.is("(") {
            let (params, variadic) = self.params()?;
            while self.skip_noise()? {}
            let ret = self.suffixes(ty)?;
            return Some(CT::Func(params.into_iter().map(|p| p.1).collect(), Box::new(ret), variadic));
        }
        Some(ty)
    }

    /// a parameter list: each param's name and type, and whether it ends in `...`; the names are kept
    /// in last_params for the fn being declared
    fn params(&mut self) -> PRes<(Vec<(Option<String>, CT)>, bool)> {
        let open = self.i;
        self.skip_group()?;
        let close = self.i - 1;
        let toks = &self.t[open + 1..close];
        if toks.is_empty() || toks == [Tok::Id("void".into())] {
            return Some((Vec::new(), false));
        }
        let mut out = Vec::new();
        let mut variadic = false;
        for part in split_top(toks, ",") {
            if part == [Tok::P("...")] {
                variadic = true;
                continue;
            }
            let mut sub = DeclParser { t: part, i: 0, d: self.d };
            let mut stat = false;
            let base = sub.specs(&mut stat)?;
            let (name, ty) = sub.declarator(base)?;
            if sub.peek().is_some() {
                return None;
            }
            // arrays and functions as params are pointers
            let ty = match ty {
                CT::Array(inner, _) => CT::Ptr(inner),
                f @ CT::Func(..) => CT::Ptr(Box::new(f)),
                t => t,
            };
            out.push((name, ty));
        }
        self.d.last_params = out.iter().map(|p| p.0.clone()).collect();
        Some((out, variadic))
    }

    /// one top-level declaration (the tokens up to its `;`, or up to a function body)
    fn top(&mut self) -> PRes<()> {
        if matches!(self.peek(), Some(Tok::Id(n)) if n == "_Static_assert") {
            return Some(());
        }
        let is_typedef = matches!(self.peek(), Some(Tok::Id(n)) if n == "typedef");
        if is_typedef {
            self.i += 1;
        }
        let mut stat = false;
        let base = self.specs(&mut stat)?;
        loop {
            if self.peek().is_none() || self.is(";") {
                return Some(());
            }
            let (name, ty) = self.declarator(base.clone())?;
            let name = name?;
            if self.eat("=") {
                return Some(()); // initialized variables in headers are static data, not imports
            }
            if is_typedef {
                if let CT::Struct(tag) = &ty {
                    // the struct's Volt name: its first public typedef (FILE, not __FILE)
                    let e = self.d.typedef_of.entry(tag.clone()).or_insert(name.clone());
                    if e.starts_with("__") && !name.starts_with("__") {
                        *e = name.clone();
                    }
                }
                self.d.typedefs.insert(name, ty);
            } else if !name.starts_with("__") {
                match ty {
                    CT::Func(ps, ret, variadic) => {
                        let names = std::mem::take(&mut self.d.last_params);
                        self.d.fns.push((name, ps.into_iter().enumerate().map(|(i, p)| (names.get(i).cloned().flatten(), p)).collect(), *ret, variadic))
                    }
                    t if !stat => self.d.vars.push((name, t)),
                    _ => {}
                }
            }
            if !self.eat(",") {
                return Some(());
            }
        }
    }
}

/// split tokens on top-level `sep`
fn split_top<'a>(t: &'a [Tok], sep: &str) -> Vec<&'a [Tok]> {
    let mut out = Vec::new();
    let (mut depth, mut s) = (0, 0);
    for (i, tok) in t.iter().enumerate() {
        match tok {
            Tok::P("(" | "[" | "{") => depth += 1,
            Tok::P(")" | "]" | "}") => depth -= 1,
            Tok::P(p) if depth == 0 && *p == sep => {
                out.push(&t[s..i]);
                s = i + 1;
            }
            _ => {}
        }
    }
    out.push(&t[s..]);
    out
}

/// end of the declaration starting at `i`: its `;`, or the `{` of a function body
fn decl_end(t: &[Tok], mut i: usize) -> usize {
    let mut depth = 0;
    while i < t.len() {
        match &t[i] {
            Tok::P("(" | "[") => depth += 1,
            Tok::P(")" | "]") => depth -= 1,
            Tok::P("{") if depth == 0 && i > 0 && t[i - 1] == Tok::P(")") => return i,
            Tok::P("{") => depth += 1,
            Tok::P("}") => depth -= 1,
            Tok::P(";") if depth == 0 => return i,
            _ => {}
        }
        i += 1;
    }
    t.len()
}

/// C typedef names with an exact Volt type (checked before following typedef chains)
const KNOWN_TYPEDEFS: [(&str, &str); 14] = [
    ("size_t", "usize"),
    ("ssize_t", "isize"),
    ("ptrdiff_t", "isize"),
    ("intptr_t", "isize"),
    ("uintptr_t", "usize"),
    ("int8_t", "i8"),
    ("int16_t", "i16"),
    ("int32_t", "i32"),
    ("int64_t", "i64"),
    ("uint8_t", "u8"),
    ("uint16_t", "u16"),
    ("uint32_t", "u32"),
    ("uint64_t", "u64"),
    ("bool", "bool"),
];

// ---------- to Volt items ----------

/// turns the parsed C declarations into Volt items
struct Mapper<'a> {
    d: &'a Decls,
    names: HashMap<String, String>, // struct tag -> Volt name
    span: Span,
}

impl Mapper<'_> {
    fn path(&self, name: &str) -> Type {
        Type { kind: TypeKind::Path(Path::single(name, self.span)), span: self.span }
    }
    fn wrap(&self, kind: TypeKind) -> Type {
        Type { kind, span: self.span }
    }
    /// follows typedef names (not the known ones) to what they stand for; None at an unknown name or
    /// past 32 steps
    fn resolve<'b>(&'b self, t: &'b CT, depth: u32) -> Option<&'b CT> {
        match t {
            CT::Named(n) if !KNOWN_TYPEDEFS.iter().any(|(k, _)| k == n) => {
                if depth > 32 {
                    return None;
                }
                self.resolve(self.d.typedefs.get(n)?, depth + 1)
            }
            t => Some(t),
        }
    }
    /// a C type as a Volt type; None when it can't be used
    fn ty(&self, t: &CT) -> Option<Type> {
        let t = self.resolve(t, 0)?;
        Some(match t {
            CT::Void => self.path("void"),
            CT::Bool => self.path("bool"),
            CT::Char => self.path("i8"),
            CT::Prim(p) => self.path(p),
            CT::Named(n) => self.path(KNOWN_TYPEDEFS.iter().find(|(k, _)| k == n)?.1),
            CT::Struct(tag) => self.path(self.names.get(tag)?),
            // C pointers may be null: raw T* (a char* is a cstr?, a function pointer an optional fn)
            CT::Ptr(inner) => match self.resolve(inner, 0) {
                Some(CT::Char) => self.wrap(TypeKind::Optional(Box::new(self.path("cstr")))),
                Some(CT::Func(ps, ret, va)) => match self.fn_ty(ps, ret, *va) {
                    Some(f) => self.wrap(TypeKind::Optional(Box::new(f))),
                    None => self.void_ptr(),
                },
                Some(CT::Void) | None => self.void_ptr(),
                Some(other) => match self.ty(other) {
                    Some(t) => self.wrap(TypeKind::Ptr(Box::new(t))),
                    None => self.void_ptr(),
                },
            },
            CT::Array(inner, Some(n)) => {
                let len = Expr { kind: ExprKind::Int(*n as u128), span: self.span };
                self.wrap(TypeKind::Array(Box::new(self.ty(inner)?), Some(Box::new(len))))
            }
            CT::Array(_, None) | CT::Func(..) | CT::Bad => return None,
        })
    }
    fn void_ptr(&self) -> Type {
        self.wrap(TypeKind::Ptr(Box::new(self.path("void"))))
    }
    /// a C function type as an extern "C" Volt fn type; None if a param or the return can't map
    fn fn_ty(&self, ps: &[CT], ret: &CT, va: bool) -> Option<Type> {
        let params = ps.iter().map(|p| self.ty(p)).collect::<Option<Vec<_>>>()?;
        Some(self.wrap(TypeKind::Fn { params, c_varargs: va, ret: Box::new(self.ret(ret)?), extern_c: true }))
    }
    fn ret(&self, t: &CT) -> Option<Type> {
        self.ty(t)
    }
    /// a public item at the import's span
    fn item(&self, kind: ItemKind) -> Item {
        Item { kind, span: self.span, attrs: Vec::new(), vis: Vis::Public, generics: Vec::new() }
    }
}

/// preprocess `headers` (local ones next to `dir`, others from the system) with the C compiler:
/// returns the declarations (-E -P), the macro definitions (-dM) and the #include lines
fn preprocess(headers: &[String], dir: &FsPath, flags: &[String], span: Span) -> Res<(String, String, Vec<String>)> {
    let includes: Vec<String> = headers
        .iter()
        .map(|h| {
            let local = dir.join(h);
            if local.is_file() { format!("#include \"{}\"", local.canonicalize().unwrap_or(local).display()) } else { format!("#include <{h}>") }
        })
        .collect();
    // the includes go in through stdin: no temp file to race on
    let src = includes.join("\n") + "\n";
    let run = |args: &[&str]| -> Res<String> {
        use std::io::Write;
        let (mut cmd, cc) = c_compiler();
        let child = cmd.args(flags).args(args).args(["-x", "c", "-"]).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn();
        let mut child = match child {
            Ok(c) => c,
            Err(e) => return err(span, format!("can't run the C compiler '{cc}' to read the headers: {e}")),
        };
        let _ = child.stdin.take().unwrap().write_all(src.as_bytes());
        let out = match child.wait_with_output() {
            Ok(o) => o,
            Err(e) => return err(span, format!("the C compiler '{cc}' failed: {e}")),
        };
        if !out.status.success() {
            let msg = String::from_utf8_lossy(&out.stderr);
            let first = msg.lines().find(|l| l.contains("error")).and_then(|l| l.split("error: ").last()).unwrap_or("").trim();
            return err(span, format!("the C compiler couldn't read these headers: {first}"));
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    };
    let decls = run(&["-E", "-P", "-std=gnu11"]);
    let macros = run(&["-E", "-dM", "-std=gnu11"]);
    Ok((decls?, macros?, includes))
}

/// what a header import yields: the Volt items, and the #include lines the generated C needs
pub struct Imported {
    pub items: Vec<Item>,
    pub includes: Vec<String>,
}

/// the --cc arguments the preprocessor needs too, to find and read headers: -I, -D, -U (joined to
/// their value or before it) and -isystem, -iquote, -idirafter, -include (and the argument after them)
pub fn preprocessor_flags(cc_args: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    let mut it = cc_args.iter();
    while let Some(a) = it.next() {
        if ["-I", "-D", "-U", "-isystem", "-iquote", "-idirafter", "-include"].contains(&a.as_str()) {
            out.push(a.clone());
            out.extend(it.next().cloned());
        } else if a.len() > 2 && (a.starts_with("-I") || a.starts_with("-D") || a.starts_with("-U")) {
            out.push(a.clone());
        }
    }
    out
}

/// the C compiler as a command: $CC split at whitespace (CC="ccache gcc"), else cc; with $CC's text
/// for messages. ponytail: no quoting, so a compiler path with spaces needs a wrapper script
pub fn c_compiler() -> (Command, String) {
    let text = std::env::var("CC").ok().filter(|s| !s.trim().is_empty()).unwrap_or_else(|| "cc".into());
    let mut words = text.split_whitespace();
    let mut cmd = Command::new(words.next().unwrap());
    cmd.args(words);
    (cmd, text)
}

/// tokens as C text (a bitfield's type, for its accessors); None if one has no text kept
fn text_of(t: &[Tok]) -> Option<String> {
    let words: Option<Vec<&str>> = t
        .iter()
        .map(|k| match k {
            Tok::Id(n) | Tok::Num(n) => Some(n.as_str()),
            Tok::P(p) => Some(*p),
            _ => None,
        })
        .collect();
    Some(words?.join(" "))
}

/// reads C declarations (preprocessed) into d; function bodies are skipped
fn parse_decls(src: &str, d: &mut Decls) {
    let toks = lex(src);
    let mut i = 0;
    // the declarations, one at a time
    while i < toks.len() {
        let end = decl_end(&toks, i);
        let mut p = DeclParser { t: &toks[i..end], i: 0, d };
        p.top();
        i = end;
        if matches!(toks.get(i), Some(Tok::P("{"))) {
            // a function body: skip it
            let mut depth = 0;
            while i < toks.len() {
                match toks[i] {
                    Tok::P("{") => depth += 1,
                    Tok::P("}") => depth -= 1,
                    _ => {}
                }
                i += 1;
                if depth == 0 {
                    break;
                }
            }
        } else {
            i += 1;
        }
    }
}

/// reads `headers` into Volt items: structs, fns, extern variables and constants (see the top of the file)
pub fn import(headers: &[String], dir: &FsPath, flags: &[String], span: Span) -> Res<Imported> {
    let (src, macros, mut includes) = preprocess(headers, dir, flags, span)?;
    let mut d = Decls::default();
    parse_decls(&src, &mut d);
    // numeric object-like #defines (EOF, SEEK_SET, RAND_MAX, M_PI...). They may use macros defined
    // after them (INT_MAX is __INT_MAX__), so repeat until nothing new resolves; _names stay hidden
    let defs: Vec<(&str, Vec<Tok>)> = macros
        .lines()
        .filter_map(|l| {
            let rest = l.strip_prefix("#define ")?;
            let end = rest.find(|c: char| !(c.is_ascii_alphanumeric() || c == '_')).unwrap_or(rest.len());
            let (name, body) = rest.split_at(end);
            (!body.starts_with('(')).then(|| (name, lex(body)))
        })
        .collect();
    let mut known = std::collections::HashSet::new();
    loop {
        let mut progress = false;
        for (name, body) in &defs {
            if known.contains(name) || d.env.contains_key(*name) {
                continue;
            }
            if let Some(v) = const_eval(body, &d.env) {
                known.insert(name);
                d.env.insert(name.to_string(), v);
                if !name.starts_with('_') {
                    d.consts.push((name.to_string(), v));
                }
                progress = true;
            }
        }
        if !progress {
            break;
        }
    }

    // one Volt struct per C struct: named by its first typedef, else by its tag (also when the
    // typedef is reserved and the tag isn't: __sigval_t, union sigval)
    let mut names = HashMap::new();
    let mut taken = std::collections::HashSet::new();
    let mut c_names = HashMap::new();
    for s in &d.structs {
        let anon = s.tag.starts_with('#');
        let (name, c) = match d.typedef_of.get(&s.tag) {
            Some(t) if !(t.starts_with("__") && !anon && !s.tag.starts_with("__")) => (t.clone(), t.clone()),
            None if anon => continue, // anonymous and never typedef'd: unreachable
            _ => (s.tag.clone(), format!("{} {}", if s.union { "union" } else { "struct" }, s.tag)),
        };
        if name.starts_with("__") || !taken.insert(name.clone()) {
            continue;
        }
        names.insert(s.tag.clone(), name);
        c_names.insert(s.tag.clone(), c);
    }
    // an anonymous struct or union typing a named field is OUTER_FIELD: a typedef of the field's
    // __typeof__ in the generated C (outer ones first, so nested ones can name them)
    loop {
        let mut progress = false;
        for s in &d.structs {
            if names.contains_key(&s.tag) {
                continue;
            }
            let Some((outer, field)) = d.anon_in.get(&s.tag) else { continue };
            let (Some(on), Some(oc)) = (names.get(outer), c_names.get(outer)) else { continue };
            let name = format!("{on}_{field}");
            if !taken.insert(name.clone()) {
                continue;
            }
            includes.push(format!("typedef __typeof__((({oc} *)0)->{field}) {name};"));
            names.insert(s.tag.clone(), name.clone());
            c_names.insert(s.tag.clone(), name.clone());
            d.typedefs.insert(name, CT::Struct(s.tag.clone()));
            progress = true;
        }
        if !progress {
            break;
        }
    }
    // each bitfield's accessors: C reads and writes it, so the backends never need its bits
    let mut protos = String::new();
    for s in &d.structs {
        let (Some(name), Some(c)) = (names.get(&s.tag), c_names.get(&s.tag)) else { continue };
        for (f, ty) in &s.bits {
            let get = format!("static inline {ty} {name}_get_{f}(const {c} *s)");
            let set = format!("static inline void {name}_set_{f}({c} *s, {ty} v)");
            protos.push_str(&format!("{get};\n{set};\n"));
            includes.push(format!("{get} {{ return s->{f}; }}"));
            includes.push(format!("{set} {{ s->{f} = v; }}"));
        }
    }
    parse_decls(&protos, &mut d);
    let m = Mapper { d: &d, names, span };
    let mut items = Vec::new();
    for s in &d.structs {
        let (Some(name), Some(c)) = (m.names.get(&s.tag), c_names.get(&s.tag)) else { continue };
        let fields = s
            .fields
            .iter()
            .flatten()
            .filter_map(|(n, t)| Some(Field { name: n.clone(), ty: m.ty(t)?, default: None, vis: Vis::Public, span }))
            .collect();
        items.push(m.item(ItemKind::Struct(StructDecl { name: name.clone(), spec: None, fields, is_extern: true, is_comptime: false, c_name: Some(c.clone()), c_union: s.union })));
    }
    // functions (the first declaration wins); one with a param or return type Volt can't use is skipped
    let mut seen_fns = std::collections::HashSet::new();
    for (name, ps, ret, va) in &d.fns {
        if !seen_fns.insert(name.clone()) {
            continue;
        }
        let Some(params) = ps
            .iter()
            .enumerate()
            .map(|(i, (n, t))| {
                Some(Param {
                    name: n.clone().unwrap_or_else(|| format!("a{i}")),
                    ty: Some(m.ty(t)?),
                    default: None,
                    mutable: false,
                    is_static: false,
                    comptime: false,
                    span,
                })
            })
            .collect::<Option<Vec<_>>>()
        else {
            continue;
        };
        let Some(ret) = m.ret(ret) else { continue };
        items.push(m.item(ItemKind::Fn(FnDecl {
            name: name.clone(),
            spec: None,
            params,
            c_varargs: *va,
            ret: Some(ret),
            body: None,
            is_async: false,
            is_comptime: false,
            extern_abi: Some(C_HEADER.into()),
            is_export: false,
            is_attach: false,
        })));
    }
    // extern variables, bound to their C names
    for (name, t) in &d.vars {
        let Some(ty) = m.ty(t) else { continue };
        let pat = Pat { kind: PatKind::Bind(name.clone()), span };
        items.push(m.item(ItemKind::Global(Let { mutable: true, comptime: false, is_static: false, pat, ty: Some(ty), init: None, span, c_name: Some(name.clone()) })));
    }
    // constants: an int gets the first of i32, u32, i64, u64 that its suffixes allow and its value fits,
    // a float f64; a negative value is `-literal`
    for (name, v) in &d.consts {
        if name.starts_with("__") {
            continue;
        }
        let (ty, lit) = match *v {
            Num::Int(v, u, l) => {
                let t = if !u && !l && i32::try_from(v).is_ok() {
                    "i32"
                } else if u && !l && u32::try_from(v).is_ok() {
                    "u32"
                } else if !u && i64::try_from(v).is_ok() {
                    "i64"
                } else if u64::try_from(v).is_ok() {
                    "u64"
                } else {
                    continue;
                };
                (t, ExprKind::Int(v.unsigned_abs()))
            }
            Num::Float(f) => ("f64", ExprKind::Float(f.abs())),
        };
        let neg = matches!(*v, Num::Int(x, ..) if x < 0) || matches!(*v, Num::Float(f) if f.is_sign_negative());
        let lit = Expr { kind: lit, span };
        let init = if neg { Expr { kind: ExprKind::Unary(UnOp::Neg, Box::new(lit)), span } } else { lit };
        let pat = Pat { kind: PatKind::Bind(name.clone()), span };
        items.push(m.item(ItemKind::Global(Let { mutable: false, comptime: false, is_static: false, pat, ty: Some(m.path(ty)), init: Some(init), span, c_name: None })));
    }
    Ok(Imported { items, includes })
}

/// the extern_abi of fns declared by an imported header (C's own prototype is used)
pub const C_HEADER: &str = "C header";

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(src: &str) -> Decls {
        let toks = lex(src);
        let mut d = Decls::default();
        let mut i = 0;
        while i < toks.len() {
            let end = decl_end(&toks, i);
            DeclParser { t: &toks[i..end], i: 0, d: &mut d }.top();
            i = end + 1;
        }
        d
    }

    #[test]
    fn declarators() {
        let d = parse(
            "typedef unsigned long size_t; typedef struct _IO_FILE __FILE; typedef struct _IO_FILE FILE; extern FILE *stderr;
             int printf(const char *__restrict __fmt, ...) __attribute__((format(printf, 1, 2)));
             void qsort(void *base, size_t n, size_t size, int (*cmp)(const void *, const void *));
             void (*signal(int sig, void (*handler)(int)))(int);
             enum { A, B = 5, C, D = B << 2 }; struct tm { int tm_sec; char name[8]; int bits : 3; };
             long double ld(void);",
        );
        let names: Vec<&str> = d.fns.iter().map(|f| f.0.as_str()).collect();
        assert_eq!(names, ["printf", "qsort", "signal", "ld"]);
        assert!(matches!(&d.fns[2].2, CT::Ptr(f) if matches!(**f, CT::Func(..))), "signal returns a fn pointer");
        assert!(d.fns[0].3, "printf is variadic");
        assert!(matches!(&d.fns[1].1[3].1, CT::Ptr(f) if matches!(**f, CT::Func(ref ps, _, false) if ps.len() == 2)));
        let c: Vec<(String, i128)> = d.consts.iter().map(|(n, v)| (n.clone(), if let Num::Int(x, ..) = v { *x } else { -1 })).collect();
        assert_eq!(c, [("A".into(), 0), ("B".into(), 5), ("C".into(), 6), ("D".into(), 20)]);
        let tm = d.structs.iter().find(|s| s.tag == "tm").unwrap();
        assert_eq!(tm.fields.iter().flatten().map(|f| f.0.as_str()).collect::<Vec<_>>(), ["tm_sec", "name"], "bitfields are kept apart");
        assert_eq!(tm.bits, [("bits".to_string(), "int".to_string())]);
        assert_eq!(d.vars.len(), 1);
        assert_eq!(d.typedef_of["_IO_FILE"], "FILE", "public typedef names win");
        assert!(matches!(d.fns[3].2, CT::Bad), "long double can't map");
    }
}
