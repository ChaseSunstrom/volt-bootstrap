// Libraries written in other languages that a package uses ([foreign]): bolt builds each into a
// static library and writes a C header of its C API, which Volt code imports like any C header
// (`use { "NAME.h" } as NAME;`). The header comes from the source: for Rust, the
// #[no_mangle] extern "C" fns and the #[repr(C)] structs and enums; for Zig, the export fns and the
// extern structs and enums. What a header can't say is left out, with a comment.
use std::collections::BTreeSet;
use std::path::Path;

// ---------- tokens ----------

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Id(String),
    Num(String),
    Str(String),
    P(String), // punctuation: one char, or ::, ->
}

/// Rust or Zig source as tokens (comments, char literals and lifetimes dropped)
fn lex(src: &str) -> Vec<Tok> {
    let b = src.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        if c.is_ascii_whitespace() {
            i += 1;
        } else if src[i..].starts_with("//") {
            while i < b.len() && b[i] != b'\n' {
                i += 1;
            }
        } else if src[i..].starts_with("/*") {
            let mut depth = 0;
            while i < b.len() {
                if src[i..].starts_with("/*") {
                    depth += 1;
                    i += 2;
                } else if src[i..].starts_with("*/") {
                    depth -= 1;
                    i += 2;
                    if depth == 0 {
                        break;
                    }
                } else {
                    i += 1;
                }
            }
        } else if c == b'"' {
            let s = i + 1;
            i += 1;
            while i < b.len() && b[i] != b'"' {
                i += if b[i] == b'\\' { 2 } else { 1 };
            }
            out.push(Tok::Str(src[s..i.min(b.len())].to_string()));
            i += 1;
        } else if c == b'\'' {
            // a char literal ('a', '\n') or a lifetime ('a): neither matters here
            if i + 2 < b.len() && (b[i + 2] == b'\'' || b[i + 1] == b'\\') {
                i += 2;
                while i < b.len() && b[i] != b'\'' {
                    i += 1;
                }
                i += 1;
            } else {
                i += 1;
                while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                    i += 1;
                }
            }
        } else if c.is_ascii_alphabetic() || c == b'_' || c == b'@' {
            let s = i;
            i += 1;
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                i += 1;
            }
            out.push(Tok::Id(src[s..i].to_string()));
        } else if c.is_ascii_digit() {
            let s = i;
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                i += 1;
            }
            out.push(Tok::Num(src[s..i].replace('_', "")));
        } else if src[i..].starts_with("::") || src[i..].starts_with("->") {
            out.push(Tok::P(src[i..i + 2].to_string()));
            i += 2;
        } else {
            out.push(Tok::P((c as char).to_string()));
            i += 1;
        }
    }
    out
}

/// a cursor over tokens
struct Cur<'a> {
    t: &'a [Tok],
    i: usize,
}

