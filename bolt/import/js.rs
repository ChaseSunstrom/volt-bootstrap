// use { "geom.ts" } as NAME; (or "lib.js" with a lib.d.ts beside it) — JavaScript called from Volt.
// bolt reads the TypeScript declarations for the types (a small parser of exported functions,
// classes, enums and constants), strips the types with node (strip-only TypeScript: its enums are
// rewritten first), and writes Volt that runs the module in JavaScriptCore through its C API (its
// headers, copied beside the import so they need no -I, and js_rt, a small runtime in the import's
// namespace). No shim and no C: the engine starts the first time it's called.
//
//   number -> f64; string -> str in, std::string out; boolean -> bool; T[] (of those) -> T[..] in
//   (what JavaScript changes in an array of numbers or booleans comes back), std::vec<T> out;
//   T | null | undefined -> T?; an exported class -> a handle (a copy refers to the same object):
//   new T(...) is T::new(...), methods, static methods, fields and get/set accessors as x() and
//   set_x(v); a numeric enum -> a Volt enum; exported constants of those types -> vals
//   a thrown exception -> the program stops with its text
use super::{arg_path, fresh, save, stamp, volt_name, Made, Req};
use std::collections::BTreeSet;
use std::fmt::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn import(r: &Req) -> Result<(), String> {
    let [arg] = r.args.as_slice() else {
        return Err(format!("use js {{ \"geom.ts\" }} as {}: name one module", r.alias));
    };
    let file = arg_path(r, arg);
    let ext = file.extension().map(|e| e.to_string_lossy().to_ascii_lowercase()).unwrap_or_default();
    if !file.is_file() || !["ts", "mts", "js", "mjs"].contains(&ext.as_str()) {
        return Err(format!("use js: {} isn't a .ts or .js file", file.display()));
    }
    // a JavaScript file's types: its .d.ts
    let ts = ext.ends_with("ts");
    let types = if ts { file.clone() } else { file.with_extension("d.ts") };
    if !types.is_file() {
        return Err(format!("use js: {} needs its types: a {} beside it (or write it in TypeScript)", file.display(), types.file_name().map_or(String::new(), |n| n.to_string_lossy().into_owned())));
    }
    let mut files = vec![file.clone()];
    if !ts {
        files.push(types.clone());
    }
    let node = std::env::var("NODE").unwrap_or_else(|_| "node".into());
    let st = stamp(&files, &format!("js {} {}", r.alias, file.display()));
    if fresh(r, &st) {
        return Ok(());
    }
    std::fs::create_dir_all(&r.out).map_err(|e| format!("can't make {}: {e}", r.out.display()))?;
    let out = std::fs::canonicalize(&r.out).unwrap_or_else(|_| r.out.clone());

    // the declarations, and the module as a script returning what it exports
    let tsrc = std::fs::read_to_string(&types).map_err(|e| format!("use js: can't read {}: {e}", types.display()))?;
    let m = parse(&tsrc);
    let src = std::fs::read_to_string(&file).map_err(|e| format!("use js: can't read {}: {e}", file.display()))?;
    let edited = if ts { rewrite(&src, &m.edits)? } else { rewrite(&src, &parse(&src).edits)? };
    let js = if ts {
        let edited_file = out.join("module.ts");
        crate::build::write_if_changed(&edited_file, &edited)?;
        let o = Command::new(&node)
            .args(["-e", "process.stdout.write(require('module').stripTypeScriptTypes(require('fs').readFileSync(process.argv[1], 'utf8')))"])
            .arg(&edited_file)
            .output()
            .map_err(|e| format!("use js: can't run {node}: {e} (TypeScript needs node 23.2 or later to strip its types; set $NODE)"))?;
        if !o.status.success() {
            return Err(format!("use js: node couldn't strip {}'s types (strip-only TypeScript: no parameter properties or namespaces):\n{}", file.display(), String::from_utf8_lossy(&o.stderr)));
        }
        String::from_utf8_lossy(&o.stdout).into_owned()
    } else {
        edited
    };
    let names: Vec<&str> = m.items.iter().map(|i| i.name()).collect();
    let script = format!("(function () {{\n{js}\nreturn {{ {} }};\n}})()\n", names.join(", "));
    let script_file = out.join("module.js");
    crate::build::write_if_changed(&script_file, &script)?;

    // JavaScriptCore's headers, their includes made relative
    let inc = jsc_include()?;
    let hdir = out.join("jsc");
    std::fs::create_dir_all(&hdir).map_err(|e| format!("can't make {}: {e}", hdir.display()))?;
    for e in std::fs::read_dir(inc.join("JavaScriptCore")).map_err(|e| format!("use js: can't read {}: {e}", inc.display()))?.flatten() {
        let p = e.path();
        if p.extension().is_some_and(|x| x == "h") {
            let text = std::fs::read_to_string(&p).map_err(|e| format!("use js: can't read {}: {e}", p.display()))?;
            let text = text.lines().map(|l| match l.trim().strip_prefix("#include <JavaScriptCore/").and_then(|x| x.split_once('>')) {
                Some((h, rest)) => format!("#include \"{h}\"{rest}"),
                None => l.to_string(),
            });
            crate::build::write_if_changed(&hdir.join(e.file_name()), &(text.collect::<Vec<_>>().join("\n") + "\n"))?;
        }
    }
    let volt = generate(&r.alias, &m, &hdir.join("JavaScript.h"), &script_file);
    save(r, &Made { volt, flags: jsc_libs(), deps: files }, &st)
}

/// JavaScriptCore's include directory, from pkg-config ($JSC_PKG for another package)
fn jsc_include() -> Result<PathBuf, String> {
    let pkg = std::env::var("JSC_PKG").unwrap_or_else(|_| "javascriptcoregtk-4.1".into());
    let o = Command::new("pkg-config").args(["--cflags-only-I", &pkg]).output().map_err(|e| format!("use js: can't run pkg-config: {e}"))?;
    if !o.status.success() {
        return Err(format!("use js: needs JavaScriptCore (pkg-config {pkg}): install WebKitGTK's JavaScriptCore, or set $JSC_PKG"));
    }
    String::from_utf8_lossy(&o.stdout).split_whitespace().filter_map(|w| w.strip_prefix("-I")).map(PathBuf::from).find(|d| d.join("JavaScriptCore/JavaScript.h").is_file()).ok_or_else(|| format!("use js: {pkg}'s include directories have no JavaScriptCore/JavaScript.h"))
}

fn jsc_libs() -> Vec<String> {
    let pkg = std::env::var("JSC_PKG").unwrap_or_else(|_| "javascriptcoregtk-4.1".into());
    Command::new("pkg-config").args(["--libs", &pkg]).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).split_whitespace().map(str::to_string).collect()).unwrap_or_default()
}

