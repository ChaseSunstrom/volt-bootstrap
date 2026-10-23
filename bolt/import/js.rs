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
//   set_x(v); a numeric enum -> a Volt enum; exported constants of those types -> vals;
//   an interface or a type alias of an object type -> a Volt struct, copied (x?: T is T?);
//   a generic function or class -> a Volt generic, each value converted by its type (js_rt's
//   of_any and from_js); a callback parameter ((x: number) => number) -> a Volt fn value
//   JavaScript can call and keep; an async function (or one giving a Promise<T>) -> its settled
//   value (there's no event loop: what it awaits must settle as the call returns)
//   a thrown exception or a rejection -> the program stops with its text
use super::{arg_path, fresh, save, stamp, volt_name, Made, Req};
use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
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
    let out = super::canonicalize(&r.out).unwrap_or_else(|_| r.out.clone());

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
    let mut names: Vec<String> = m.items.iter().filter(|i| i.is_value()).map(|i| i.name().to_string()).collect();
    names.push(format!("__volt_settle: {SETTLE}"));
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

/// a promise's outcome, read once JavaScriptCore has run what's queued (it does as the call
/// attaching then() returns)
const SETTLE: &str = "function (p) { var s = { done: false, ok: false, v: undefined }; Promise.resolve(p).then(function (v) { s.done = true; s.ok = true; s.v = v; }, function (e) { s.done = true; s.v = e; }); return s; }";

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
    /// its type parameters (<T, U>)
    tparams: Vec<String>,
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
    tparams: Vec<String>,
    base: Option<String>,
    ctor: Option<Func>,
    methods: Vec<Func>,
    /// fields and accessors: name, type, settable, static
    props: Vec<(String, String, bool, bool)>,
}

/// an interface, or a type alias of an object type: a Volt struct
#[derive(Clone, Debug, Default, PartialEq)]
struct Struct {
    name: String,
    bases: Vec<String>,
    /// name, type, optional
    fields: Vec<(String, String, bool)>,
    /// why it isn't plain data (a method, an index signature, type parameters)
    why: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
enum Item {
    Func(Func),
    Class(Class),
    Enum(String, Vec<(String, i64)>),
    Const(String, String, String),
    Struct(Struct),
    /// type X = T (not an object type): X is T
    Alias(String, String),
}

impl Item {
    fn name(&self) -> &str {
        match self {
            Item::Func(f) => &f.name,
            Item::Class(c) => &c.name,
            Item::Struct(s) => &s.name,
            Item::Enum(n, _) | Item::Const(n, _, _) | Item::Alias(n, _) => n,
        }
    }