impl Cur<'_> {
    fn peek(&self) -> Option<&Tok> {
        self.t.get(self.i)
    }
    fn is(&self, p: &str) -> bool {
        matches!(self.peek(), Some(Tok::P(q)) if q == p)
    }
    fn is_id(&self, w: &str) -> bool {
        matches!(self.peek(), Some(Tok::Id(q)) if q == w)
    }
    fn eat(&mut self, p: &str) -> bool {
        let y = self.is(p) || self.is_id(p);
        if y {
            self.i += 1;
        }
        y
    }
    fn id(&mut self) -> Option<String> {
        match self.peek() {
            Some(Tok::Id(s)) => {
                let s = s.clone();
                self.i += 1;
                Some(s)
            }
            _ => None,
        }
    }
    /// past a group that starts at the current token ((, [, {), nested ones included
    fn skip_group(&mut self) {
        let open = match self.peek() {
            Some(Tok::P(p)) => p.clone(),
            _ => return,
        };
        let close = match open.as_str() {
            "(" => ")",
            "[" => "]",
            "{" => "}",
            "<" => ">",
            _ => return,
        };
        let mut depth = 0;
        while let Some(t) = self.peek() {
            if let Tok::P(p) = t {
                if *p == open {
                    depth += 1;
                } else if p == close {
                    depth -= 1;
                    if depth == 0 {
                        self.i += 1;
                        return;
                    }
                } else if open == "<" && p == "-" && matches!(self.t.get(self.i + 1), Some(Tok::P(q)) if q == ">") {
                    self.i += 1; // the > of -> in fn(A) -> B isn't a closing one
                }
            }
            self.i += 1;
        }
    }
    /// the tokens of a group's inside, split at its top-level commas
    fn group_items(&mut self) -> Vec<Vec<Tok>> {
        let start = self.i;
        self.skip_group();
        let inner = &self.t[start + 1..self.i.saturating_sub(1)];
        let mut out = Vec::new();
        let mut cur = Vec::new();
        let mut depth = 0;
        let mut k = 0;
        while k < inner.len() {
            let t = &inner[k];
            if let Tok::P(p) = t {
                match p.as_str() {
                    "(" | "[" | "{" | "<" => depth += 1,
                    ")" | "]" | "}" => depth -= 1,
                    ">" if !(k > 0 && inner[k - 1] == Tok::P("-".into())) => depth -= 1,
                    "," if depth == 0 => {
                        out.push(std::mem::take(&mut cur));
                        k += 1;
                        continue;
                    }
                    _ => {}
                }
            }
            cur.push(t.clone());
            k += 1;
        }
        if !cur.is_empty() {
            out.push(cur);
        }
        out
    }
}

// ---------- the header ----------

/// a C API read from source: declarations in order, and what was left out
#[derive(Default)]
struct Api {
    structs: Vec<(String, Vec<(String, String)>)>, // name, (field, C type)
    enums: Vec<(String, String, Vec<(String, i128)>)>, // name, C tag type, (variant, value)
    fns: Vec<String>,                               // C prototypes
    left_out: Vec<String>,
    known: BTreeSet<String>, // struct and enum names, which C types can name
}

impl Api {
    fn header(&self, name: &str, what: &str) -> String {
        let guard = format!("VOLT_FOREIGN_{}_H", name.to_uppercase());
        let mut out = format!("// {name}: the C API of {what}, written by bolt from its source\n#ifndef {guard}\n#define {guard}\n#include <stdbool.h>\n#include <stddef.h>\n#include <stdint.h>\n");
        for (n, tag, vs) in &self.enums {
            out.push_str(&format!("\ntypedef {tag} {n};\nenum {{\n"));
            for (v, x) in vs {
                out.push_str(&format!("    {n}_{v} = {x},\n"));
            }
            out.push_str("};\n");
        }
        for (n, _) in &self.structs {
            out.push_str(&format!("\ntypedef struct {n} {n};"));
        }
        if !self.structs.is_empty() {
            out.push('\n');
        }
        for (n, fs) in &self.structs {
            out.push_str(&format!("\nstruct {n} {{\n"));
            for (f, t) in fs {
                out.push_str(&format!("    {};\n", declare(t, f)));
            }
            out.push_str("};\n");
        }
        if !self.fns.is_empty() {
            out.push('\n');
        }
        for f in &self.fns {
            out.push_str(f);
            out.push_str(";\n");
        }
        for l in &self.left_out {
            out.push_str(&format!("// left out: {l}\n"));
        }
        out.push_str(&format!("\n#endif // {guard}\n"));
        out
    }
}

/// a C declaration of name with type t ("int32_t x", "int32_t (*f)(int32_t)", "char buf[4]")
fn declare(t: &str, name: &str) -> String {
    if let Some(at) = t.find("(*)") {
        return format!("{}(*{name}){}", &t[..at], &t[at + 3..]);
    }
    if let Some(at) = t.find('[') {
        return format!("{} {name}{}", &t[..at].trim_end(), &t[at..]);
    }
    if t.ends_with('*') {
        format!("{t}{name}")
    } else {
        format!("{t} {name}")
    }
}