// ---------- reading TypeScript declarations ----------

#[derive(Clone, Debug, PartialEq)]
enum T {
    Id(String),
    Num(String),
    Str(String),
    P(char),
}

#[derive(Clone, Debug)]
struct Tok {
    t: T,
    at: usize,
    end: usize,
}

/// TypeScript as tokens with their byte ranges (comments dropped; a template literal is one Str)
fn lex(src: &str) -> Vec<Tok> {
    let b = src.as_bytes();
    let (mut out, mut i) = (Vec::new(), 0);
    while i < b.len() {
        let c = b[i];
        let start = i;
        if c.is_ascii_whitespace() {
            i += 1;
        } else if b[i..].starts_with(b"//") {
            while i < b.len() && b[i] != b'\n' {
                i += 1;
            }
        } else if b[i..].starts_with(b"/*") {
            i += 2;
            while i + 1 < b.len() && !b[i..].starts_with(b"*/") {
                i += 1;
            }
            i += 2;
        } else if c == b'"' || c == b'\'' || c == b'`' {
            i += 1;
            let mut depth = 0;
            while i < b.len() && (b[i] != c || depth > 0) {
                if b[i] == b'\\' {
                    i += 1;
                } else if c == b'`' && b[i..].starts_with(b"${") {
                    depth += 1;
                } else if c == b'`' && b[i] == b'}' && depth > 0 {
                    depth -= 1;
                }
                i += 1;
            }
            i += 1;
            out.push(Tok { t: T::Str(src[start + 1..(i - 1).min(src.len()).max(start + 1)].to_string()), at: start, end: i.min(src.len()) });
        } else if c.is_ascii_digit() {
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'.' || b[i] == b'_') {
                i += 1;
            }
            out.push(Tok { t: T::Num(src[start..i].to_string()), at: start, end: i });
        } else if c.is_ascii_alphabetic() || c == b'_' || c == b'$' || c == b'#' || c >= 0x80 {
            i += 1;
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_' || b[i] == b'$' || b[i] >= 0x80) {
                i += 1;
            }
            out.push(Tok { t: T::Id(src[start..i].to_string()), at: start, end: i });
        } else {
            i += 1;
            out.push(Tok { t: T::P(c as char), at: start, end: i });
        }
    }
    out
}

#[derive(Clone, Debug, PartialEq)]
struct Param {
    name: String,
    ty: String,
    optional: bool,
    default: Option<String>,
    rest: bool,
}

#[derive(Clone, Debug, PartialEq)]
struct Func {
    name: String,
    params: Vec<Param>,
    /// None: not written (an error when the body returns something)
    ret: Option<String>,
    returns: bool,
    is_static: bool,
    is_async: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
struct Class {
    name: String,
    base: Option<String>,
    ctor: Option<Func>,
    methods: Vec<Func>,
    /// fields and accessors: name, type, settable, static
    props: Vec<(String, String, bool, bool)>,
}

#[derive(Clone, Debug, PartialEq)]
enum Item {
    Func(Func),
    Class(Class),
    Enum(String, Vec<(String, i64)>),
    Const(String, String, String),
}

impl Item {
    fn name(&self) -> &str {
        match self {
            Item::Func(f) => &f.name,
            Item::Class(c) => &c.name,
            Item::Enum(n, _) | Item::Const(n, _, _) => n,
        }
    }
}

#[derive(Default)]
struct Module {
    items: Vec<Item>,
    left: Vec<String>,
    /// text edits making the source a script: (range, replacement)
    edits: Vec<(usize, usize, String)>,
}

struct P<'a> {
    toks: &'a [Tok],
    i: usize,
    src: &'a str,
}

impl P<'_> {
    fn peek(&self, k: usize) -> Option<&T> {
        self.toks.get(self.i + k).map(|t| &t.t)
    }
    fn is_id(&self, k: usize, s: &str) -> bool {
        matches!(self.peek(k), Some(T::Id(x)) if x == s)
    }
    fn is_p(&self, k: usize, c: char) -> bool {
        self.peek(k) == Some(&T::P(c))
    }
    fn id(&mut self) -> Option<String> {
        match self.peek(0) {
            Some(T::Id(x)) => {
                let x = x.clone();
                self.i += 1;
                Some(x)
            }
            _ => None,
        }
    }
    /// past the bracketed group starting here ((...), {...}, [...], <...>)
    fn skip_group(&mut self) {
        let (open, close) = match self.peek(0) {
            Some(T::P('(')) => ('(', ')'),
            Some(T::P('{')) => ('{', '}'),
            Some(T::P('[')) => ('[', ']'),
            Some(T::P('<')) => ('<', '>'),
            _ => return,
        };
        let mut depth = 0;
        while let Some(t) = self.peek(0) {
            if *t == T::P(open) {
                depth += 1;
            } else if *t == T::P(close) {
                depth -= 1;
                if depth == 0 {
                    self.i += 1;
                    return;
                }
            }
            self.i += 1;
        }
    }
    /// a type's text, up to one of stops outside brackets (=> in a function type isn't a stop)
    fn ty(&mut self, stops: &[char]) -> String {
        let start = self.i;
        let mut depth = 0i32;
        while let Some(t) = self.peek(0) {
            match t {
                T::P(c) if depth == 0 && stops.contains(c) => break,
                T::P('(' | '[' | '<' | '{') => depth += 1,
                T::P(')' | ']' | '}') if depth > 0 => depth -= 1,
                T::P('>') if depth > 0 && !(self.i > 0 && self.toks[self.i - 1].t == T::P('=')) => depth -= 1,
                _ => {}
            }
            self.i += 1;
        }
        if start == self.i {
            return String::new();
        }
        self.src[self.toks[start].at..self.toks[self.i - 1].end].split_whitespace().collect::<Vec<_>>().join(" ")
    }
    /// a literal's Volt text (a number, a string, true/false, null), or None
    fn literal(&mut self) -> Option<String> {
        let neg = self.is_p(0, '-');
        if neg {
            self.i += 1;
        }
        let r = match self.peek(0)?.clone() {
            T::Num(n) if n.chars().all(|c| c.is_ascii_digit() || c == '.') => Some(format!("{}{}{}", if neg { "-" } else { "" }, n, if n.contains('.') { "" } else { ".0" })),
            T::Str(s) if !neg && s.chars().all(|c| (' '..='~').contains(&c) && !"\"\\{}`$".contains(c)) => Some(format!("\"{s}\"")),
            T::Id(x) if !neg && (x == "true" || x == "false" || x == "null") => Some(x),
            _ => None,
        };
        self.i += 1;
        r
    }
    fn params(&mut self) -> Vec<Param> {
        let mut out = Vec::new();
        if !self.is_p(0, '(') {
            return out;
        }
        self.i += 1;
        while !self.is_p(0, ')') && self.peek(0).is_some() {
            let rest = self.is_p(0, '.');
            while self.is_p(0, '.') {
                self.i += 1;
            }
            while matches!(self.peek(0), Some(T::Id(x)) if ["public", "private", "protected", "readonly", "override"].contains(&x.as_str())) && matches!(self.peek(1), Some(T::Id(_))) {
                self.i += 1;
            }
            let name = match self.peek(0) {
                Some(T::Id(x)) => x.clone(),
                _ => {
                    // a destructured parameter
                    self.skip_group();
                    String::new()
                }
            };
            if !name.is_empty() {
                self.i += 1;
            }
            let optional = self.is_p(0, '?');
            if optional {
                self.i += 1;
            }
            let ty = if self.is_p(0, ':') {
                self.i += 1;
                self.ty(&[',', ')', '='])
            } else {
                String::new()
            };
            let default = if self.is_p(0, '=') {
                self.i += 1;
                let at = self.i;
                let lit = self.literal();
                // a default that isn't a literal: skip it
                self.i = at;
                self.ty(&[',', ')']);
                lit
            } else {
                None
            };
            out.push(Param { name, ty, optional, default, rest });
            if self.is_p(0, ',') {
                self.i += 1;
            }
        }
        self.i += 1;
        out
    }
    /// after the parameters: the return type (if written), then the body (or ;); whether the
    /// body returns a value
    fn ret_and_body(&mut self) -> (Option<String>, bool) {
        let ret = if self.is_p(0, ':') {
            self.i += 1;
            Some(self.ty(&['{', ';']))
        } else {
            None
        };
        let mut returns = false;
        if self.is_p(0, '{') {
            let start = self.i;
            self.skip_group();
            returns = self.toks[start..self.i].windows(2).any(|w| w[0].t == T::Id("return".into()) && w[1].t != T::P(';') && w[1].t != T::P('}'));
        } else if self.is_p(0, ';') {
            self.i += 1;
        }
        (ret, returns)
    }
    /// past a statement: to its ; or past its {...} at depth 0
    fn skip_statement(&mut self) {
        while let Some(t) = self.peek(0) {
            match t {
                T::P(';') => {
                    self.i += 1;
                    return;
                }
                T::P('{') | T::P('(') | T::P('[') => self.skip_group(),
                T::P('}') => return,
                _ => self.i += 1,
            }
            if self.i > 0 && self.toks[self.i - 1].t == T::P('}') && !matches!(self.peek(0), Some(T::P('.' | '(' | ',' | ')'))) {
                return;
            }
        }
    }
}