    /// whether it's a value the module exports (not only a type)
    fn is_value(&self) -> bool {
        !matches!(self, Item::Struct(_) | Item::Alias(..))
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
    /// whether token k starts on a later line than the one before it
    fn new_line(&self, k: usize) -> bool {
        let i = self.i + k;
        i > 0 && i < self.toks.len() && self.src[self.toks[i - 1].end..self.toks[i].at].contains('\n')
    }
    /// a type's text, up to one of stops outside brackets (=> in a function type isn't a stop)
    fn ty(&mut self, stops: &[char]) -> String {
        self.ty_with(stops, |_| false)
    }
    /// ty, stopping too where brk says (outside brackets)
    fn ty_with(&mut self, stops: &[char], brk: impl Fn(&Self) -> bool) -> String {
        let start = self.i;
        let mut depth = 0i32;
        while let Some(t) = self.peek(0) {
            match t {
                // (the = of a function type's => isn't one)
                T::P(c) if depth == 0 && stops.contains(c) && !(*c == '=' && self.is_p(1, '>')) => break,
                _ if depth == 0 && self.i > start && brk(self) => break,
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
    /// an object type member's type: up to ; , } or the next member, on a line of its own
    fn member_ty(&mut self) -> String {
        self.ty_with(&[';', ',', '}'], |p| p.new_line(0) && (p.is_id(0, "readonly") || matches!(p.peek(0), Some(T::Id(_))) && matches!(p.peek(1), Some(T::P(':' | '?' | '(')))))
    }
    /// a type parameter list's names (<T, U extends X = Y>), and past it
    fn tparams(&mut self) -> Vec<String> {
        let mut out = Vec::new();
        if !self.is_p(0, '<') {
            return out;
        }
        let mut depth = 0;
        while let Some(t) = self.peek(0).cloned() {
            match t {
                T::P('(' | '[' | '{' | '<') => depth += 1,
                T::P(')' | ']' | '}') => depth -= 1,
                T::P('>') if self.toks[self.i - 1].t != T::P('=') => depth -= 1,
                T::Id(x) if depth == 1 && matches!(self.toks[self.i - 1].t, T::P('<' | ',')) => out.push(x),
                _ => {}
            }
            self.i += 1;
            if depth == 0 {
                break;
            }
        }
        out
    }
    /// an object type's members ({ x: number; y?: string }): its fields, or why it isn't plain data
    fn members(&mut self) -> (Vec<(String, String, bool)>, Option<String>) {
        let (mut fields, mut why) = (Vec::new(), None);
        self.i += 1; // {
        while !self.is_p(0, '}') && self.peek(0).is_some() {
            if self.is_p(0, ';') || self.is_p(0, ',') {
                self.i += 1;
                continue;
            }
            if self.is_id(0, "readonly") && matches!(self.peek(1), Some(T::Id(_) | T::Str(_) | T::P('['))) {
                self.i += 1;
            }
            if self.is_p(0, '[') {
                why.get_or_insert_with(|| "an index signature".to_string());
                self.skip_group();
            } else {
                let name = match self.peek(0) {
                    Some(T::Id(x)) => x.clone(),
                    _ => String::new(),
                };
                self.i += 1;
                let optional = self.is_p(0, '?');
                if optional {
                    self.i += 1;
                }
                if self.is_p(0, '(') || self.is_p(0, '<') {
                    why.get_or_insert_with(|| format!("its method {name}"));
                    self.tparams();
                    self.skip_group();
                } else if name.is_empty() {
                    why.get_or_insert_with(|| "a member that isn't a name and a type".to_string());
                } else if self.is_p(0, ':') {
                    self.i += 1;
                    let ty = self.member_ty();
                    fields.push((name, ty, optional));
                    continue;
                }
            }
            // past the rest of the member
            if self.is_p(0, ':') {
                self.i += 1;
                self.member_ty();
            }
        }
        self.i += 1;
        (fields, why)
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

/// whether an interface or a type alias starts here
fn is_type_decl(p: &P) -> bool {
    (p.is_id(0, "interface") && matches!(p.peek(1), Some(T::Id(_)))) || (p.is_id(0, "type") && matches!(p.peek(1), Some(T::Id(_))) && matches!(p.peek(2), Some(T::P('=' | '<'))))
}

/// an interface or a type alias (exported or not: an exported function may name either): a struct
/// when it's an object type, else an alias
fn type_decl(p: &mut P, m: &mut Module) {
    let interface = p.is_id(0, "interface");
    p.i += 1;
    let name = p.id().unwrap_or_default();
    let generic = !p.tparams().is_empty();
    let mut s = Struct { name: name.clone(), ..Struct::default() };
    if interface {
        while !p.is_p(0, '{') && p.peek(0).is_some() {
            let base = p.is_id(0, "extends") || p.is_p(0, ',');
            p.i += 1;
            if let Some(b) = base.then(|| p.id()).flatten() {
                s.bases.push(b);
                if p.is_p(0, '<') {
                    s.why.get_or_insert_with(|| "its base is generic".to_string());
                    p.skip_group();
                }
            }
        }
    } else {
        p.i += 1; // =
        if !p.is_p(0, '{') {
            let stmt = ["export", "function", "const", "let", "var", "class", "interface", "type", "enum", "import", "declare", "async", "abstract", "namespace"];
            let t = p.ty_with(&[';'], |p| p.new_line(0) && matches!(p.peek(0), Some(T::Id(x)) if stmt.contains(&x.as_str())));
            if !generic {
                m.items.push(Item::Alias(name, t));
            }
            if p.is_p(0, ';') {
                p.i += 1;
            }
            return;
        }
    }
    let (fields, why) = p.members();
    s.fields = fields;
    if let Some(w) = why {
        s.why.get_or_insert(w);
    }
    if generic {
        s.why = Some("it's generic".into());
    }
    if !interface && (p.is_p(0, '&') || p.is_p(0, '|') || p.is_p(0, '[')) {
        s.why = Some("it isn't one object type".into());
        p.ty(&[';']);
    }
    if p.is_p(0, ';') {
        p.i += 1;
    }
    m.items.push(Item::Struct(s));
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
            if is_type_decl(&p) {
                type_decl(&mut p, &mut m);
                continue;
            }
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
            let tparams = p.tparams();
            let params = p.params();
            let (ret, returns) = p.ret_and_body();
            m.items.push(Item::Func(Func { name, tparams, params, ret, returns, is_static: true, is_async }));
        } else if p.is_id(0, "class") || (p.is_id(0, "abstract") && p.is_id(1, "class")) {
            if p.is_id(0, "abstract") {
                p.i += 1;
            }
            p.i += 1;
            let name = p.id().unwrap_or_default();
            let mut c = Class { name, tparams: p.tparams(), ..Class::default() };
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
        } else if is_type_decl(&p) {
            type_decl(&mut p, &mut m);
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
            let tparams = p.tparams();
            let params = p.params();
            let (ret, returns) = p.ret_and_body();
            if private {
                continue;
            }
            if name == "constructor" {
                c.ctor = Some(Func { name, tparams: vec![], params, ret: None, returns: false, is_static: true, is_async: false });
            } else if let Some(a) = accessor {
                // get x(): T and set x(v: T)
                let ty = if a == "get" { ret.unwrap_or_default() } else { params.first().map(|x| x.ty.clone()).unwrap_or_default() };
                match c.props.iter_mut().find(|x| x.0 == name && x.3 == is_static) {
                    Some(x) => x.2 |= a == "set",
                    None => c.props.push((name, ty, a == "set", is_static)),
                }
            } else {
                c.methods.push(Func { name, tparams, params, ret, returns, is_static, is_async });
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
    /// a class (a generic one's own type, Box<T>, only as its constructor's result)
    Obj(String),
    Enum(String),
    /// an interface or object type: a struct
    Struct(String),
    /// a type parameter
    Gen(String),
    /// an array of classes, enums, object types or a type parameter
    Many(Box<JT>),
    /// a callback, (a: A) => R: a parameter only
    Fn(Vec<JT>, Box<JT>),
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

/// s split at sep outside brackets (the > of => doesn't close one)
fn split_top(s: &str, sep: u8) -> Vec<&str> {
    let b = s.as_bytes();
    let (mut out, mut depth, mut from) = (Vec::new(), 0i32, 0);
    for (i, &c) in b.iter().enumerate() {
        match c {
            b'(' | b'[' | b'{' | b'<' => depth += 1,
            b')' | b']' | b'}' => depth -= 1,
            b'>' if i == 0 || b[i - 1] != b'=' => depth -= 1,
            _ if depth == 0 && c == sep => {
                out.push(&s[from..i]);
                from = i + 1;
            }
            _ => {}
        }
    }
    out.push(&s[from..]);
    out
}

/// type parameters as Volt declares them (<T: type, U: type> on a line of its own), or nothing
fn generics(tps: &[String]) -> String {
    if tps.is_empty() {
        return String::new();
    }
    format!("<{}>\n", tps.iter().map(|t| format!("{t}: type")).collect::<Vec<_>>().join(", "))
}

/// a class's Volt type (Box<T> for a generic one)
fn class_ty(c: &str, tps: &[String]) -> String {
    if tps.is_empty() {
        c.to_string()
    } else {
        format!("{c}<{}>", tps.join(", "))
    }
}

/// an object type's fields, its bases' first (a field it writes again replaces a base's)
fn fields_of(all: &[&Struct], s: &Struct, depth: usize) -> Result<Vec<(String, String, bool)>, String> {
    if let Some(w) = &s.why {
        return Err(w.clone());
    }
    let mut out: Vec<(String, String, bool)> = Vec::new();
    for b in &s.bases {
        let base = all.iter().find(|x| x.name == *b).filter(|_| depth < 16).ok_or(format!("its base {b} isn't an object type here"))?;
        for f in fields_of(all, base, depth + 1)? {
            out.retain(|x| x.0 != f.0);
            out.push(f);
        }
    }
    for f in &s.fields {
        out.retain(|x| x.0 != f.0);
        out.push(f.clone());
    }
    Ok(out)
}

/// whether object type n holds x by value (through its fields, and theirs)
fn holds(held: &BTreeMap<String, Vec<JT>>, n: &str, x: &str, depth: usize) -> bool {
    depth < 32 && held.get(n).is_some_and(|ts| ts.iter().any(|t| matches!(t, JT::Struct(s) if s == x || holds(held, s, x, depth + 1))))
}

struct Gen<'a> {
    alias: &'a str,
    enums: BTreeSet<String>,
    /// the classes a type can name (not generic ones)
    objs: BTreeSet<String>,
    /// the object types Volt holds as structs
    structs: BTreeSet<String>,
    aliases: BTreeMap<String, String>,
    /// the callbacks' Volt types and their js_rt helpers (of_fn_K, K its place)
    fns: RefCell<Vec<(String, String)>>,
}

impl Gen<'_> {
    /// the type s names, where tps are the type parameters in scope
    fn jt(&self, s: &str, tps: &[String]) -> Option<JT> {
        self.jt_at(s, tps, 0)
    }

    fn jt_at(&self, s: &str, tps: &[String], depth: usize) -> Option<JT> {
        let s = s.trim();
        if s.starts_with('(') {
            return self.fn_jt(s, tps);
        }
        let parts: Vec<&str> = split_top(s, b'|').into_iter().map(str::trim).filter(|x| !x.is_empty()).collect();
        let nullable = parts.iter().any(|x| *x == "null" || *x == "undefined");
        let rest: Vec<&str> = parts.iter().copied().filter(|x| *x != "null" && *x != "undefined").collect();
        if rest.is_empty() {
            return (s == "void" || s == "undefined").then_some(JT::Void);
        }
        let [one] = rest.as_slice() else { return None };
        let one = one.strip_prefix("readonly ").unwrap_or(one);
        if let Some(e) = one.strip_suffix("[]").or_else(|| one.strip_prefix("Array<").and_then(|x| x.strip_suffix('>'))) {
            if nullable {
                return None;
            }
            if let Some(p) = prim(e.trim()) {
                return Some(JT::List(p));
            }
            return match self.jt_at(e, tps, depth + 1)? {
                t @ (JT::Obj(_) | JT::Enum(_) | JT::Struct(_) | JT::Gen(_)) => Some(JT::Many(Box::new(t))),
                _ => None,
            };
        }
        if let Some(p) = prim(one) {
            return Some(if nullable { JT::Opt(p) } else { JT::Prim(p) });
        }
        if one == "void" {
            return Some(JT::Void);
        }
        if tps.iter().any(|t| t == one) {
            return (!nullable).then(|| JT::Gen(one.to_string()));
        }
        // an alias: its type (with null, when this adds it)
        if let Some(a) = self.aliases.get(one).filter(|_| depth < 16) {
            // (a callback's can't be: Cb | null would read as one giving number | null)
            if nullable && a.trim_start().starts_with('(') {
                return None;
            }
            return self.jt_at(&if nullable { format!("{a} | null") } else { a.clone() }, tps, depth + 1);
        }
        if self.enums.contains(one) && !nullable {
            return Some(JT::Enum(one.to_string()));
        }
        if self.structs.contains(one) && !nullable {
            return Some(JT::Struct(one.to_string()));
        }
        self.objs.contains(one).then(|| JT::Obj(one.to_string()))
    }

    /// a callback's type, (a: A, b: B) => R, of values that cross one at a time (no arrays, no
    /// type parameters, no optional or rest parameters)
    fn fn_jt(&self, s: &str, tps: &[String]) -> Option<JT> {
        let b = s.as_bytes();
        let (mut depth, mut close) = (0i32, None);
        for (i, &c) in b.iter().enumerate() {
            match c {
                b'(' | b'[' | b'{' | b'<' => depth += 1,
                b')' | b']' | b'}' => depth -= 1,
                b'>' if i == 0 || b[i - 1] != b'=' => depth -= 1,
                _ => {}
            }
            if depth == 0 {
                close = Some(i);
                break;
            }
        }
        let close = close?;
        let ret = s[close + 1..].trim().strip_prefix("=>")?;
        let one = |t: &JT| matches!(t, JT::Prim(_) | JT::Opt("num" | "bool") | JT::Obj(_) | JT::Struct(_) | JT::Enum(_));
        let mut ps = Vec::new();
        for p in split_top(&s[1..close], b',') {
            if p.trim().is_empty() {
                continue;
            }
            let (name, ty) = p.split_once(':')?;
            if name.contains("...") || name.trim_end().ends_with('?') {
                return None;
            }
            ps.push(self.jt(ty, tps).filter(one)?);
        }
        let r = self.jt(ret, tps).filter(|t| *t == JT::Void || one(t))?;
        Some(JT::Fn(ps, Box::new(r)))
    }

    /// a struct field's Volt type: a value, or x?: T as T? (a number, boolean or string), an empty
    /// handle or an empty array
    fn field_jt(&self, t: &str, optional: bool) -> Option<JT> {
        match (self.jt(t, &[])?, optional) {
            (JT::Prim(p), true) => Some(JT::Opt(p)),
            (JT::Void | JT::Gen(_) | JT::Fn(..), _) | (JT::Enum(_) | JT::Struct(_), true) => None,
            (j, _) => Some(j),
        }
    }

    /// the object types Volt holds as structs, each one's fields (its bases' first) as Volt types;
    /// the rest go to left, with why
    fn plain_structs(&mut self, m: &Module, left: &mut Vec<String>) -> BTreeMap<String, Vec<(String, JT)>> {
        let all: Vec<&Struct> = m.items.iter().filter_map(|i| if let Item::Struct(s) = i { Some(s) } else { None }).collect();
        let mut raw = BTreeMap::new();
        for s in &all {
            if self.objs.contains(&s.name) || self.enums.contains(&s.name) || s.name == "js_rt" || raw.contains_key(&s.name) {
                left.push(format!("{} (an object type another declaration names)", s.name));
                continue;
            }
            match fields_of(&all, s, 0) {
                Ok(fs) => {
                    raw.insert(s.name.clone(), fs);
                }
                Err(why) => left.push(format!("{} ({why})", s.name)),
            }
        }
        // one with a field Volt can't hold goes (and then any naming it), as does one holding itself
        loop {
            self.structs = raw.keys().cloned().collect();
            let mut out = BTreeMap::new();
            let mut bad = None;
            'all: for (n, fs) in &raw {
                let mut ts = Vec::new();
                for (f, t, opt) in fs {
                    match self.field_jt(t, *opt) {
                        Some(j) => ts.push((f.clone(), j)),
                        None => {
                            bad = Some((n.clone(), format!("{n} (field {f}'s type)")));
                            break 'all;
                        }
                    }
                }
                out.insert(n.clone(), ts);
            }
            if bad.is_none() {
                let held: BTreeMap<String, Vec<JT>> = out.iter().map(|(n, ts): (&String, &Vec<(String, JT)>)| (n.clone(), ts.iter().map(|x| x.1.clone()).collect())).collect();
                bad = out.keys().find(|n| holds(&held, n, n, 0)).map(|n| (n.clone(), format!("{n} (it holds itself)")));
            }
            match bad {
                Some((n, why)) => {
                    raw.remove(&n);
                    left.push(why);
                }
                None => return out,
            }
        }
    }

    /// an object type's struct, and its js_rt converters (an object of its fields; a field the
    /// object doesn't have is undefined, which an optional field takes as null)
    fn struct_glue(&self, n: &str, fs: &[(String, JT)]) -> (String, String) {
        let alias = self.alias;
        let mut body = String::new();
        let mut of = format!("    fn of_any(x: {alias}::{n}&) -> js::JSValueRef {{\n        val o = js::JSObjectMake(ctx, null, null);\n");
        let mut from = format!("    fn from_js(v: js::JSValueRef) -> {alias}::{n} {{\n        val o = obj(v);\n");
        let mut lit = Vec::new();
        for (f, t) in fs {
            let vf = volt_name(f);
            let _ = writeln!(body, "    {vf}: {}{};", Self::ty_out(t), if matches!(t, JT::Opt(_)) { " = null" } else { "" });
            match t {
                JT::Opt(p) => {
                    let _ = write!(of, "        if (x.{vf}) {{\n            set(o, \"{f}\", of_any(&x.{vf}));\n        }}\n");
                    let _ = writeln!(from, "        val f_{vf} = to_opt<{}>(get(o, \"{f}\"));", Self::ty_out(&JT::Prim(p)));
                }
                JT::List(_) | JT::Many(_) => {
                    let e = match t {
                        JT::List(p) => Self::ty_out(&JT::Prim(p)),
                        JT::Many(e) => self.ty_rt(e),
                        _ => String::new(),
                    };
                    let _ = writeln!(of, "        set(o, \"{f}\", of_list(x.{vf}.items()));");
                    let _ = writeln!(from, "        val f_{vf} = to_list<{e}>(get(o, \"{f}\"));");
                }
                _ => {
                    let _ = writeln!(of, "        set(o, \"{f}\", of_any(&x.{vf}));");
                    let _ = writeln!(from, "        val f_{vf}: {} = from_js(get(o, \"{f}\"));", self.ty_rt(t));
                }
            }
            lit.push(format!("{vf}: f_{vf}"));
        }
        of.push_str("        return o;\n    }\n");
        let _ = write!(from, "        return {{ {} }};\n    }}\n", lit.join(", "));
        (format!("\n// the object type {n}: a struct, copied to and from a JavaScript object\nstruct {n} {{\n{body}}}\n"), of + &from)
    }

    fn ty_in(t: &JT) -> String {
        match t {
            JT::Prim(p) => volt_prim(p).into(),
            JT::List(p) => format!("{}[..]", volt_prim(p)),
            JT::Opt(p) => format!("{}?", volt_prim(p)),
            JT::Obj(n) => format!("{n}&"),
            JT::Enum(n) | JT::Struct(n) | JT::Gen(n) => n.clone(),
            JT::Many(e) => format!("{}[..]", Self::ty_out(e)),
            JT::Fn(ps, r) => Self::fn_ty(ps, r, &Self::ty_out),
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
            JT::Many(e) => format!("std::vec<{}>", Self::ty_out(e)),
            t => Self::ty_in(t),
        }
    }

    /// ty_out as js_rt writes it (the import's own types under its name)
    fn ty_rt(&self, t: &JT) -> String {
        match t {
            JT::Obj(n) | JT::Enum(n) | JT::Struct(n) => format!("{}::{n}", self.alias),
            JT::Many(e) => format!("std::vec<{}>", self.ty_rt(e)),
            t => Self::ty_out(t),
        }
    }

    /// a callback's Volt type, fn(A, B) -> R (text in as str, out as std::string), its types
    /// written by name
    fn fn_ty(ps: &[JT], r: &JT, name: &dyn Fn(&JT) -> String) -> String {
        let a: Vec<String> = ps.iter().map(|p| if *p == JT::Prim("str") { "str".to_string() } else { name(p) }).collect();
        format!("fn({}) -> {}", a.join(", "), name(r))
    }

    /// the js_rt helper making a Volt fn value of this type a JavaScript function: of_fn_K, made
    /// once per type (a JSClass whose objects hold the closure: callAsFunction calls it, finalize
    /// frees it)
    fn callback(&self, ps: &[JT], r: &JT) -> String {
        let ft = Self::fn_ty(ps, r, &|t: &JT| self.ty_rt(t));
        let mut fns = self.fns.borrow_mut();
        if let Some(k) = fns.iter().position(|(t, _)| *t == ft) {
            return format!("of_fn_{k}");
        }
        let k = fns.len();
        let (mut take, mut args) = (String::new(), Vec::new());
        for (i, p) in ps.iter().enumerate() {
            let a = format!("arg(args, n, {i})");
            match p {
                JT::Prim("str") => {
                    let _ = writeln!(take, "        val a{i} = to_str({a});");
                    args.push(format!("a{i}.as_str()"));
                }
                JT::Prim(_) | JT::Opt(_) => {
                    let _ = writeln!(take, "        val a{i}: {} = {}({a});", Self::ty_out(p), if matches!(p, JT::Opt(_)) { format!("to_opt<{}>", Self::ty_out(&JT::Prim(if *p == JT::Opt("num") { "num" } else { "bool" }))) } else { "from_js".into() });
                    args.push(format!("a{i}"));
                }
                p => {
                    let _ = writeln!(take, "        val a{i}: {} = from_js({a});", self.ty_rt(p));
                    args.push(format!("move a{i}"));
                }
            }
        }
        let call = format!("(*fp)({})", args.join(", "));
        let give = match r {
            JT::Void => format!("{call};\n        return undefined();"),
            JT::Opt(o) => format!("return of_opt_{o}({call});"),
            _ => format!("val r = {call};\n        return of_any(&r);"),
        };
        let code = format!(
            "\n    // a Volt {ft} as a JavaScript function: an object of a class whose call runs it (the\n    // closure is freed with the object)\n    var cls_{k}: js::JSClassRef = null;\n\n    extern \"C\" fn call_{k}(c: js::JSContextRef, f: js::JSObjectRef, t: js::JSObjectRef, n: usize, args: js::JSValueRef*, exc: js::JSValueRef*) -> js::JSValueRef {{\n        val fp = @cast<({ft})*>(js::JSObjectGetPrivate(f));\n{take}        {give}\n    }}\n\n    extern \"C\" fn drop_{k}(o: js::JSObjectRef) -> void {{\n        val p = @cast<({ft})*>(js::JSObjectGetPrivate(o));\n        val f = @read(p);\n        val a: std::mem::default_allocator = {{}};\n        a.free<({ft})>(p);\n    }}\n\n    fn of_fn_{k}(f: {ft}) -> js::JSValueRef {{\n        if (cls_{k} == null) {{\n            var d: js::JSClassDefinition = {{}};\n            d.className = \"VoltFn\";\n            d.callAsFunction = call_{k};\n            d.finalize = drop_{k};\n            cls_{k} = js::JSClassCreate(&d);\n        }}\n        val a: std::mem::default_allocator = {{}};\n        val p: ({ft})* = a.malloc<({ft})>() catch @panic(\"out of memory\");\n        @write(p, move f);\n        return js::JSObjectMake(ctx, cls_{k}, @cast<void*>(p));\n    }}\n"
        );
        fns.push((ft, code));
        format!("of_fn_{k}")
    }

    /// Volt value v as a JavaScript value (statements before, the value, statements after)
    fn to_js(&self, t: &JT, v: &str) -> (Vec<String>, String, Vec<String>) {
        match t {
            JT::Prim(p) => (vec![], format!("js_rt::of_{p}({v})"), vec![]),
            JT::List("str") => (vec![], format!("js_rt::of_strs({v})"), vec![]),
            // the array's numbers (or booleans) come back
            JT::List(p) => (vec![format!("val {v}_a = js_rt::of_{p}s({v});")], format!("{v}_a"), vec![format!("js_rt::back_{p}s({v}_a, {v});")]),
            JT::Opt(p) => (vec![], format!("js_rt::of_opt_{p}({v})"), vec![]),
            JT::Obj(_) => (vec![], format!("js_rt::of_obj({v}.o.v)"), vec![]),
            JT::Enum(n) => (vec![], format!("js_rt::of_num(@cast<f64>(js_rt::tag_{n}({v})))"), vec![]),
            JT::Void => (vec![], "js_rt::undefined()".into(), vec![]),
            JT::Struct(_) | JT::Gen(_) => (vec![], format!("js_rt::of_any(&{v})"), vec![]),
            JT::Many(_) => (vec![], format!("js_rt::of_list({v})"), vec![]),
            // the closure moves into a JavaScript function
            JT::Fn(ps, r) => (vec![], format!("js_rt::{}(move {v})", self.callback(ps, r)), vec![]),
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
            JT::Struct(_) | JT::Gen(_) => vec!["return js_rt::from_js(j_r);".into()],
            JT::Many(e) => vec![format!("return js_rt::to_list<{}>(j_r);", Self::ty_out(e))],
            JT::Fn(..) => vec![],
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
    fn func(&self, cls: Option<(&str, &[String])>, f: &Func, ctor: bool, seen: &mut BTreeSet<String>) -> Result<String, String> {
        let what = match cls {
            Some((c, _)) => format!("{c}.{}", f.name),
            None => f.name.clone(),
        };
        let mut tps: Vec<String> = cls.map_or(Vec::new(), |(_, t)| t.to_vec());
        if let Some(t) = f.tparams.iter().find(|t| tps.contains(t)) {
            return Err(format!("{what} (its type parameter {t} is the class's too)"));
        }
        tps.extend(f.tparams.iter().cloned());
        // a Promise<T>: the call gives what it settles to
        let (written, settles) = match f.ret.as_deref().map(str::trim) {
            Some(r) if r.starts_with("Promise<") && r.ends_with('>') => (Some(&r["Promise<".len()..r.len() - 1]), true),
            r => (r, f.is_async),
        };
        let cty = cls.map(|(c, t)| class_ty(c, t));
        let ret = if ctor {
            JT::Obj(cty.clone().unwrap_or_default())
        } else {
            match written {
                Some(r) => self.jt(r, &tps).filter(|t| !matches!(t, JT::Fn(..))).ok_or(format!("{what} (its return type)"))?,
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
            let mut t = self.jt(&p.ty, &tps).ok_or(format!("{what} (parameter {}'s type)", p.name))?;
            // x?: T is T? (absent: undefined)
            if let (true, JT::Prim(pr)) = (p.optional, &t) {
                t = JT::Opt(pr);
            }
            if p.optional && matches!(t, JT::Fn(..) | JT::Struct(_) | JT::Gen(_) | JT::Many(_)) {
                return Err(format!("{what} (parameter {} is optional: a callback, object type or type parameter can't be absent)", p.name));
            }
            let vn = Self::param_name(&p.name, i);
            let default = match (&p.default, &t) {
                (Some(d), JT::Prim(_)) if d != "null" => format!(" = {d}"),
                (Some(d), JT::Opt(_)) => format!(" = {d}"),
                (None, JT::Opt(_)) if p.optional => " = null".into(),
                _ => String::new(),
            };
            params.push(format!("{vn}: {}{default}", Self::ty_in(&t)));
            let (p0, e, p1) = self.to_js(&t, &vn);
            pre.extend(p0);
            args.push(e);
            post.extend(p1);
        }
        let vn = if ctor { "new".to_string() } else { volt_name(&f.name) };
        let is_static = ctor || f.is_static;
        if !seen.insert(format!("{vn} {is_static}")) {
            return Err(format!("{what} (another function has its Volt name)"));
        }
        let gp = generics(&tps);
        let head = match (&cty, is_static) {
            (Some(c), true) => {
                let mut ps = vec![format!("static this: {c}")];
                ps.extend(params);
                format!("{gp}attach fn {vn}({}) -> {}", ps.join(", "), Self::ty_out(&ret))
            }
            (Some(c), false) => {
                let mut ps = vec![format!("this: {c}&")];
                ps.extend(params);
                format!("{gp}attach fn {vn}({}) -> {}", ps.join(", "), Self::ty_out(&ret))
            }
            (None, _) => format!("{gp}fn {vn}({}) -> {}", params.join(", "), Self::ty_out(&ret)),
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
        let call = match (cls.map(|x| x.0), ctor, f.is_static) {
            (None, _, _) => format!("js_rt::call(js_rt::get(js_rt::module(), \"{}\"), null, {n}, {a})", f.name),
            (Some(c), true, _) => format!("js_rt::construct(js_rt::get(js_rt::module(), \"{c}\"), {n}, {a})"),
            (Some(c), false, true) => format!("js_rt::call(js_rt::get(js_rt::obj(js_rt::get(js_rt::module(), \"{c}\")), \"{}\"), js_rt::obj(js_rt::get(js_rt::module(), \"{c}\")), {n}, {a})", f.name),
            (Some(c), false, false) => {
                l.push(format!("js_rt::live(this.o.v, \"{}::{c}\");", self.alias));
                format!("js_rt::call(js_rt::get(js_rt::obj(this.o.v), \"{}\"), js_rt::obj(this.o.v), {n}, {a})", f.name)
            }
        };
        if settles {
            l.push(format!("val j_r = js_rt::settle({call}, \"{what}\");"));
        } else {
            l.push(format!("val j_r = {call};"));
        }
        l.extend(post);
        l.extend(Self::result(&ret));
        Ok(func(&head, &l))
    }

    /// a field's or accessor's getter and (when it can be set) setter
    fn prop(&self, (c, tps): (&str, &[String]), (name, ty, settable, is_static): &(String, String, bool, bool), taken: &BTreeSet<String>) -> Result<String, String> {
        let what = format!("{c}.{name}");
        let t = self.jt(ty, tps).filter(|t| !matches!(t, JT::Void | JT::Fn(..))).ok_or(format!("{what} (its type)"))?;
        let (cty, gp) = (class_ty(c, tps), generics(tps));
        let vn = volt_name(name);
        if taken.contains(&vn) {
            return Err(format!("{what} (a method has its name)"));
        }
        let (this, target) = if *is_static {
            (format!("static this: {cty}"), format!("js_rt::obj(js_rt::get(js_rt::module(), \"{c}\"))"))
        } else {
            (format!("this: {cty}&"), "js_rt::obj(this.o.v)".to_string())
        };
        let mut start = vec!["val j_x = js_rt::enter();".to_string()];
        if !is_static {
            start.push(format!("js_rt::live(this.o.v, \"{}::{c}\");", self.alias));
        }
        let mut get = start.clone();
        get.push(format!("val j_r = js_rt::get({target}, \"{name}\");"));
        get.extend(Self::result(&t));
        let mut out = func(&format!("{gp}attach fn {vn}({this}) -> {}", Self::ty_out(&t)), &get);
        if *settable && !taken.contains(&format!("set_{vn}")) {
            let (pre, e, _) = self.to_js(&t, "v");
            let mut set = start;
            set.extend(pre);
            set.push(format!("js_rt::set({target}, \"{name}\", {e});"));
            let _ = write!(out, "\n{}", func(&format!("{gp}attach fn set_{vn}({this}, v: {}) -> void", Self::ty_in(&t)), &set));
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
    let mut g = Gen {
        alias,
        enums: m.items.iter().filter_map(|i| if let Item::Enum(n, _) = i { Some(n.clone()) } else { None }).collect(),
        objs: m.items.iter().filter_map(|i| if let Item::Class(c) = i { (c.name != "js_rt" && c.tparams.is_empty()).then(|| c.name.clone()) } else { None }).collect(),
        structs: BTreeSet::new(),
        aliases: m.items.iter().filter_map(|i| if let Item::Alias(n, t) = i { Some((n.clone(), t.clone())) } else { None }).collect(),
        fns: RefCell::default(),
    };
    let structs = g.plain_structs(m, &mut left);
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
                let _ = write!(helpers, "    fn of_any(x: {alias}::{n}&) -> js::JSValueRef {{\n        return of_num(@cast<f64>(tag_{n}(*x)));\n    }}\n    fn from_js(v: js::JSValueRef) -> {alias}::{n} {{\n        return of_{n}(to_num(v));\n    }}\n");
                let _ = write!(decls, "\n// the enum {n}\nenum {n}: i64 {{\n{body}}}\n");
            }
            Item::Struct(s) => {
                if let Some(fs) = structs.get(&s.name) {
                    let (decl, conv) = g.struct_glue(&s.name, fs);
                    decls.push_str(&decl);
                    helpers.push_str(&conv);
                }
            }
            Item::Alias(..) => {}
            Item::Class(c) if c.name == "js_rt" => left.push("js_rt (the glue's own name)".into()),
            Item::Class(own) => {
                // what it inherits: its bases' methods, fields and accessors it doesn't have, and
                // a constructor when it writes none
                let mut c = own.clone();
                let mut b = own.base.clone();
                while let Some(base) = b.and_then(|s| m.items.iter().find_map(|i| if let Item::Class(x) = i { (x.name == s).then_some(x) } else { None })) {
                    // (its type parameters aren't the subclass's)
                    if !base.tparams.is_empty() {
                        left.push(format!("{} (what it inherits from {}, a generic class)", own.name, base.name));
                        break;
                    }
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
                let tps = c.tparams.as_slice();
                let (cty, gp) = (class_ty(n, tps), generics(tps));
                let _ = write!(decls, "\n// the class {n}: a reference to an object (a copy refers to the same one)\n{gp}struct {n} {{\n    o: js_rt::ref = {{}};\n}}\n\n{gp}attach fn is_null(this: {cty}&) -> bool {{\n    return this.o.v == null;\n}}\n");
                if tps.is_empty() {
                    let _ = write!(helpers, "    fn of_any(x: {alias}::{n}&) -> js::JSValueRef {{\n        return of_obj(x.o.v);\n    }}\n    fn from_js(v: js::JSValueRef) -> {alias}::{n} {{\n        return {{ o: keep(v) }};\n    }}\n");
                }
                // its bases, as far as the module has them
                let mut b = c.base.clone();
                while let Some(s) = b.filter(|s| g.objs.contains(s)) {
                    let _ = write!(decls, "\n// as a {s}: the same object\n{gp}attach fn as_{s}(this: {cty}&) -> {s} {{\n    return {{ o: copy this.o }};\n}}\n");
                    b = m.items.iter().find_map(|i| if let Item::Class(x) = i { (x.name == s).then(|| x.base.clone()).flatten() } else { None });
                }
                let mut cs = BTreeSet::new();
                let ctor = c.ctor.clone().unwrap_or(Func { name: "constructor".into(), tparams: vec![], params: vec![], ret: None, returns: false, is_static: true, is_async: false });
                match g.func(Some((n, tps)), &ctor, true, &mut cs) {
                    Ok(t) => {
                        let _ = write!(decls, "\n{t}");
                    }
                    Err(why) => left.push(why),
                }
                let taken: BTreeSet<String> = c.methods.iter().map(|f| volt_name(&f.name)).collect();
                for f in &c.methods {
                    match g.func(Some((n, tps)), f, false, &mut cs) {
                        Ok(t) => {
                            let _ = write!(decls, "\n{t}");
                        }
                        Err(why) => left.push(why),
                    }
                }
                for p in &c.props {
                    match g.prop((n, tps), p, &taken) {
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
            Item::Const(n, t, v) => match g.jt(t, &[]) {
                Some(JT::Prim(p)) => {
                    let _ = write!(decls, "\nval {}: {} = {v};\n", volt_name(n), volt_prim(p));
                }
                _ => left.push(format!("{n} (its type)")),
            },
        }
    }
    for (_, code) in g.fns.borrow().iter() {
        helpers.push_str(code);
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

    // an async function's promise, settled: JavaScriptCore runs what's queued (its microtasks) as
    // the call attaching then() returns; with no event loop, one still pending never settles
    fn settle(p: js::JSValueRef, what: str) -> js::JSValueRef {
        val a: js::JSValueRef[1] = { p };
        val s = obj(call(get(module(), "__volt_settle"), null, 1, &a[0]));
        if (!to_bool(get(s, "done"))) {
            @panic(std::fmt::format("JavaScript: {}'s promise never settled (there's no event loop: what it awaits must be done as the call returns)", what).as_str());
        }
        val v = get(s, "v");
        if (!to_bool(get(s, "ok"))) {
            val m = to_str(v);
            @panic(m.as_str());
        }
        return v;
    }

    // a callback's i-th argument (undefined past those it was given)
    fn arg(args: js::JSValueRef*, n: usize, i: usize) -> js::JSValueRef {
        if (i >= n) {
            return undefined();
        }
        return @slice(args, n)[i];
    }

    // conversions by type, for generic functions and classes, object types and arrays of them
    // (the import's classes, enums and object types add theirs)
    fn of_any(x: f64&) -> js::JSValueRef {
        return of_num(*x);
    }
    fn of_any(x: bool&) -> js::JSValueRef {
        return of_bool(*x);
    }
    fn of_any(x: str&) -> js::JSValueRef {
        return of_str(*x);
    }
    fn of_any(x: std::string&) -> js::JSValueRef {
        return of_str(x.as_str());
    }
    fn from_js(v: js::JSValueRef) -> f64 {
        return to_num(v);
    }
    fn from_js(v: js::JSValueRef) -> bool {
        return to_bool(v);
    }
    fn from_js(v: js::JSValueRef) -> std::string {
        return to_str(v);
    }

    <T: type>
    fn to_opt(v: js::JSValueRef) -> T? {
        if (is_nothing(v)) {
            return null;
        }
        val x: T = from_js(v);
        return x;
    }

    <T: type>
    fn of_list(xs: T[..]) -> js::JSValueRef {
        var vs: std::vec<js::JSValueRef> = {};
        for (x&) in xs {
            vs.push(of_any(x)) catch @panic("out of memory");
        }
        return array(vs.items());
    }

    <T: type>
    fn to_list(v: js::JSValueRef) -> std::vec<T> {
        var out: std::vec<T> = {};
        if (is_nothing(v)) {
            return out;
        }
        for (i) in 0..length(v) {
            val x: T = from_js(at(v, i));
            out.push(move x) catch @panic("out of memory");
        }
        return out;
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
        let g = Gen { alias: "geo", enums: ["Color".to_string()].into(), objs: ["Shape".to_string()].into(), structs: ["Size".to_string()].into(), aliases: [("Id".to_string(), "number".to_string())].into(), fns: RefCell::default() };
        assert_eq!(g.jt("number | undefined", &[]), Some(JT::Opt("num")));
        assert_eq!(g.jt("Array<string>", &[]), Some(JT::List("str")));
        assert_eq!(g.jt("Shape | null", &[]), Some(JT::Obj("Shape".into())));
        assert_eq!(g.jt("Promise<void>", &[]), None);
        assert_eq!(g.jt("Id | null", &[]), Some(JT::Opt("num")));
        assert_eq!(g.jt("T[]", &["T".to_string()]), Some(JT::Many(Box::new(JT::Gen("T".into())))));
        assert_eq!(g.jt("Size[]", &[]), Some(JT::Many(Box::new(JT::Struct("Size".into())))));
        assert_eq!(g.jt("(a: number, s: string) => Shape", &[]), Some(JT::Fn(vec![JT::Prim("num"), JT::Prim("str")], Box::new(JT::Obj("Shape".into())))));
        assert_eq!(g.jt("(xs: number[]) => void", &[]), None);
        assert_eq!(g.jt("(x?: number) => void", &[]), None);
    }

    #[test]
    fn import_js_types() {
        let src = "export function first<T extends object = {}>(xs: T[]): T { return xs[0]; }\nexport class Box<T> {\n  value: T;\n  constructor(v: T) { this.value = v; }\n  map<U>(f: (x: T) => U): U { return f(this.value); }\n}\nexport interface Size extends Base {\n  w: number\n  readonly h?: number;\n  tags: string[], name: string\n}\ninterface Base { id: number }\ninterface Odd { [k: string]: number }\nexport type Range = { lo: number; hi: number };\ntype Id = number\nexport async function later(n: Id): Promise<number> { return n; }\nexport function apply(f: (x: number) => number, g: (s?: string) => void): number { return f(1); }\nexport function each(f: (s: string, r: Range) => Size): void {}\ninterface Loop { next: Loop }\nexport class Wrap<T> {\n  static of<T>(x: T): number { return 1; }\n  size(): number { return 0; }\n}\nexport function onDone(f?: (x: number) => void, s?: Size): void {}\ntype Cb = (x: number) => number;\nexport function maybeCb(f: Cb | null): void {}\nexport class Sub<T> extends Box<string> {\n  own(): number { return 1; }\n}\n";
        let m = parse(src);
        let Item::Func(first) = &m.items[0] else { panic!() };
        assert_eq!(first.tparams, ["T"]);
        let Item::Class(b) = &m.items[1] else { panic!() };
        assert_eq!((b.tparams.as_slice(), b.methods[0].tparams.as_slice()), (&["T".to_string()][..], &["U".to_string()][..]));
        let Item::Struct(s) = &m.items[2] else { panic!("{:?}", m.items[2]) };
        assert_eq!(s.bases, ["Base"]);
        let f = |n: &str, t: &str, o: bool| (n.to_string(), t.to_string(), o);
        assert_eq!(s.fields, [f("w", "number", false), f("h", "number", true), f("tags", "string[]", false), f("name", "string", false)]);
        let Item::Struct(odd) = &m.items[4] else { panic!() };
        assert_eq!(odd.why.as_deref(), Some("an index signature"));
        assert_eq!(m.items[6], Item::Alias("Id".into(), "number".into()));
        assert!(m.items.iter().filter(|i| i.is_value()).map(|i| i.name()).eq(["first", "Box", "later", "apply", "each", "Wrap", "onDone", "maybeCb", "Sub"]));
        let out = generate("geo", &m, Path::new("JavaScript.h"), Path::new("module.js"));
        for want in [
            "<T: type>\nfn first(xs: T[..]) -> T {",
            "js_rt::of_list(xs)",
            "<T: type>\nstruct Box {",
            "<T: type>\nattach fn new(static this: Box<T>, v: T) -> Box<T> {",
            "<T: type>\nattach fn value(this: Box<T>&) -> T {",
            "struct Size {\n    id: f64;\n    w: f64;\n    h: f64? = null;\n    tags: std::vec<std::string>;\n    name: std::string;\n}",
            "fn from_js(v: js::JSValueRef) -> geo::Size {",
            "struct Range {\n    lo: f64;\n    hi: f64;\n}",
            "fn later(n: f64) -> f64 {",
            "val j_r = js_rt::settle(js_rt::call(js_rt::get(js_rt::module(), \"later\"), null, 1, &j_a[0]), \"later\");",
            "fn each(f: fn(str, Range) -> Size) -> void {",
            "fn of_fn_1(f: fn(str, geo::Range) -> geo::Size) -> js::JSValueRef {",
            "fn of_fn_0(f: fn(f64) -> f64) -> js::JSValueRef {",
            "val a1: geo::Range = from_js(arg(args, n, 1));",
            "//   Box.map (parameter f's type)",
            "//   Odd (an index signature)",
            "//   apply (parameter g's type)",
            "//   Loop (it holds itself)",
            "//   Wrap.of (its type parameter T is the class's too)",
            "attach fn size(this: Wrap<T>&) -> f64 {",
            "//   onDone (parameter f is optional: a callback, object type or type parameter can't be absent)",
            "//   maybeCb (parameter f's type)",
            "//   Sub (what it inherits from Box, a generic class)",
            "attach fn own(this: Sub<T>&) -> f64 {",
        ] {
            assert!(out.contains(want), "{want}\n---\n{out}");
        }
    }
}