fn prim(name: &str) -> Option<&'static str> {
    Some(match name {
        "i8" => "int8_t",
        "i16" => "int16_t",
        "i32" => "int32_t",
        "i64" => "int64_t",
        "u8" => "uint8_t",
        "u16" => "uint16_t",
        "u32" => "uint32_t",
        "u64" => "uint64_t",
        "isize" => "intptr_t",
        "usize" => "size_t",
        "f32" => "float",
        "f64" => "double",
        "bool" => "bool",
        "c_char" => "char",
        "c_schar" => "signed char",
        "c_uchar" => "unsigned char",
        "c_short" => "short",
        "c_ushort" => "unsigned short",
        "c_int" => "int",
        "c_uint" => "unsigned int",
        "c_long" => "long",
        "c_ulong" => "unsigned long",
        "c_longlong" => "long long",
        "c_ulonglong" => "unsigned long long",
        "c_float" => "float",
        "c_double" => "double",
        "c_void" | "anyopaque" => "void",
        _ => return None,
    })
}

/// "T *" for a pointer to C type t (const when it is), keeping function pointers and pointers apart
fn pointer_to(t: &str, constant: bool) -> String {
    let c = if constant && !t.ends_with('*') { "const " } else { "" };
    if t.ends_with('*') {
        format!("{t}*")
    } else {
        format!("{c}{t} *")
    }
}

// ---------- Rust ----------

/// the C type of a Rust type (its tokens), or None
fn rust_ty(api: &Api, t: &[Tok]) -> Option<String> {
    let mut c = Cur { t, i: 0 };
    let ty = rust_ty_at(api, &mut c)?;
    (c.i == t.len()).then_some(ty)
}

fn rust_ty_at(api: &Api, c: &mut Cur) -> Option<String> {
    // paths like std::os::raw::c_int, core::ffi::c_char: the last segment counts
    if c.eat("*") {
        let constant = c.eat("const");
        if !constant {
            c.eat("mut");
        }
        let inner = rust_ty_at(api, c)?;
        return Some(pointer_to(&inner, constant));
    }
    if c.eat("&") {
        let constant = !c.eat("mut");
        let inner = rust_ty_at(api, c)?;
        return Some(pointer_to(&inner, constant));
    }
    if c.is("(") {
        let items = c.group_items();
        return items.is_empty().then(|| "void".to_string());
    }
    if c.eat("extern") || c.eat("unsafe") {
        c.eat("extern");
        if let Some(Tok::Str(_)) = c.peek() {
            c.i += 1;
        }
        return rust_fn_ptr(api, c);
    }
    if c.is_id("fn") {
        return None; // a Rust fn pointer isn't a C one
    }
    let mut name = c.id()?;
    while c.eat("::") {
        name = c.id()?;
    }
    if name == "Option" && c.is("<") {
        // Option<&T>, Option<extern "C" fn>: a nullable pointer
        let args = c.group_items();
        if args.len() != 1 {
            return None;
        }
        let first = args[0].first();
        if !matches!(first, Some(Tok::P(p)) if p == "&") && !matches!(first, Some(Tok::Id(w)) if w == "extern" || w == "unsafe" || w == "NonNull") {
            return None;
        }
        return rust_ty(api, &args[0]);
    }
    if name == "NonNull" && c.is("<") {
        let args = c.group_items();
        let inner = rust_ty(api, args.first()?)?;
        return Some(pointer_to(&inner, false));
    }
    if let Some(p) = prim(&name) {
        return Some(p.to_string());
    }
    api.known.contains(&name).then_some(name)
}

/// extern "C" fn(A, B) -> R, after the extern "C": a C function pointer type, "R (*)(A, B)"
fn rust_fn_ptr(api: &Api, c: &mut Cur) -> Option<String> {
    if !c.eat("fn") || !c.is("(") {
        return None;
    }
    let params = c.group_items();
    let mut ps = Vec::new();
    for p in &params {
        // an argument may be named (x: i32)
        let ty = match p.iter().position(|t| *t == Tok::P(":".into())) {
            Some(k) if k == 1 => &p[2..],
            _ => &p[..],
        };
        ps.push(rust_ty(api, ty)?);
    }
    let ret = if c.eat("->") { rust_ty_at(api, c)? } else { "void".into() };
    let ps = if ps.is_empty() { "void".to_string() } else { ps.join(", ") };
    Some(format!("{ret} (*)({ps})"))
}