/// a module's exported declarations, and the edits that make its source a script
fn parse(src: &str) -> Module {
    let toks = lex(src);
    let mut p = P { toks: &toks, i: 0, src };
    let mut m = Module::default();
    while p.peek(0).is_some() {
        if p.is_id(0, "import") {
            let t = &toks[p.i];
            // a type-only import is gone after stripping; any other one can't run in a script
            if !p.is_id(1, "type") {
                m.left.push("import (a module that imports another can't run alone: bundle it into one file)".into());
            }
            let at = t.at;
            p.skip_statement();
            m.edits.push((at, toks[p.i - 1].end, String::new()));
            continue;
        }
        if !p.is_id(0, "export") {
            p.skip_statement();
            if p.is_p(0, '}') {
                p.i += 1;
            }
            continue;
        }
        let export_at = &toks[p.i];
        m.edits.push((export_at.at, export_at.end, " ".repeat(export_at.end - export_at.at)));
        p.i += 1;
        if p.is_id(0, "default") {
            m.left.push("the default export (only named exports reach Volt)".into());
            let t = &toks[p.i];
            m.edits.push((t.at, t.end, String::new()));
            p.i += 1;
            continue;
        }
        if p.is_id(0, "declare") {
            p.i += 1;
        }
        let is_async = p.is_id(0, "async");
        if is_async {
            p.i += 1;
        }
        if p.is_id(0, "function") {
            p.i += 1;
            if p.is_p(0, '*') {
                p.i += 1;
            }
            let name = p.id().unwrap_or_default();
            if p.is_p(0, '<') {
                p.skip_group();
                m.left.push(format!("{name} (it's generic)"));
                p.params();
                p.ret_and_body();
                continue;
            }
            let params = p.params();
            let (ret, returns) = p.ret_and_body();
            m.items.push(Item::Func(Func { name, params, ret, returns, is_static: true, is_async }));
        } else if p.is_id(0, "class") || (p.is_id(0, "abstract") && p.is_id(1, "class")) {
            if p.is_id(0, "abstract") {
                p.i += 1;
            }
            p.i += 1;
            let name = p.id().unwrap_or_default();
            let mut c = Class { name: name.clone(), ..Class::default() };
            if p.is_p(0, '<') {
                m.left.push(format!("{name} (it's generic)"));
                p.skip_group();
                p.skip_group();
                continue;
            }
            while !p.is_p(0, '{') && p.peek(0).is_some() {
                if p.is_id(0, "extends") {
                    p.i += 1;
                    c.base = p.id();
                } else {
                    p.i += 1;
                }
            }
            class_body(&mut p, &mut c, &mut m.left);
            m.items.push(Item::Class(c));
        } else if p.is_id(0, "enum") || (p.is_id(0, "const") && p.is_id(1, "enum")) {
            let at = toks[p.i].at;
            if p.is_id(0, "const") {
                p.i += 1;
            }
            p.i += 1;
            let name = p.id().unwrap_or_default();
            let (mut vals, mut next, mut ok) = (Vec::new(), 0i64, true);
            p.i += 1; // {
            while !p.is_p(0, '}') && p.peek(0).is_some() {
                let n = match p.peek(0) {
                    Some(T::Id(x)) | Some(T::Str(x)) => x.clone(),
                    _ => String::new(),
                };
                p.i += 1;
                if p.is_p(0, '=') {
                    p.i += 1;
                    let neg = p.is_p(0, '-');
                    if neg {
                        p.i += 1;
                    }
                    match p.peek(0).cloned() {
                        Some(T::Num(v)) => match v.parse::<i64>() {
                            Ok(v) => next = if neg { -v } else { v },
                            Err(_) => ok = false,
                        },
                        _ => ok = false,
                    }
                    p.ty(&[',', '}']);
                }
                vals.push((n, next));
                next += 1;
                if p.is_p(0, ',') {
                    p.i += 1;
                }
            }
            let end = toks[p.i].end;
            p.i += 1;
            // the enum as a frozen object, the same values
            let body: Vec<String> = vals.iter().map(|(n, v)| format!("{n}: {v}")).collect();
            m.edits.push((at, end, format!("const {name} = Object.freeze({{ {} }});", body.join(", "))));
            if ok {
                m.items.push(Item::Enum(name, vals));
            } else {
                m.left.push(format!("{name} (an enum of other than numbers)"));
            }
        } else if p.is_id(0, "const") || p.is_id(0, "let") || p.is_id(0, "var") {
            p.i += 1;
            let name = p.id().unwrap_or_default();
            let ty = if p.is_p(0, ':') {
                p.i += 1;
                p.ty(&['=', ';'])
            } else {
                String::new()
            };
            if p.is_p(0, '=') {
                p.i += 1;
                let at = p.i;
                let lit = p.literal();
                let simple = p.is_p(0, ';') || p.is_p(0, '}') || p.peek(0).is_none() || matches!(p.peek(0), Some(T::Id(_)));
                p.i = at;
                p.skip_statement();
                match lit.filter(|l| simple && l != "null") {
                    Some(l) => {
                        let t = if !ty.is_empty() {
                            ty
                        } else if l.starts_with('"') {
                            "string".into()
                        } else if l == "true" || l == "false" {
                            "boolean".into()
                        } else {
                            "number".into()
                        };
                        m.items.push(Item::Const(name, t, l));
                    }
                    None => m.left.push(format!("{name} (a value that isn't a literal)")),
                }
            } else {
                p.skip_statement();
            }
        } else if p.is_id(0, "interface") || p.is_id(0, "type") || p.is_id(0, "namespace") {
            p.skip_statement();
            if p.is_p(0, '}') {
                p.i += 1;
            }
        } else {
            p.skip_statement();
        }
    }
    m
}