/// the C API of a Rust crate's sources (each file's text)
fn rust_api(files: &[String]) -> Api {
    let mut api = Api::default();
    let toks: Vec<Vec<Tok>> = files.iter().map(|f| lex(f)).collect();
    // the names first: a fn may use a struct declared after it
    for t in &toks {
        for_items(t, &mut |attrs, item| {
            if (has_attr(attrs, "repr", "C") || repr_int(attrs).is_some()) && item.len() > 2 {
                if let Some(n) = item_name(item, &["struct", "enum"]) {
                    api.known.insert(n);
                }
            }
        });
    }
    for t in &toks {
        for_items(t, &mut |attrs, item| rust_item(&mut api, attrs, item));
    }
    api
}

/// calls f with each top-level item's attributes (the tokens of each #[...]) and its tokens
fn for_items(t: &[Tok], f: &mut dyn FnMut(&[Vec<Tok>], &[Tok])) {
    let mut c = Cur { t, i: 0 };
    let mut attrs = Vec::new();
    while c.i < t.len() {
        if c.is("#") {
            c.i += 1;
            c.eat("!");
            if c.is("[") {
                let s = c.i;
                c.skip_group();
                attrs.push(t[s + 1..c.i - 1].to_vec());
            }
            continue;
        }
        // an item: up to its ; or its body, a mod's body being items of its own
        let start = c.i;
        let mut is_mod = false;
        while c.i < t.len() {
            if c.is_id("mod") {
                is_mod = true;
            }
            if c.is(";") {
                c.i += 1;
                break;
            }
            if c.is("{") {
                if is_mod {
                    let s = c.i;
                    c.skip_group();
                    for_items(&t[s + 1..c.i - 1], f);
                } else {
                    c.skip_group();
                    // a struct body ends the item; so does a fn's
                }
                break;
            }
            if c.is("(") || c.is("[") {
                c.skip_group();
                continue;
            }
            c.i += 1;
        }
        if !is_mod {
            f(&attrs, &t[start..c.i]);
        }
        attrs.clear();
    }
}

fn has_attr(attrs: &[Vec<Tok>], name: &str, arg: &str) -> bool {
    attrs.iter().any(|a| {
        let s: Vec<String> = a.iter().map(tok_text).collect();
        let joined = s.join("");
        joined == name || joined.starts_with(&format!("{name}({arg}")) || joined == format!("unsafe({name})") || (arg.is_empty() && joined.starts_with(name))
    })
}

/// #[repr(u8)] and the like: the C tag type
fn repr_int(attrs: &[Vec<Tok>]) -> Option<&'static str> {
    for a in attrs {
        let s: String = a.iter().map(tok_text).collect::<Vec<_>>().join("");
        if let Some(r) = s.strip_prefix("repr(").and_then(|r| r.strip_suffix(')')) {
            for part in r.split(',') {
                if let Some(p) = prim(part.trim()) {
                    if part.trim().starts_with('i') || part.trim().starts_with('u') {
                        return Some(p);
                    }
                }
            }
        }
    }
    None
}

fn tok_text(t: &Tok) -> String {
    match t {
        Tok::Id(s) | Tok::Num(s) | Tok::P(s) => s.clone(),
        Tok::Str(s) => format!("\"{s}\""),
    }
}

/// the name after the first of `kinds` (struct Foo, fn bar)
fn item_name(item: &[Tok], kinds: &[&str]) -> Option<String> {
    let k = item.iter().position(|t| matches!(t, Tok::Id(w) if kinds.contains(&w.as_str())))?;
    match item.get(k + 1) {
        Some(Tok::Id(n)) => Some(n.clone()),
        _ => None,
    }
}

fn rust_item(api: &mut Api, attrs: &[Vec<Tok>], item: &[Tok]) {
    let is_pub = matches!(item.first(), Some(Tok::Id(w)) if w == "pub");
    let words: Vec<&str> = item.iter().take_while(|t| !matches!(t, Tok::P(p) if p == "(" || p == "{" || p == "<")).filter_map(|t| if let Tok::Id(w) = t { Some(w.as_str()) } else { None }).collect();
    if words.contains(&"fn") {
        let no_mangle = has_attr(attrs, "no_mangle", "") || has_attr(attrs, "export_name", "");
        let extern_c = item.windows(2).any(|w| w[0] == Tok::Id("extern".into()) && matches!(&w[1], Tok::Str(s) if s == "C" || s == "C-unwind"));
        if !(no_mangle && extern_c) {
            return;
        }
        let Some(name) = item_name(item, &["fn"]) else { return };
        let mut c = Cur { t: item, i: 0 };
        while c.i < item.len() && !c.is("(") {
            c.i += 1;
        }
        let params = c.group_items();
        let mut ps = Vec::new();
        for p in &params {
            let Some(colon) = p.iter().position(|t| *t == Tok::P(":".into())) else { continue };
            let pname = match p.get(colon - 1) {
                Some(Tok::Id(n)) if n != "_" => n.clone(),
                _ => format!("a{}", ps.len()),
            };
            match rust_ty(api, &p[colon + 1..]) {
                Some(t) => ps.push(declare(&t, &pname)),
                None => {
                    api.left_out.push(format!("fn {name} (parameter {pname}'s type)"));
                    return;
                }
            }
        }
        let ret = if c.eat("->") {
            let s = c.i;
            while c.i < item.len() && !c.is("{") && !c.is(";") && !c.is_id("where") {
                c.i += 1;
            }
            match rust_ty(api, &item[s..c.i]) {
                Some(t) if t != "!" => t,
                _ => {
                    api.left_out.push(format!("fn {name} (its return type)"));
                    return;
                }
            }
        } else {
            "void".into()
        };
        let ps = if ps.is_empty() { "void".to_string() } else { ps.join(", ") };
        api.fns.push(format!("{}({ps})", declare(&ret, &name)));
    } else if words.contains(&"struct") && is_pub && has_attr(attrs, "repr", "C") {
        let Some(name) = item_name(item, &["struct"]) else { return };
        let Some(open) = item.iter().position(|t| *t == Tok::P("{".into())) else {
            api.left_out.push(format!("struct {name} (a tuple or unit struct)"));
            return;
        };
        let mut c = Cur { t: item, i: open };
        let mut fields = Vec::new();
        for f in c.group_items() {
            let f: Vec<Tok> = f.into_iter().skip_while(|t| matches!(t, Tok::P(p) if p == "#")).collect();
            let Some(colon) = f.iter().position(|t| *t == Tok::P(":".into())) else { continue };
            let Some(Tok::Id(fname)) = f.get(colon - 1) else { continue };
            match rust_ty(api, &f[colon + 1..]) {
                Some(t) => fields.push((fname.clone(), t)),
                None => {
                    api.left_out.push(format!("struct {name} (field {fname}'s type)"));
                    api.known.remove(&name);
                    return;
                }
            }
        }
        api.structs.push((name, fields));
    } else if words.contains(&"enum") && is_pub {
        let Some(name) = item_name(item, &["enum"]) else { return };
        let tag = repr_int(attrs).or(has_attr(attrs, "repr", "C").then_some("int"));
        let Some(tag) = tag else { return };
        let Some(open) = item.iter().position(|t| *t == Tok::P("{".into())) else { return };
        let mut c = Cur { t: item, i: open };
        let mut vs = Vec::new();
        let mut next: i128 = 0;
        for v in c.group_items() {
            let Some(Tok::Id(vn)) = v.iter().find(|t| matches!(t, Tok::Id(_))) else { continue };
            if v.iter().any(|t| matches!(t, Tok::P(p) if p == "(" || p == "{")) {
                api.left_out.push(format!("enum {name} (variant {vn} holds data)"));
                api.known.remove(&name);
                return;
            }
            if let Some(eq) = v.iter().position(|t| *t == Tok::P("=".into())) {
                next = int_value(&v[eq + 1..]).unwrap_or(next);
            }
            vs.push((vn.clone(), next));
            next += 1;
        }
        api.enums.push((name, tag.to_string(), vs));
    }
}