fn class_body(p: &mut P, c: &mut Class, left: &mut Vec<String>) {
    p.i += 1; // {
    while !p.is_p(0, '}') && p.peek(0).is_some() {
        if p.is_p(0, ';') {
            p.i += 1;
            continue;
        }
        let (mut is_static, mut private, mut readonly, mut is_async, mut accessor) = (false, false, false, false, None);
        loop {
            match p.peek(0) {
                Some(T::Id(x)) if matches!(x.as_str(), "public" | "protected" | "private" | "static" | "readonly" | "abstract" | "override" | "declare" | "async" | "get" | "set") && !matches!(p.peek(1), Some(T::P('(' | ':' | '=' | ';' | '?' | '!'))) => {
                    match x.as_str() {
                        "static" => is_static = true,
                        "private" | "protected" => private = true,
                        "readonly" => readonly = true,
                        "async" => is_async = true,
                        "get" | "set" => accessor = Some(x.clone()),
                        _ => {}
                    }
                    p.i += 1;
                }
                _ => break,
            }
        }
        if p.is_p(0, '{') {
            // a static block
            p.skip_group();
            continue;
        }
        let name = match p.peek(0) {
            Some(T::Id(x)) => x.clone(),
            _ => {
                p.skip_statement();
                continue;
            }
        };
        p.i += 1;
        if name.starts_with('#') {
            private = true;
        }
        let optional = p.is_p(0, '?');
        if optional || p.is_p(0, '!') {
            p.i += 1;
        }
        if p.is_p(0, '(') || p.is_p(0, '<') {
            let generic = p.is_p(0, '<');
            if generic {
                p.skip_group();
            }
            let params = p.params();
            let (ret, returns) = p.ret_and_body();
            if private {
                continue;
            }
            if generic {
                left.push(format!("{}.{name} (it's generic)", c.name));
                continue;
            }
            if name == "constructor" {
                c.ctor = Some(Func { name, params, ret: None, returns: false, is_static: true, is_async: false });
            } else if let Some(a) = accessor {
                // get x(): T and set x(v: T)
                let ty = if a == "get" { ret.unwrap_or_default() } else { params.first().map(|x| x.ty.clone()).unwrap_or_default() };
                match c.props.iter_mut().find(|x| x.0 == name && x.3 == is_static) {
                    Some(x) => x.2 |= a == "set",
                    None => c.props.push((name, ty, a == "set", is_static)),
                }
            } else {
                c.methods.push(Func { name, params, ret, returns, is_static, is_async });
            }
        } else {
            // a field: name: T = init;
            let ty = if p.is_p(0, ':') {
                p.i += 1;
                p.ty(&['=', ';', '}'])
            } else {
                String::new()
            };
            if p.is_p(0, '=') {
                p.i += 1;
                p.ty(&[';', '}']);
            }
            if p.is_p(0, ';') {
                p.i += 1;
            }
            if !private {
                if ty.is_empty() {
                    left.push(format!("{}.{name} (a field without a type)", c.name));
                } else {
                    c.props.push((name, ty, !readonly, is_static));
                }
            }
        }
    }
    p.i += 1;
}

/// the source with the edits made (from the end, so the ranges stay right)
fn rewrite(src: &str, edits: &[(usize, usize, String)]) -> Result<String, String> {
    let mut e = edits.to_vec();
    e.sort_by_key(|x| std::cmp::Reverse(x.0));
    let mut s = src.to_string();
    for (a, b, t) in e {
        if b > s.len() || a > b {
            return Err("use js: can't rewrite the module".into());
        }
        s.replace_range(a..b, &t);
    }
    Ok(s)
}

// ---------- the Volt side ----------

/// a TypeScript type as Volt sees it
#[derive(Clone, PartialEq, Debug)]
enum JT {
    Void,
    /// number, string, boolean
    Prim(&'static str),
    List(&'static str),
    Opt(&'static str),
    Obj(String),
    Enum(String),
}

fn prim(s: &str) -> Option<&'static str> {
    match s {
        "number" => Some("num"),
        "string" => Some("str"),
        "boolean" => Some("bool"),
        _ => None,
    }
}

fn volt_prim(p: &str) -> &'static str {
    match p {
        "num" => "f64",
        "str" => "str",
        _ => "bool",
    }
}

struct Gen<'a> {
    alias: &'a str,
    enums: BTreeSet<String>,
    objs: BTreeSet<String>,
}

impl Gen<'_> {
    fn jt(&self, s: &str) -> Option<JT> {
        let s = s.trim();
        let parts: Vec<&str> = s.split('|').map(str::trim).filter(|x| !x.is_empty()).collect();
        let nullable = parts.iter().any(|x| *x == "null" || *x == "undefined");
        let rest: Vec<&str> = parts.iter().copied().filter(|x| *x != "null" && *x != "undefined").collect();
        if rest.is_empty() {
            return (s == "void" || s == "undefined").then_some(JT::Void);
        }
        let [one] = rest.as_slice() else { return None };
        let one = one.strip_prefix("readonly ").unwrap_or(one);
        if let Some(e) = one.strip_suffix("[]").or_else(|| one.strip_prefix("Array<").and_then(|x| x.strip_suffix('>'))) {
            return (!nullable).then_some(JT::List(prim(e.trim())?));
        }
        if let Some(p) = prim(one) {
            return Some(if nullable { JT::Opt(p) } else { JT::Prim(p) });
        }
        if one == "void" {
            return Some(JT::Void);
        }
        if self.enums.contains(one) && !nullable {
            return Some(JT::Enum(one.to_string()));
        }
        self.objs.contains(one).then(|| JT::Obj(one.to_string()))
    }

    fn ty_in(t: &JT) -> String {
        match t {
            JT::Prim(p) => volt_prim(p).into(),
            JT::List(p) => format!("{}[..]", volt_prim(p)),
            JT::Opt(p) => format!("{}?", volt_prim(p)),
            JT::Obj(n) => format!("{n}&"),
            JT::Enum(n) => n.clone(),
            JT::Void => "void".into(),
        }
    }

    fn ty_out(t: &JT) -> String {
        let one = |p: &str| if p == "str" { "std::string".to_string() } else { volt_prim(p).to_string() };
        match t {
            JT::Prim(p) => one(p),
            JT::List(p) => format!("std::vec<{}>", one(p)),
            JT::Opt(p) => format!("{}?", one(p)),
            JT::Obj(n) => n.clone(),
            t => Self::ty_in(t),
        }
    }

    /// Volt value v as a JavaScript value (statements before, the value, statements after)
    fn to_js(t: &JT, v: &str) -> (Vec<String>, String, Vec<String>) {
        match t {
            JT::Prim(p) => (vec![], format!("js_rt::of_{p}({v})"), vec![]),
            JT::List("str") => (vec![], format!("js_rt::of_strs({v})"), vec![]),
            // the array's numbers (or booleans) come back
            JT::List(p) => (vec![format!("val {v}_a = js_rt::of_{p}s({v});")], format!("{v}_a"), vec![format!("js_rt::back_{p}s({v}_a, {v});")]),
            JT::Opt(p) => (vec![], format!("js_rt::of_opt_{p}({v})"), vec![]),
            JT::Obj(_) => (vec![], format!("js_rt::of_obj({v}.o.v)"), vec![]),
            JT::Enum(n) => (vec![], format!("js_rt::of_num(@cast<f64>(js_rt::tag_{n}({v})))"), vec![]),
            JT::Void => (vec![], "js_rt::undefined()".into(), vec![]),
        }
    }

    /// the statements returning JavaScript value j_r as Volt's
    fn result(t: &JT) -> Vec<String> {
        match t {
            JT::Void => vec![],
            JT::Prim(p) => vec![format!("return js_rt::to_{p}(j_r);")],
            JT::List(p) => vec![format!("return js_rt::to_{p}s(j_r);")],
            JT::Opt(p) => vec!["if (js_rt::is_nothing(j_r)) {".into(), "    return null;".into(), "}".into(), format!("return js_rt::to_{p}(j_r);")],
            JT::Obj(n) => vec![format!("val j_v: {n} = {{ o: js_rt::keep(j_r) }};"), "return j_v;".into()],
            JT::Enum(n) => vec![format!("return js_rt::of_{n}(js_rt::to_num(j_r));")],
        }
    }

    fn param_name(n: &str, i: usize) -> String {
        let n = if n.is_empty() { format!("p{i}") } else { volt_name(n) };
        if n.starts_with("j_") || n == "this" {
            format!("{n}_")
        } else {
            n
        }
    }

    /// a function, constructor or method as Volt, or why it's left out
    fn func(&self, cls: Option<&str>, f: &Func, ctor: bool, seen: &mut BTreeSet<String>) -> Result<String, String> {
        let what = match cls {
            Some(c) => format!("{c}.{}", f.name),
            None => f.name.clone(),
        };
        if f.is_async {
            return Err(format!("{what} (it's async)"));
        }
        let ret = if ctor {
            JT::Obj(cls.unwrap_or_default().to_string())
        } else {
            match &f.ret {
                Some(r) => self.jt(r).ok_or(format!("{what} (its return type)"))?,
                None if f.returns => return Err(format!("{what} (its return type isn't written)")),
                None => JT::Void,
            }
        };
        let (mut params, mut pre, mut args, mut post) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
        for (i, p) in f.params.iter().enumerate() {
            if p.rest || p.name.is_empty() {
                return Err(format!("{what} (a rest or destructured parameter)"));
            }
            if p.ty.is_empty() {
                return Err(format!("{what} (parameter {} has no type)", p.name));
            }
            let mut t = self.jt(&p.ty).ok_or(format!("{what} (parameter {}'s type)", p.name))?;
            // x?: T is T? (absent: undefined)
            if let (true, JT::Prim(pr)) = (p.optional, &t) {
                t = JT::Opt(pr);
            }
            let vn = Self::param_name(&p.name, i);
            let default = match (&p.default, &t) {
                (Some(d), JT::Prim(_)) if d != "null" => format!(" = {d}"),
                (Some(d), JT::Opt(_)) => format!(" = {d}"),
                (None, JT::Opt(_)) if p.optional => " = null".into(),
                _ => String::new(),
            };
            params.push(format!("{vn}: {}{default}", Self::ty_in(&t)));
            let (p0, e, p1) = Self::to_js(&t, &vn);
            pre.extend(p0);
            args.push(e);
            post.extend(p1);
        }
        let vn = if ctor { "new".to_string() } else { volt_name(&f.name) };
        let is_static = ctor || f.is_static;
        if !seen.insert(format!("{vn} {is_static}")) {
            return Err(format!("{what} (another function has its Volt name)"));
        }
        let head = match (cls, is_static) {
            (Some(c), true) => {
                let mut ps = vec![format!("static this: {c}")];
                ps.extend(params);
                format!("attach fn {vn}({}) -> {}", ps.join(", "), Self::ty_out(&ret))
            }
            (Some(c), false) => {
                let mut ps = vec![format!("this: {c}&")];
                ps.extend(params);
                format!("attach fn {vn}({}) -> {}", ps.join(", "), Self::ty_out(&ret))
            }
            (None, _) => format!("fn {vn}({}) -> {}", params.join(", "), Self::ty_out(&ret)),
        };
        let mut l = vec!["val j_x = js_rt::enter();".to_string()];
        l.extend(pre);
        let a = if args.is_empty() {
            "null".to_string()
        } else {
            l.push(format!("val j_a: js_rt::js::JSValueRef[{}] = {{ {} }};", args.len(), args.join(", ")));
            "&j_a[0]".to_string()
        };
        let n = args.len();
        let call = match (cls, ctor, f.is_static) {
            (None, _, _) => format!("js_rt::call(js_rt::get(js_rt::module(), \"{}\"), null, {n}, {a})", f.name),
            (Some(c), true, _) => format!("js_rt::construct(js_rt::get(js_rt::module(), \"{c}\"), {n}, {a})"),
            (Some(c), false, true) => format!("js_rt::call(js_rt::get(js_rt::obj(js_rt::get(js_rt::module(), \"{c}\")), \"{}\"), js_rt::obj(js_rt::get(js_rt::module(), \"{c}\")), {n}, {a})", f.name),
            (Some(c), false, false) => {
                l.push(format!("js_rt::live(this.o.v, \"{}::{c}\");", self.alias));
                format!("js_rt::call(js_rt::get(js_rt::obj(this.o.v), \"{}\"), js_rt::obj(this.o.v), {n}, {a})", f.name)
            }
        };
        l.push(format!("val j_r = {call};"));
        l.extend(post);
        l.extend(Self::result(&ret));
        Ok(func(&head, &l))
    }

    /// a field's or accessor's getter and (when it can be set) setter
    fn prop(&self, c: &str, (name, ty, settable, is_static): &(String, String, bool, bool), taken: &BTreeSet<String>) -> Result<String, String> {
        let what = format!("{c}.{name}");
        let t = self.jt(ty).filter(|t| *t != JT::Void).ok_or(format!("{what} (its type)"))?;
        let vn = volt_name(name);
        if taken.contains(&vn) {
            return Err(format!("{what} (a method has its name)"));
        }
        let (this, target) = if *is_static {
            (format!("static this: {c}"), format!("js_rt::obj(js_rt::get(js_rt::module(), \"{c}\"))"))
        } else {
            (format!("this: {c}&"), "js_rt::obj(this.o.v)".to_string())
        };
        let mut start = vec!["val j_x = js_rt::enter();".to_string()];
        if !is_static {
            start.push(format!("js_rt::live(this.o.v, \"{}::{c}\");", self.alias));
        }
        let mut get = start.clone();
        get.push(format!("val j_r = js_rt::get({target}, \"{name}\");"));
        get.extend(Self::result(&t));
        let mut out = func(&format!("attach fn {vn}({this}) -> {}", Self::ty_out(&t)), &get);
        if *settable && !taken.contains(&format!("set_{vn}")) {
            let (pre, e, _) = Self::to_js(&t, "v");
            let mut set = start;
            set.extend(pre);
            set.push(format!("js_rt::set({target}, \"{name}\", {e});"));
            let _ = write!(out, "\n{}", func(&format!("attach fn set_{vn}({this}, v: {}) -> void", Self::ty_in(&t)), &set));
        }
        Ok(out)
    }
}