/// an integer literal, maybe negative (-1, 0x10, 0b11)
fn int_value(t: &[Tok]) -> Option<i128> {
    let (neg, rest) = match t {
        [Tok::P(m), rest @ ..] if m == "-" => (true, rest),
        _ => (false, t),
    };
    let Some(Tok::Num(n)) = rest.first() else { return None };
    let n = n.trim_end_matches(|c: char| c.is_ascii_alphabetic() && !c.is_ascii_hexdigit() || c == 'u' || c == 'i');
    let v = if let Some(h) = n.strip_prefix("0x") {
        i128::from_str_radix(h, 16).ok()?
    } else if let Some(b) = n.strip_prefix("0b") {
        i128::from_str_radix(b, 2).ok()?
    } else if let Some(o) = n.strip_prefix("0o") {
        i128::from_str_radix(o, 8).ok()?
    } else {
        n.parse().ok()?
    };
    Some(if neg { -v } else { v })
}

/// every .rs file under dir (a crate's src)
fn rust_files(dir: &Path, out: &mut Vec<String>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    let mut paths: Vec<_> = rd.filter_map(|e| e.ok().map(|e| e.path())).collect();
    paths.sort();
    for p in paths {
        if p.is_dir() {
            rust_files(&p, out);
        } else if p.extension().is_some_and(|x| x == "rs") {
            if let Ok(s) = std::fs::read_to_string(&p) {
                out.push(s);
            }
        }
    }
}

/// the C header of the Rust crate in dir
pub fn rust_header(dir: &Path, name: &str) -> String {
    let mut files = Vec::new();
    rust_files(&dir.join("src"), &mut files);
    rust_api(&files).header(name, &format!("Rust crate {name}"))
}

// ---------- Zig ----------

/// the C type of a Zig type (its tokens), or None
fn zig_ty(api: &Api, t: &[Tok]) -> Option<String> {
    let mut c = Cur { t, i: 0 };
    let ty = zig_ty_at(api, &mut c)?;
    (c.i == t.len()).then_some(ty)
}

fn zig_ty_at(api: &Api, c: &mut Cur) -> Option<String> {
    if c.eat("?") {
        // ?*T, ?*const fn: a nullable pointer, as C has them
        if !(c.is("*") || c.is("[")) {
            return None;
        }
    }
    if c.is("*") || c.is("[") {
        // *T, *const T, [*]T, [*c]T, [*:0]const u8
        let many = c.is("[");
        if many {
            let items = c.group_items();
            let ok = items.len() == 1 && matches!(items[0].first(), Some(Tok::P(p)) if p == "*");
            if !ok {
                return None;
            }
        } else {
            c.i += 1;
        }
        let constant = c.eat("const");
        if c.is_id("fn") {
            return zig_fn_ptr(api, c);
        }
        let inner = zig_ty_at(api, c)?;
        return Some(pointer_to(&inner, constant));
    }
    let name = c.id()?;
    let name = name.strip_prefix("std.").unwrap_or(&name).to_string();
    if c.eat(".") {
        // c.int and friends aren't the C header's: only plain names here
        return None;
    }
    if name == "void" {
        return Some("void".into());
    }
    if let Some(p) = prim(&name) {
        return Some(p.to_string());
    }
    api.known.contains(&name).then_some(name)
}

/// fn (A, B) callconv(.c) R, after the pointer: a C function pointer type
fn zig_fn_ptr(api: &Api, c: &mut Cur) -> Option<String> {
    if !c.eat("fn") || !c.is("(") {
        return None;
    }
    let params = c.group_items();
    let mut ps = Vec::new();
    for p in &params {
        let ty = match p.iter().position(|t| *t == Tok::P(":".into())) {
            Some(k) => &p[k + 1..],
            None => &p[..],
        };
        ps.push(zig_ty(api, ty)?);
    }
    if c.eat("callconv") {
        c.skip_group();
    }
    let ret = zig_ty_at(api, c)?;
    let ps = if ps.is_empty() { "void".to_string() } else { ps.join(", ") };
    Some(format!("{ret} (*)({ps})"))
}

/// the C API of a Zig file: its export fns, extern structs and enum(T)s
fn zig_api(src: &str) -> Api {
    let t = lex(src);
    let mut api = Api::default();
    // pub const NAME = extern struct { ... }; / enum(c_int) { ... };
    let decl = |k: usize| -> Option<(String, usize)> {
        if t.get(k) != Some(&Tok::Id("const".into())) {
            return None;
        }
        let Some(Tok::Id(n)) = t.get(k + 1) else { return None };
        (t.get(k + 2) == Some(&Tok::P("=".into()))).then(|| (n.clone(), k + 3))
    };
    for k in 0..t.len() {
        if let Some((n, at)) = decl(k) {
            if t.get(at) == Some(&Tok::Id("extern".into())) && t.get(at + 1) == Some(&Tok::Id("struct".into())) {
                api.known.insert(n);
            } else if t.get(at) == Some(&Tok::Id("enum".into())) && t.get(at + 1) == Some(&Tok::P("(".into())) {
                api.known.insert(n);
            }
        }
    }
    let mut k = 0;
    while k < t.len() {
        if let Some((n, at)) = decl(k) {
            if t.get(at) == Some(&Tok::Id("extern".into())) && t.get(at + 1) == Some(&Tok::Id("struct".into())) {
                let mut c = Cur { t: &t, i: at + 2 };
                let mut fields = Vec::new();
                let mut ok = true;
                for f in c.group_items() {
                    let Some(colon) = f.iter().position(|x| *x == Tok::P(":".into())) else { continue };
                    let Some(Tok::Id(fname)) = f.get(colon - 1) else { continue };
                    // a default value (= ...) isn't part of the type
                    let end = f.iter().position(|x| *x == Tok::P("=".into())).unwrap_or(f.len());
                    match zig_ty(&api, &f[colon + 1..end]) {
                        Some(ty) => fields.push((fname.clone(), ty)),
                        None => {
                            api.left_out.push(format!("struct {n} (field {fname}'s type)"));
                            ok = false;
                            break;
                        }
                    }
                }
                if ok {
                    api.structs.push((n, fields));
                } else {
                    api.known.remove(&n);
                }
                k = c.i;
                continue;
            }
            if t.get(at) == Some(&Tok::Id("enum".into())) && t.get(at + 1) == Some(&Tok::P("(".into())) {
                let mut c = Cur { t: &t, i: at + 1 };
                let tag = c.group_items();
                let tag = tag.first().and_then(|x| zig_ty(&api, x)).unwrap_or("int".into());
                let mut vs = Vec::new();
                let mut next: i128 = 0;
                for v in c.group_items() {
                    let Some(Tok::Id(vn)) = v.first() else { continue };
                    if v.first() == Some(&Tok::Id("_".into())) {
                        continue;
                    }
                    if let Some(eq) = v.iter().position(|x| *x == Tok::P("=".into())) {
                        next = int_value(&v[eq + 1..]).unwrap_or(next);
                    }
                    vs.push((vn.clone(), next));
                    next += 1;
                }
                api.enums.push((n, tag, vs));
                k = c.i;
                continue;
            }
        }
        if t.get(k) == Some(&Tok::Id("export".into())) && t.get(k + 1) == Some(&Tok::Id("fn".into())) {
            let Some(Tok::Id(name)) = t.get(k + 2) else {
                k += 1;
                continue;
            };
            let mut c = Cur { t: &t, i: k + 3 };
            let params = c.group_items();
            let mut ps = Vec::new();
            let mut ok = true;
            for p in &params {
                let Some(colon) = p.iter().position(|x| *x == Tok::P(":".into())) else { continue };
                let pname = match p.get(colon - 1) {
                    Some(Tok::Id(n)) if n != "_" => n.clone(),
                    _ => format!("a{}", ps.len()),
                };
                match zig_ty(&api, &p[colon + 1..]) {
                    Some(ty) => ps.push(declare(&ty, &pname)),
                    None => {
                        api.left_out.push(format!("fn {name} (parameter {pname}'s type)"));
                        ok = false;
                        break;
                    }
                }
            }
            if c.eat("callconv") {
                c.skip_group();
            }
            let s = c.i;
            while c.i < t.len() && !c.is("{") {
                c.i += 1;
            }
            if ok {
                match zig_ty(&api, &t[s..c.i]) {
                    Some(r) => {
                        let ps = if ps.is_empty() { "void".to_string() } else { ps.join(", ") };
                        api.fns.push(format!("{}({ps})", declare(&r, name)));
                    }
                    None => api.left_out.push(format!("fn {name} (its return type)")),
                }
            }
            c.skip_group();
            k = c.i;
            continue;
        }
        k += 1;
    }
    api
}