fn func(head: &str, lines: &[String]) -> String {
    let mut f = format!("{head} {{\n");
    for x in lines {
        let _ = writeln!(f, "    {x}");
    }
    f.push_str("}\n");
    f
}

fn generate(alias: &str, m: &Module, header: &Path, script: &Path) -> String {
    let mut left = m.left.clone();
    let g = Gen {
        alias,
        enums: m.items.iter().filter_map(|i| if let Item::Enum(n, _) = i { Some(n.clone()) } else { None }).collect(),
        objs: m.items.iter().filter_map(|i| if let Item::Class(c) = i { (c.name != "js_rt").then(|| c.name.clone()) } else { None }).collect(),
    };
    let (mut decls, mut helpers) = (String::new(), String::new());
    let mut seen = BTreeSet::new();
    for item in &m.items {
        match item {
            Item::Enum(n, vals) => {
                let mut body = String::new();
                let mut tag = format!("    fn tag_{n}(x: {alias}::{n}) -> i64 {{\n        match (x) {{\n");
                let mut of = format!("    fn of_{n}(x: f64) -> {alias}::{n} {{\n");
                for (v, k) in vals {
                    let vv = volt_name(v);
                    let _ = writeln!(body, "    {vv} = {k},");
                    let _ = writeln!(tag, "            .{vv} => {{ return {k}; }},");
                    let _ = writeln!(of, "        if (x == {k}.0) {{\n            return {alias}::{n}::{vv};\n        }}");
                }
                tag.push_str("        }\n    }\n");
                let _ = write!(of, "        @panic(std::fmt::format(\"JavaScript gave back a {n} that isn't one: {{}}\", x).as_str());\n    }}\n");
                helpers.push_str(&tag);
                helpers.push_str(&of);
                let _ = write!(decls, "\n// the enum {n}\nenum {n}: i64 {{\n{body}}}\n");
            }
            Item::Class(c) if c.name == "js_rt" => left.push("js_rt (the glue's own name)".into()),
            Item::Class(own) => {
                // what it inherits: its bases' methods, fields and accessors it doesn't have, and
                // a constructor when it writes none
                let mut c = own.clone();
                let mut b = own.base.clone();
                while let Some(base) = b.and_then(|s| m.items.iter().find_map(|i| if let Item::Class(x) = i { (x.name == s).then_some(x) } else { None })) {
                    for f in &base.methods {
                        if !c.methods.iter().any(|x| x.name == f.name) {
                            c.methods.push(f.clone());
                        }
                    }
                    for p in &base.props {
                        if !c.props.iter().any(|x| x.0 == p.0) {
                            c.props.push(p.clone());
                        }
                    }
                    if c.ctor.is_none() {
                        c.ctor = base.ctor.clone();
                    }
                    b = base.base.clone();
                }
                let c = &c;
                let n = &c.name;
                let _ = write!(decls, "\n// the class {n}: a reference to an object (a copy refers to the same one)\nstruct {n} {{\n    o: js_rt::ref = {{}};\n}}\n\nattach fn is_null(this: {n}&) -> bool {{\n    return this.o.v == null;\n}}\n");
                // its bases, as far as the module has them
                let mut b = c.base.clone();
                while let Some(s) = b.filter(|s| g.objs.contains(s)) {
                    let _ = write!(decls, "\n// as a {s}: the same object\nattach fn as_{s}(this: {n}&) -> {s} {{\n    return {{ o: copy this.o }};\n}}\n");
                    b = m.items.iter().find_map(|i| if let Item::Class(x) = i { (x.name == s).then(|| x.base.clone()).flatten() } else { None });
                }
                let mut cs = BTreeSet::new();
                let ctor = c.ctor.clone().unwrap_or(Func { name: "constructor".into(), params: vec![], ret: None, returns: false, is_static: true, is_async: false });
                match g.func(Some(n), &ctor, true, &mut cs) {
                    Ok(t) => {
                        let _ = write!(decls, "\n{t}");
                    }
                    Err(why) => left.push(why),
                }
                let taken: BTreeSet<String> = c.methods.iter().map(|f| volt_name(&f.name)).collect();
                for f in &c.methods {
                    match g.func(Some(n), f, false, &mut cs) {
                        Ok(t) => {
                            let _ = write!(decls, "\n{t}");
                        }
                        Err(why) => left.push(why),
                    }
                }
                for p in &c.props {
                    match g.prop(n, p, &taken) {
                        Ok(t) => {
                            let _ = write!(decls, "\n{t}");
                        }
                        Err(why) => left.push(why),
                    }
                }
            }
            Item::Func(f) => match g.func(None, f, false, &mut seen) {
                Ok(t) => {
                    let _ = write!(decls, "\n{t}");
                }
                Err(why) => left.push(why),
            },
            Item::Const(n, t, v) => match g.jt(t) {
                Some(JT::Prim(p)) => {
                    let _ = write!(decls, "\nval {}: {} = {v};\n", volt_name(n), volt_prim(p));
                }
                _ => left.push(format!("{n} (its type)")),
            },
        }
    }
    let q = |p: &Path| p.display().to_string().replace('\\', "\\\\").replace('"', "\\\"");
    let mut rt = RUNTIME.replace("{JSH}", &q(header)).replace("{SCRIPT}", &q(script));
    rt.push_str(&lists());
    let mut volt = format!("// use js {{ ... }} as {alias}: the module's exports, called through JavaScriptCore (written by bolt import)\n\nnamespace js_rt {{\n{rt}\n{helpers}}}\n");
    volt.push_str(&decls);
    if !left.is_empty() {
        volt.push_str("\n// left out (Volt can't call these):\n");
        for l in &left {
            let _ = writeln!(volt, "//   {l}");
        }
    }
    volt
}