/// the C header of a Zig file
pub fn zig_header(file: &Path, name: &str) -> String {
    let src = std::fs::read_to_string(file).unwrap_or_default();
    zig_api(&src).header(name, &format!("Zig library {name}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rust() {
        let src = r#"
use std::os::raw::c_char;
/// a point
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Point { pub x: f64, pub y: f64 }

#[repr(u8)]
pub enum Mode { Off = 1, On }

#[no_mangle]
pub extern "C" fn rs_add(a: i32, b: i32) -> i32 { a + b }
#[no_mangle]
pub unsafe extern "C" fn rs_len(p: *const Point, n: usize, name: *const c_char) -> f64 { 0.0 }
#[unsafe(no_mangle)]
pub extern "C" fn rs_apply(f: extern "C" fn(i32) -> i32, x: i32, cb: Option<extern "C" fn(*mut Point)>) -> i32 { f(x) }
#[no_mangle]
pub extern "C" fn rs_mode(m: Mode, p: &mut Point) -> Mode { m }
pub fn not_exported(x: Vec<i32>) {}
#[no_mangle]
pub extern "C" fn rs_vec(x: Vec<i32>) {}
mod inner {
    #[no_mangle]
    pub extern "C" fn rs_inner() {}
}
impl Point { pub fn len(&self) -> f64 { 0.0 } }
"#;
        let h = rust_api(&[src.to_string()]).header("geo", "x");
        for want in [
            "typedef uint8_t Mode;",
            "    Mode_Off = 1,\n    Mode_On = 2,",
            "struct Point {\n    double x;\n    double y;\n};",
            "int32_t rs_add(int32_t a, int32_t b);",
            "double rs_len(const Point *p, size_t n, const char *name);",
            "int32_t rs_apply(int32_t (*f)(int32_t), int32_t x, void (*cb)(Point *));",
            "Mode rs_mode(Mode m, Point *p);",
            "void rs_inner(void);",
            "// left out: fn rs_vec (parameter x's type)",
        ] {
            assert!(h.contains(want), "missing {want:?} in\n{h}");
        }
        assert!(!h.contains("not_exported") && !h.contains(" len("), "{h}");
    }

    #[test]
    fn zig() {
        let src = r#"
const std = @import("std");
pub const Point = extern struct { x: f64, y: f64 = 0 };
pub const Mode = enum(u8) { off = 1, on };
export fn zg_add(a: i32, b: i32) i32 { return a + b; }
export fn zg_len(p: *const Point, n: usize, name: [*:0]const u8) callconv(.c) f64 { _ = p; _ = n; _ = name; return 0; }
export fn zg_apply(f: *const fn (i32) callconv(.c) i32, x: i32) i32 { return f(x); }
export fn zg_slice(xs: []const i32) usize { return xs.len; }
export fn zg_mode(m: Mode, p: ?*Point) void { _ = m; _ = p; }
fn private(x: i32) i32 { return x; }
"#;
        let h = zig_api(src).header("geo", "x");
        for want in [
            "typedef uint8_t Mode;",
            "    Mode_off = 1,\n    Mode_on = 2,",
            "struct Point {\n    double x;\n    double y;\n};",
            "int32_t zg_add(int32_t a, int32_t b);",
            "double zg_len(const Point *p, size_t n, const uint8_t *name);",
            "int32_t zg_apply(int32_t (*f)(int32_t), int32_t x);",
            "void zg_mode(Mode m, Point *p);",
            "// left out: fn zg_slice (parameter xs's type)",
        ] {
            assert!(h.contains(want), "missing {want:?} in\n{h}");
        }
        assert!(!h.contains("private"), "{h}");
    }
}