/// js_rt: the engine, the module, references, exceptions, calls, conversions
const RUNTIME: &str = r#"    use { "{JSH}" } as js;

    // the engine's context, made the first time; the module ran in it, its exports an object
    var ctx: js::JSGlobalContextRef = null;
    var module_v: js::JSObjectRef = null;

    // a call's start (JavaScriptCore locks its engine itself)
    struct entered {
        n: i32 = 0;
    }

    fn enter() -> entered {
        if (ctx == null) {
            ctx = js::JSGlobalContextCreate(null);
            val code = std::fs::read_file("{SCRIPT}") catch |e| {
                @panic("JavaScript: can't read the module ({SCRIPT})");
            };
            val s = jsstr(code.as_str());
            var url = std::string::from("{SCRIPT}");
            val u = js::JSStringCreateWithUTF8CString(url.c_str());
            var exc: js::JSValueRef = null;
            val r = js::JSEvaluateScript(ctx, s, null, u, 1, &exc);
            js::JSStringRelease(s);
            js::JSStringRelease(u);
            thrown(exc);
            module_v = obj(r);
            js::JSValueProtect(ctx, module_v);
        }
        return {};
    }

    fn module() -> js::JSObjectRef {
        return module_v;
    }

    // a value a Volt value holds: protected from the collector until it's deleted; a copy refers
    // to the same object
    struct ref {
        v: js::JSValueRef = null;
    }

    attach fn delete(this: ref&) -> void {
        if (this.v != null) {
            js::JSValueUnprotect(ctx, this.v);
            this.v = null;
        }
    }

    attach fn copy(this: ref&) -> ref {
        if (this.v != null) {
            js::JSValueProtect(ctx, this.v);
        }
        return { v: this.v };
    }

    // a result for a Volt value to hold; null and undefined are an empty one
    fn keep(v: js::JSValueRef) -> ref {
        if (is_nothing(v)) {
            return {};
        }
        js::JSValueProtect(ctx, v);
        return { v: v };
    }

    fn live(v: js::JSValueRef, what: str) -> void {
        if (v == null) {
            @panic(std::fmt::format("{} is empty: JavaScript never made it, or gave back null", what).as_str());
        }
    }

    fn is_nothing(v: js::JSValueRef) -> bool {
        return v == null || js::JSValueIsNull(ctx, v) || js::JSValueIsUndefined(ctx, v);
    }

    // an exception: the program stops with its text
    fn thrown(exc: js::JSValueRef) -> void {
        if (exc != null) {
            val m = to_str(exc);
            @panic(m.as_str());
        }
    }

    fn jsstr(s: str) -> js::JSStringRef {
        var n = std::string::from(s);
        return js::JSStringCreateWithUTF8CString(n.c_str());
    }

    fn undefined() -> js::JSValueRef {
        return js::JSValueMakeUndefined(ctx);
    }

    fn obj(v: js::JSValueRef) -> js::JSObjectRef {
        var exc: js::JSValueRef = null;
        val o = js::JSValueToObject(ctx, v, &exc);
        thrown(exc);
        return o;
    }

    fn get(o: js::JSObjectRef, name: str) -> js::JSValueRef {
        val n = jsstr(name);
        var exc: js::JSValueRef = null;
        val r = js::JSObjectGetProperty(ctx, o, n, &exc);
        js::JSStringRelease(n);
        thrown(exc);
        return r;
    }

    fn set(o: js::JSObjectRef, name: str, v: js::JSValueRef) -> void {
        val n = jsstr(name);
        var exc: js::JSValueRef = null;
        js::JSObjectSetProperty(ctx, o, n, v, 0, &exc);
        js::JSStringRelease(n);
        thrown(exc);
    }

    fn call(f: js::JSValueRef, this_: js::JSObjectRef, n: usize, args: js::JSValueRef*) -> js::JSValueRef {
        var exc: js::JSValueRef = null;
        val r = js::JSObjectCallAsFunction(ctx, obj(f), this_, n, args, &exc);
        thrown(exc);
        return r;
    }

    fn construct(c: js::JSValueRef, n: usize, args: js::JSValueRef*) -> js::JSValueRef {
        var exc: js::JSValueRef = null;
        val r = js::JSObjectCallAsConstructor(ctx, obj(c), n, args, &exc);
        thrown(exc);
        return r;
    }

    fn of_obj(v: js::JSValueRef) -> js::JSValueRef {
        if (v == null) {
            return js::JSValueMakeNull(ctx);
        }
        return v;
    }

    fn of_num(x: f64) -> js::JSValueRef {
        return js::JSValueMakeNumber(ctx, x);
    }

    fn of_bool(x: bool) -> js::JSValueRef {
        return js::JSValueMakeBoolean(ctx, x);
    }

    fn of_str(s: str) -> js::JSValueRef {
        val j = jsstr(s);
        val v = js::JSValueMakeString(ctx, j);
        js::JSStringRelease(j);
        return v;
    }

    fn to_num(v: js::JSValueRef) -> f64 {
        var exc: js::JSValueRef = null;
        val r = js::JSValueToNumber(ctx, v, &exc);
        thrown(exc);
        return r;
    }

    fn to_bool(v: js::JSValueRef) -> bool {
        return js::JSValueToBoolean(ctx, v);
    }

    fn to_str(v: js::JSValueRef) -> std::string {
        var exc: js::JSValueRef = null;
        val s = js::JSValueToStringCopy(ctx, v, &exc);
        if (exc != null) {
            return std::string::from("a JavaScript exception");
        }
        val cap = js::JSStringGetMaximumUTF8CStringSize(s);
        var buf: std::vec<u8> = {};
        for (i) in 0..cap {
            buf.push(0) catch @panic("out of memory");
        }
        val n = js::JSStringGetUTF8CString(s, @cast<cstr>(buf.items().ptr), cap);
        js::JSStringRelease(s);
        if (n <= 1) {
            return std::string::from("");
        }
        return std::string::from(@cast<str>(buf.items()[0..n - 1]));
    }

    fn array(xs: js::JSValueRef[..]) -> js::JSValueRef {
        var exc: js::JSValueRef = null;
        var first: js::JSValueRef* = null;
        if (xs.len > 0) {
            first = @cast<js::JSValueRef*>(xs.ptr);
        }
        val a = js::JSObjectMakeArray(ctx, xs.len, first, &exc);
        thrown(exc);
        return a;
    }

    fn length(v: js::JSValueRef) -> usize {
        val n = to_num(get(obj(v), "length"));
        return @cast<usize>(n);
    }

    fn at(v: js::JSValueRef, i: usize) -> js::JSValueRef {
        var exc: js::JSValueRef = null;
        val r = js::JSObjectGetPropertyAtIndex(ctx, obj(v), @cast<u32>(i), &exc);
        thrown(exc);
        return r;
    }
"#;

/// js_rt's arrays and optionals, for each element type
fn lists() -> String {
    let mut s = String::new();
    for (p, vt, ot) in [("num", "f64", "f64"), ("bool", "bool", "bool"), ("str", "str", "std::string")] {
        let _ = write!(
            s,
            "    fn of_{p}s(xs: {vt}[..]) -> js::JSValueRef {{\n        var vs: std::vec<js::JSValueRef> = {{}};\n        for (x) in xs {{\n            vs.push(of_{p}(x)) catch @panic(\"out of memory\");\n        }}\n        return array(vs.items());\n    }}\n    fn to_{p}s(v: js::JSValueRef) -> std::vec<{ot}> {{\n        var out: std::vec<{ot}> = {{}};\n        if (is_nothing(v)) {{\n            return out;\n        }}\n        for (i) in 0..length(v) {{\n            out.push(to_{p}(at(v, i))) catch @panic(\"out of memory\");\n        }}\n        return out;\n    }}\n    fn of_opt_{p}(x: {vt}?) -> js::JSValueRef {{\n        if (x) {{\n            return of_{p}(x);\n        }}\n        return undefined();\n    }}\n"
        );
        if p != "str" {
            // what changed comes back, element by element (an argument left alone may be a val)
            let _ = write!(
                s,
                "    fn back_{p}s(a: js::JSValueRef, xs: {vt}[..]) -> void {{\n        if (length(a) != xs.len) {{\n            return;\n        }}\n        val m = @slice(@cast<{vt}*>(xs.ptr), xs.len);\n        for (i) in 0..xs.len {{\n            val x = to_{p}(at(a, i));\n            if (m[i] != x) {{\n                m[i] = x;\n            }}\n        }}\n    }}\n"
            );
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn import_js_parse() {
        let src = "import type { X } from './x';\n// a comment\nexport const LIMIT = 10;\nexport const NAME: string = \"geo\";\nexport enum Color { Red, Green = 5, Blue }\nexport function add(a: number, b: number = 2): number { return a + b; }\nexport function find(xs: number[], x: number): number | null { return null; }\nexport function noted(x: number) { return x; }\nexport class Shape extends Base {\n  name: string;\n  readonly sides: number[] = [];\n  private secret = 1;\n  static made: number = 0;\n  constructor(name: string, public extra?: number) { super(); this.name = name; }\n  perimeter(): number { return 0; }\n  get count(): number { return 0; }\n  set count(v: number) {}\n  static origin(): Shape { return new Shape('o'); }\n  async later(): Promise<void> {}\n}\nfunction hidden() {}\nexport default 3;\n";
        let m = parse(src);
        let names: Vec<&str> = m.items.iter().map(|i| i.name()).collect();
        assert_eq!(names, ["LIMIT", "NAME", "Color", "add", "find", "noted", "Shape"]);
        assert_eq!(m.items[2], Item::Enum("Color".into(), vec![("Red".into(), 0), ("Green".into(), 5), ("Blue".into(), 6)]));
        let Item::Func(add) = &m.items[3] else { panic!() };
        assert_eq!((add.params[1].default.as_deref(), add.ret.as_deref()), (Some("2.0"), Some("number")));
        let Item::Func(noted) = &m.items[5] else { panic!() };
        assert!(noted.ret.is_none() && noted.returns);
        let Item::Class(c) = &m.items[6] else { panic!() };
        assert_eq!(c.base.as_deref(), Some("Base"));
        assert_eq!(c.props, [("name".to_string(), "string".to_string(), true, false), ("sides".to_string(), "number[]".to_string(), false, false), ("made".to_string(), "number".to_string(), true, true), ("count".to_string(), "number".to_string(), true, false)]);
        assert_eq!(c.methods.iter().map(|f| (f.name.as_str(), f.is_static, f.is_async)).collect::<Vec<_>>(), [("perimeter", false, false), ("origin", true, false), ("later", false, true)]);
        assert_eq!(c.ctor.as_ref().unwrap().params.len(), 2);
        assert_eq!(m.left, ["the default export (only named exports reach Volt)"]);
        let out = rewrite(src, &m.edits).unwrap();
        assert!(out.contains("const Color = Object.freeze({ Red: 0, Green: 5, Blue: 6 });") && !out.contains("export") && !out.contains("import"), "{out}");
        let g = Gen { alias: "geo", enums: ["Color".to_string()].into(), objs: ["Shape".to_string()].into() };
        assert_eq!(g.jt("number | undefined"), Some(JT::Opt("num")));
        assert_eq!(g.jt("Array<string>"), Some(JT::List("str")));
        assert_eq!(g.jt("Shape | null"), Some(JT::Obj("Shape".into())));
        assert_eq!(g.jt("Promise<void>"), None);
    }
}
