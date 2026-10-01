// use rust { "crate dir" } as NAME; — an ordinary Cargo library crate, called from Volt. bolt reads
// the crate's public API from its source and writes a shim crate next to OUT that depends on it and
// wraps each public fn, method and type in an extern "C" function, builds it with cargo as a static
// library, and writes the Volt side that calls the shim. Nothing in the crate changes.
//
//   pub fn                   -> fn; a method (impl T { pub fn }) -> attach fn, an associated fn
//                               (no self) -> attach fn f(static this: T, ...), so T::new(...)
//   i8..u64, isize, usize, f32, f64, bool -> the same; char -> u32
//   &str, String              -> str in, std::string out (a copy)
//   &[T], &mut [T], Vec<T>    -> T[..] in, std::vec<T> out (a copy), T a number or bool; &[&str],
//                               Vec<String> -> str[..] in, std::vec<std::string> out
//   Option<T>                 -> T?
//   Result<T, E>              -> rust_error!T, the error's to_string() in rust_error::ERROR
//   a struct whose fields are all pub numbers, bools, chars, fieldless enums or such structs
//                             -> a Volt struct with the same fields, passed by value (copied over)
//   any other struct, or an enum with data -> an owned handle: deleting it drops the Rust value,
//                               copy clones it (when the type is Clone); a method that takes self
//                               takes the handle (var this) and leaves it empty
//   a fieldless enum          -> a Volt enum with the same values
//   pub const of a number, bool or &str literal -> val
//   pub mod                   -> namespace
// What doesn't map (generics, traits, closures, references returned to Rust-owned data) is left out
// with a comment in the Volt source, which VOLT_SHOW_IMPORT=1 makes voltc print.
use super::{arg_path, fresh, save, stamp, volt_name, Made, Req};
use crate::foreign::{int_value, lex, tok_text, Cur, Tok};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn import(r: &Req) -> Result<(), String> {
    let [dir] = r.args.as_slice() else {
        return Err(format!("use rust {{ \"crate dir\" }} as {}: name one crate's directory", r.alias));
    };
    let dir = arg_path(r, dir);
    let manifest = dir.join("Cargo.toml");
    if !manifest.is_file() {
        return Err(format!("use rust: {} has no Cargo.toml", dir.display()));
    }
    let (pkg, lib) = crate_names(&manifest)?;
    let mut files = vec![manifest.clone(), dir.join("Cargo.lock")];
    rs_files(&dir.join("src"), &mut files);
    let st = stamp(&files, &format!("rust {} {} release={}", r.alias, dir.display(), r.release));
    if fresh(r, &st) {
        return Ok(());
    }

    let mut model = Model { lib: lib.clone(), ..Model::default() };
    let root = dir.join("src/lib.rs");
    let text = std::fs::read_to_string(&root).map_err(|e| format!("use rust: can't read {}: {e}", root.display()))?;
    model.walk(&lex(&text), &[], &dir.join("src"));
    let g = Gen::new(&model, &r.alias);
    let (shim, volt) = g.write();

    // the shim crate: its own target directory, cargo run from the crate's (its rust-toolchain.toml)
    let shim_dir = r.out.join("shim");
    crate::build::write_if_changed(&shim_dir.join("Cargo.toml"), &format!("[package]\nname = \"volt_import_{}\"\nversion = \"0.0.0\"\nedition = \"2021\"\npublish = false\n\n[lib]\npath = \"lib.rs\"\n\n[dependencies]\n{pkg} = {{ path = {:?} }}\n\n[workspace]\n", r.alias, dir.display().to_string()))?;
    crate::build::write_if_changed(&shim_dir.join("lib.rs"), &shim)?;
    let mut c = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".into()));
    c.current_dir(&dir).args(["rustc", "-q", "--lib", "--crate-type", "staticlib", "--manifest-path"]).arg(shim_dir.join("Cargo.toml")).arg("--target-dir").arg(r.out.join("target"));
    if r.release {
        c.arg("--release");
    }
    c.args(["--", "--print", "native-static-libs"]);
    let o = c.output().map_err(|e| format!("use rust: can't run cargo: {e}"))?;
    let err = String::from_utf8_lossy(&o.stderr);
    if !o.status.success() {
        return Err(format!("use rust: cargo couldn't build the glue for {}:\n{err}", dir.display()));
    }
    let lib_file = r.out.join("target").join(if r.release { "release" } else { "debug" }).join(format!("libvolt_import_{}.a", r.alias));
    let mut flags = vec![lib_file.display().to_string()];
    for line in err.lines() {
        if let Some(libs) = line.split("native-static-libs:").nth(1) {
            for l in libs.split_whitespace() {
                if !flags.iter().any(|x| x == l) {
                    flags.push(l.to_string());
                }
            }
        }
    }
    save(r, &Made { volt, flags, deps: files }, &st)
}

/// the package's name and its library's (as Rust code names it)
fn crate_names(manifest: &Path) -> Result<(String, String), String> {
    let text = std::fs::read_to_string(manifest).map_err(|e| format!("can't read {}: {e}", manifest.display()))?;
    let t = crate::toml::parse(&text).map_err(|e| format!("{}: {e}", manifest.display()))?;
    let get = |table: &str, key: &str| t.get(table).and_then(|v| v.as_table()).and_then(|v| v.get(key)).and_then(|v| v.as_str()).map(String::from);
    let pkg = get("package", "name").ok_or(format!("{} has no [package] name", manifest.display()))?;
    let lib = get("lib", "name").unwrap_or_else(|| pkg.clone()).replace('-', "_");
    Ok((pkg, lib))
}

fn rs_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    let mut paths: Vec<_> = rd.filter_map(|e| e.ok().map(|e| e.path())).collect();
    paths.sort();
    for p in paths {
        if p.is_dir() {
            rs_files(&p, out);
        } else if p.extension().is_some_and(|x| x == "rs") {
            out.push(p);
        }
    }
}

// ---------- the crate's public API ----------

#[derive(Default)]
struct Model {
    lib: String,
    fns: Vec<(Vec<String>, Sig)>,
    types: Vec<TypeDef>,
    consts: Vec<(Vec<String>, String, Vec<Tok>, Vec<Tok>)>, // module, name, type, value
    // inherent impls' pub fns, by type name; trait impls' trait names, by type name
    methods: BTreeMap<String, Vec<Sig>>,
    traits: BTreeMap<String, BTreeSet<String>>,
}

#[derive(Clone)]
struct TypeDef {
    module: Vec<String>,
    name: String,
    generic: bool,
    // struct fields (name, pub, type), None for a tuple or unit struct
    fields: Option<Vec<(String, bool, Vec<Tok>)>>,
    // an enum's variants (name, value), None when one holds data
    variants: Option<Vec<(String, i128)>>,
    is_enum: bool,
    derives: BTreeSet<String>,
    // #[non_exhaustive]: never built (or matched without a wildcard) outside its crate
    non_exhaustive: bool,
}

#[derive(Clone, Copy, PartialEq)]
enum Recv {
    None,
    Ref,
    Mut,
    Value,
}

#[derive(Clone)]
struct Sig {
    name: String,
    recv: Recv,
    params: Vec<(String, Vec<Tok>)>,
    ret: Vec<Tok>,
    // why it can't be called from Volt, when it can't
    skip: Option<&'static str>,
}

impl Model {
    /// a file's (or an inline mod's) items: `dir` is where its child modules' files are
    fn walk(&mut self, t: &[Tok], module: &[String], dir: &Path) {
        let mut c = Cur { t, i: 0 };
        let mut attrs: Vec<Vec<Tok>> = Vec::new();
        while c.i < t.len() {
            if c.is("#") {
                c.i += 1;
                let inner = c.eat("!");
                if c.is("[") {
                    let s = c.i;
                    c.skip_group();
                    if !inner {
                        attrs.push(t[s + 1..c.i - 1].to_vec());
                    }
                }
                continue;
            }
            let start = c.i;
            let kind = item_kind(&t[start..]);
            let mut body = None;
            while c.i < t.len() {
                if c.is(";") {
                    c.i += 1;
                    break;
                }
                if c.is("{") && !matches!(kind, "const" | "static") {
                    let s = c.i;
                    c.skip_group();
                    body = Some((s + 1, c.i - 1));
                    break;
                }
                if c.is("(") || c.is("[") || c.is("{") {
                    c.skip_group();
                    continue;
                }
                c.i += 1;
            }
            let item = &t[start..c.i];
            let cfg = attrs.iter().any(|a| matches!(a.first(), Some(Tok::Id(w)) if w == "cfg"));
            if !cfg {
                self.item(&attrs, item, kind, body.map(|(a, b)| &t[a..b]), module, dir);
            }
            attrs.clear();
        }
    }

    fn item(&mut self, attrs: &[Vec<Tok>], item: &[Tok], kind: &str, body: Option<&[Tok]>, module: &[String], dir: &Path) {
        let public = matches!(item.first(), Some(Tok::Id(w)) if w == "pub") && !matches!(item.get(1), Some(Tok::P(p)) if p == "(");
        let at = |w: &str| item.iter().position(|x| matches!(x, Tok::Id(y) if y == w));
        match kind {
            "mod" if public => {
                let Some(Tok::Id(name)) = at("mod").and_then(|k| item.get(k + 1)) else { return };
                let mut sub = module.to_vec();
                sub.push(name.clone());
                match body {
                    Some(b) => self.walk(b, &sub, &dir.join(name)),
                    None => {
                        let file = [dir.join(format!("{name}.rs")), dir.join(name).join("mod.rs")].into_iter().find(|p| p.is_file());
                        if let Some(text) = file.and_then(|f| std::fs::read_to_string(f).ok()) {
                            self.walk(&lex(&text), &sub, &dir.join(name));
                        }
                    }
                }
            }
            "fn" if public => {
                let sig = sig(item);
                self.fns.push((module.to_vec(), sig));
            }
            "struct" | "enum" if public => {
                let Some(Tok::Id(name)) = at(kind).and_then(|k| item.get(k + 1)) else { return };
                let generic = matches!(at(kind).and_then(|k| item.get(k + 2)), Some(Tok::P(p)) if p == "<") && generic_args(item, at(kind).unwrap() + 2);
                let non_exhaustive = attrs.iter().any(|a| matches!(a.first(), Some(Tok::Id(w)) if w == "non_exhaustive"));
                let mut d = TypeDef { module: module.to_vec(), name: name.clone(), generic, fields: None, variants: None, is_enum: kind == "enum", derives: derives(attrs), non_exhaustive };
                let open = item.iter().position(|x| *x == Tok::P("{".into()));
                if kind == "struct" {
                    if let Some(open) = open {
                        let mut fc = Cur { t: item, i: open };
                        let mut fields = Vec::new();
                        for f in fc.group_items() {
                            let f = strip_attrs(&f);
                            let Some(colon) = f.iter().position(|x| *x == Tok::P(":".into())) else { continue };
                            let Some(Tok::Id(fname)) = f.get(colon - 1) else { continue };
                            let public = matches!(f.first(), Some(Tok::Id(w)) if w == "pub") && !matches!(f.get(1), Some(Tok::P(p)) if p == "(");
                            fields.push((fname.clone(), public, f[colon + 1..].to_vec()));
                        }
                        d.fields = Some(fields);
                    }
                } else if let Some(open) = open {
                    let mut vc = Cur { t: item, i: open };
                    let mut vs = Vec::new();
                    let mut next: i128 = 0;
                    let mut plain = true;
                    for v in vc.group_items() {
                        let v = strip_attrs(&v);
                        let Some(Tok::Id(vn)) = v.first() else { continue };
                        if v.iter().any(|x| matches!(x, Tok::P(p) if p == "(" || p == "{")) {
                            plain = false;
                        }
                        if let Some(eq) = v.iter().position(|x| *x == Tok::P("=".into())) {
                            next = int_value(&v[eq + 1..]).unwrap_or(next);
                        }
                        vs.push((vn.clone(), next));
                        next += 1;
                    }
                    d.variants = plain.then_some(vs);
                }
                self.types.push(d);
            }
            "const" if public => {
                let Some(k) = at("const") else { return };
                let (Some(Tok::Id(name)), Some(colon), Some(eq)) = (item.get(k + 1), item.iter().position(|x| *x == Tok::P(":".into())), item.iter().position(|x| *x == Tok::P("=".into()))) else { return };
                let end = item.len() - usize::from(item.last() == Some(&Tok::P(";".into())));
                self.consts.push((module.to_vec(), name.clone(), item[colon + 1..eq].to_vec(), item[eq + 1..end].to_vec()));
            }
            "impl" => {
                let Some(b) = body else { return };
                // impl<...> [Trait for] Type<...>
                let k = at("impl").unwrap_or(0);
                let mut i = k + 1;
                if matches!(item.get(i), Some(Tok::P(p)) if p == "<") {
                    let mut gc = Cur { t: item, i };
                    gc.skip_group();
                    i = gc.i;
                }
                let head: Vec<Tok> = item[i..].iter().take_while(|x| **x != Tok::P("{".into()) && **x != Tok::Id("where".into())).cloned().collect();
                let (trait_name, ty) = match head.iter().position(|x| *x == Tok::Id("for".into())) {
                    Some(f) => (last_ident(&head[..f]), head[f + 1..].to_vec()),
                    None => (None, head.clone()),
                };
                let Some(ty_name) = last_ident(&ty) else { return };
                if let Some(tr) = trait_name {
                    self.traits.entry(ty_name).or_default().insert(tr);
                    return;
                }
                // pub fns of the impl: walk its items
                let mut ic = Cur { t: b, i: 0 };
                while ic.i < b.len() {
                    if ic.is("#") {
                        ic.i += 1;
                        if ic.is("[") {
                            ic.skip_group();
                        }
                        continue;
                    }
                    let s = ic.i;
                    while ic.i < b.len() {
                        if ic.is(";") {
                            ic.i += 1;
                            break;
                        }
                        if ic.is("{") {
                            ic.skip_group();
                            break;
                        }
                        if ic.is("(") || ic.is("[") {
                            ic.skip_group();
                            continue;
                        }
                        ic.i += 1;
                    }
                    let f = &b[s..ic.i];
                    let public = matches!(f.first(), Some(Tok::Id(w)) if w == "pub") && !matches!(f.get(1), Some(Tok::P(p)) if p == "(");
                    if public && item_kind(f) == "fn" {
                        let s = sig(f);
                        self.methods.entry(ty_name.clone()).or_default().push(s);
                    }
                }
            }
            _ => {}
        }
    }
}

/// the kind of item these tokens start: fn, struct, enum, mod, impl, const, static, use, trait, ...
fn item_kind(t: &[Tok]) -> &'static str {
    const KINDS: &[&str] = &["fn", "struct", "enum", "mod", "impl", "const", "static", "use", "trait", "type", "union", "macro_rules", "extern"];
    for x in t.iter().take(8) {
        match x {
            Tok::Id(w) => {
                if let Some(k) = KINDS.iter().find(|k| **k == w) {
                    // `const fn` and `extern "C" fn` are fns
                    if (*k == "const" || *k == "extern") && t.iter().take(8).any(|y| *y == Tok::Id("fn".into())) {
                        return "fn";
                    }
                    return k;
                }
            }
            Tok::P(p) if p == "{" || p == ";" => break,
            _ => {}
        }
    }
    ""
}

/// whether the <...> at i holds generic parameters (lifetimes, which the lexer drops, don't count)
fn generic_args(t: &[Tok], i: usize) -> bool {
    let mut c = Cur { t, i };
    c.group_items().iter().any(|x| !x.is_empty())
}

fn strip_attrs(t: &[Tok]) -> Vec<Tok> {
    let mut c = Cur { t, i: 0 };
    while c.is("#") {
        c.i += 1;
        c.skip_group();
    }
    t[c.i..].to_vec()
}

fn last_ident(t: &[Tok]) -> Option<String> {
    // the type's name: the last identifier before any <...>
    let end = t.iter().position(|x| *x == Tok::P("<".into())).unwrap_or(t.len());
    t[..end].iter().rev().find_map(|x| if let Tok::Id(w) = x { Some(w.clone()) } else { None })
}

/// #[derive(Clone, Copy, ...)]'s names
fn derives(attrs: &[Vec<Tok>]) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    for a in attrs {
        if matches!(a.first(), Some(Tok::Id(w)) if w == "derive") {
            for x in a {
                if let Tok::Id(w) = x {
                    out.insert(w.clone());
                }
            }
        }
    }
    out
}

/// a fn's signature from its tokens
fn sig(item: &[Tok]) -> Sig {
    let k = item.iter().position(|x| *x == Tok::Id("fn".into())).unwrap_or(0);
    let name = match item.get(k + 1) {
        Some(Tok::Id(n)) => n.clone(),
        _ => String::new(),
    };
    let mut s = Sig { name, recv: Recv::None, params: Vec::new(), ret: Vec::new(), skip: None };
    if item[..k].iter().any(|x| *x == Tok::Id("async".into())) {
        s.skip = Some("it's async");
    }
    let mut c = Cur { t: item, i: k + 2 };
    if c.is("<") {
        if generic_args(item, c.i) {
            s.skip = Some("it's generic");
        }
        c.skip_group();
    }
    if !c.is("(") {
        s.skip = Some("its parameters");
        return s;
    }
    for (n, p) in c.group_items().into_iter().enumerate() {
        let mut p = strip_attrs(&p);
        let words: Vec<String> = p.iter().map(tok_text).collect();
        let w: Vec<&str> = words.iter().map(String::as_str).collect();
        if n == 0 && w.contains(&"self") {
            s.recv = match w.as_slice() {
                ["&", "self"] | ["self", ":", "&", "Self"] => Recv::Ref,
                ["&", "mut", "self"] | ["self", ":", "&", "mut", "Self"] => Recv::Mut,
                ["self"] | ["mut", "self"] | ["self", ":", "Self"] | ["mut", "self", ":", "Self"] => Recv::Value,
                _ => {
                    s.skip = Some("its self parameter");
                    Recv::None
                }
            };
            continue;
        }
        // `mut x: T`: the binding's mut is the callee's business
        if p.first() == Some(&Tok::Id("mut".into())) {
            p.remove(0);
        }
        let Some(colon) = p.iter().position(|x| *x == Tok::P(":".into())) else {
            s.skip = Some("a parameter");
            continue;
        };
        let pname = match p.first() {
            Some(Tok::Id(x)) if colon == 1 && x != "_" => x.clone(),
            _ => format!("a{n}"),
        };
        s.params.push((pname, p[colon + 1..].to_vec()));
    }
    if c.eat("->") {
        let st = c.i;
        while c.i < item.len() && !c.is("{") && !c.is(";") && !c.is_id("where") {
            c.i += 1;
        }
        s.ret = item[st..c.i].to_vec();
    }
    if c.is_id("where") {
        s.skip = Some("it has a where clause");
    }
    s
}

// ---------- types ----------

#[derive(Clone, Debug, PartialEq)]
enum Ty {
    Unit,
    Prim(&'static str),
    Char,
    Str,
    String,
    Slice(Box<Ty>, bool), // element, mutable
    Vec(Box<Ty>),
    Opt(Box<Ty>),
    Res(Box<Ty>),
    Named(String),
    Ref(Box<Ty>, bool), // to a named type, mutable
    SelfTy,
}

const PRIMS: &[&str] = &["i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "isize", "usize", "f32", "f64", "bool"];

/// a Rust type from its tokens, when it's one Volt can name
fn parse_ty(t: &[Tok]) -> Option<Ty> {
    match t {
        [] => Some(Ty::Unit),
        [Tok::P(a), Tok::P(b)] if a == "(" && b == ")" => Some(Ty::Unit),
        [Tok::P(amp), rest @ ..] if amp == "&" => {
            let (mutable, rest) = match rest {
                [Tok::Id(m), rest @ ..] if m == "mut" => (true, rest),
                _ => (false, rest),
            };
            match rest {
                [Tok::Id(s)] if s == "str" && !mutable => Some(Ty::Str),
                [Tok::P(o), inner @ .., Tok::P(c)] if o == "[" && c == "]" => Some(Ty::Slice(Box::new(parse_ty(inner)?), mutable)),
                _ => match parse_ty(rest)? {
                    Ty::String if !mutable => Some(Ty::Str),
                    Ty::Vec(e) => Some(Ty::Slice(e, mutable)),
                    t @ (Ty::Named(_) | Ty::SelfTy) => Some(Ty::Ref(Box::new(t), mutable)),
                    t @ (Ty::Prim(_) | Ty::Char) if !mutable => Some(t),
                    _ => None,
                },
            }
        }
        _ => {
            // a path, maybe with <args> at its end
            let lt = t.iter().position(|x| *x == Tok::P("<".into()));
            let path = &t[..lt.unwrap_or(t.len())];
            if path.iter().any(|x| matches!(x, Tok::P(p) if p != "::")) {
                return None;
            }
            let Some(Tok::Id(name)) = path.last() else { return None };
            let args = match lt {
                Some(i) => {
                    if t.last() != Some(&Tok::P(">".into())) {
                        return None;
                    }
                    let mut c = Cur { t, i };
                    c.group_items()
                }
                None => Vec::new(),
            };
            let one = |args: &[Vec<Tok>]| -> Option<Box<Ty>> { Some(Box::new(parse_ty(args.first()?)?)) };
            match (name.as_str(), args.len()) {
                (p, 0) if PRIMS.contains(&p) => Some(Ty::Prim(PRIMS.iter().find(|x| **x == p).unwrap())),
                ("char", 0) => Some(Ty::Char),
                ("String", 0) => Some(Ty::String),
                ("Self", 0) => Some(Ty::SelfTy),
                ("Vec", 1) => Some(Ty::Vec(one(&args)?)),
                ("Option", 1) => Some(Ty::Opt(one(&args)?)),
                ("Result", 1 | 2) => Some(Ty::Res(one(&args)?)),
                (_, 0) if name.chars().next().is_some_and(|c| c.is_ascii_uppercase()) => Some(Ty::Named(name.clone())),
                _ => None,
            }
        }
    }
}

// ---------- writing the glue ----------

#[derive(Clone, Copy, PartialEq, Debug)]
enum Kind {
    Plain,
    Handle,
    Enum,
}

struct TypeInfo {
    def: TypeDef,
    kind: Kind,
    clone: bool,
}

/// the shim and the Volt source for one import
struct Gen<'a> {
    m: &'a Model,
    alias: String,
    types: BTreeMap<String, TypeInfo>,
    // element types whose vecs come back (a free function each)
    vec_elems: BTreeSet<&'static str>,
    strs: bool,
    errors: bool,
    shim: String,
    ext: String,     // the Volt extern declarations
    helpers: String, // Volt helpers in rust_shim
    // the Volt source of each module (by path), and what was left out
    modules: BTreeMap<Vec<String>, String>,
    left_out: Vec<String>,
}

/// one parameter's glue
#[derive(Default)]
struct Param {
    shim_params: Vec<String>,
    shim_pre: Vec<String>,
    shim_arg: String,
    shim_post: Vec<String>,
    volt_param: String,
    volt_pre: Vec<String>,
    volt_ext: Vec<String>,
    volt_args: Vec<String>,
}

/// how a value comes back: the out parameters, the shim's statement storing `v` in them, and the
/// Volt locals, out arguments and the expression that makes the Volt value
struct Out {
    shim_params: Vec<String>,
    shim_store: String,
    volt_ext: Vec<String>,
    volt_locals: Vec<String>,
    volt_args: Vec<String>,
    volt_value: String,
    volt_ty: String,
}

impl<'a> Gen<'a> {
    fn new(m: &'a Model, alias: &str) -> Gen<'a> {
        let mut types: BTreeMap<String, TypeInfo> = BTreeMap::new();
        let mut dup = BTreeSet::new();
        for d in &m.types {
            if d.generic {
                continue;
            }
            if types.contains_key(&d.name) {
                dup.insert(d.name.clone());
            }
            let clone = d.derives.contains("Clone") || m.traits.get(&d.name).is_some_and(|t| t.contains("Clone"));
            let kind = if d.is_enum && d.variants.is_some() { Kind::Enum } else { Kind::Handle };
            types.insert(d.name.clone(), TypeInfo { def: d.clone(), kind, clone });
        }
        for n in dup {
            types.remove(&n); // two types of one name in different modules: neither is used
        }
        // plain structs: every field pub and plain, until nothing changes
        loop {
            let mut changed = false;
            let names: Vec<String> = types.keys().cloned().collect();
            for n in names {
                let ti = &types[&n];
                if ti.kind != Kind::Handle || ti.def.is_enum || ti.def.non_exhaustive {
                    continue;
                }
                let Some(fields) = &ti.def.fields else { continue };
                let plain = !fields.is_empty()
                    && fields.iter().all(|(_, public, t)| {
                        *public
                            && match parse_ty(t) {
                                Some(Ty::Prim(_) | Ty::Char) => true,
                                Some(Ty::Named(x)) => types.get(&x).is_some_and(|o| o.kind != Kind::Handle),
                                _ => false,
                            }
                    });
                if plain {
                    types.get_mut(&n).unwrap().kind = Kind::Plain;
                    changed = true;
                }
            }
            if !changed {
                break;
            }
        }
        Gen { m, alias: alias.to_string(), types, vec_elems: BTreeSet::new(), strs: false, errors: false, shim: String::new(), ext: String::new(), helpers: String::new(), modules: BTreeMap::new(), left_out: Vec::new() }
    }

    /// the extern "C" symbol for a path of names
    fn sym(&self, parts: &[&str]) -> String {
        format!("volt_rs_{}_{}", self.alias, parts.join("_"))
    }

    /// the Volt path of a named type, from anywhere in the import
    fn volt_path(&self, def: &TypeDef) -> String {
        let mut p = vec![self.alias.clone()];
        p.extend(def.module.iter().map(|m| volt_name(m)));
        p.push(def.name.clone());
        p.join("::")
    }

    /// the Rust path of a named type, from the shim
    fn rust_path(&self, def: &TypeDef) -> String {
        let mut p = vec![self.m.lib.clone()];
        p.extend(def.module.iter().cloned());
        p.push(def.name.clone());
        format!("::{}", p.join("::"))
    }

    /// a name for the glue's helpers of a type (a__b__T: `__` keeps module a_b's T apart)
    fn mangle(def: &TypeDef) -> String {
        let mut p = def.module.clone();
        p.push(def.name.clone());
        p.join("__")
    }

    /// a Rust parameter's Volt name, kept apart from the glue's own locals (o, e, a0...)
    fn param_name(n: &str) -> String {
        let v = volt_name(n);
        let glue = matches!(v.as_str(), "o" | "o_n" | "o_has" | "e" | "e_n" | "a_this") || (v.len() > 1 && v.starts_with('a') && v[1..].chars().all(|c| c.is_ascii_digit()));
        if glue { format!("{v}_") } else { v }
    }

    /// Volt code that stops the program when handle `h` (an expression) is empty
    fn not_empty(vp: &str, h: &str) -> String {
        format!("if ({h} == null) {{ @panic(\"{vp} is empty: Rust never made it, or it was given to Rust already\"); }}")
    }

    fn info(&self, t: &Ty, self_ty: Option<&str>) -> Option<&TypeInfo> {
        match t {
            Ty::Named(n) => self.types.get(n),
            Ty::SelfTy => self.types.get(self_ty?),
            _ => None,
        }
    }

    fn resolve(&self, t: Ty, self_ty: Option<&str>) -> Ty {
        match t {
            Ty::SelfTy => self_ty.map_or(Ty::SelfTy, |s| Ty::Named(s.to_string())),
            Ty::Ref(x, m) => Ty::Ref(Box::new(self.resolve(*x, self_ty)), m),
            Ty::Opt(x) => Ty::Opt(Box::new(self.resolve(*x, self_ty))),
            Ty::Res(x) => Ty::Res(Box::new(self.resolve(*x, self_ty))),
            Ty::Vec(x) => Ty::Vec(Box::new(self.resolve(*x, self_ty))),
            t => t,
        }
    }

    fn zero(p: &str) -> &'static str {
        match p {
            "bool" => "false",
            "f32" | "f64" => "0.0",
            _ => "0",
        }
    }

    /// a parameter `name` of type t (the i-th, for the glue's names)
    fn param(&mut self, name: &str, t: &Ty, i: usize) -> Option<Param> {
        let a = format!("a{i}");
        let vn = Self::param_name(name);
        let mut p = Param::default();
        match t {
            Ty::Prim(x) => {
                p.shim_params.push(format!("{a}: {x}"));
                p.shim_arg = a.clone();
                p.volt_param = format!("{vn}: {x}");
                p.volt_ext.push(format!("{a}: {x}"));
                p.volt_args.push(vn);
            }
            Ty::Char => {
                p.shim_params.push(format!("{a}: u32"));
                p.shim_arg = format!("char::from_u32({a}).unwrap_or('\\u{{fffd}}')");
                p.volt_param = format!("{vn}: u32");
                p.volt_ext.push(format!("{a}: u32"));
                p.volt_args.push(vn);
            }
            Ty::Str | Ty::String => {
                p.shim_params.extend([format!("{a}: *const u8"), format!("{a}_n: usize")]);
                p.shim_arg = if *t == Ty::String { format!("s({a}, {a}_n).to_string()") } else { format!("s({a}, {a}_n)") };
                p.volt_param = format!("{vn}: str");
                p.volt_ext.extend([format!("{a}: u8*"), format!("{a}_n: usize")]);
                p.volt_args.extend([format!("@cast<u8*>({vn}.ptr)"), format!("{vn}.len")]);
            }
            Ty::Slice(e, _) | Ty::Vec(e) if matches!(**e, Ty::Prim(_)) => {
                let Ty::Prim(x) = **e else { unreachable!() };
                let mutable = matches!(t, Ty::Slice(_, true));
                if mutable {
                    p.shim_params.extend([format!("{a}: *mut {x}"), format!("{a}_n: usize")]);
                    p.shim_arg = format!("slm({a}, {a}_n)");
                } else {
                    p.shim_params.extend([format!("{a}: *const {x}"), format!("{a}_n: usize")]);
                    p.shim_arg = if matches!(t, Ty::Vec(_)) { format!("sl({a}, {a}_n).to_vec()") } else { format!("sl({a}, {a}_n)") };
                }
                p.volt_param = format!("{vn}: {x}[..]");
                p.volt_ext.extend([format!("{a}: {x}*"), format!("{a}_n: usize")]);
                p.volt_args.extend([format!("@cast<{x}*>({vn}.ptr)"), format!("{vn}.len")]);
            }
            Ty::Slice(e, false) | Ty::Vec(e) if matches!(**e, Ty::Str | Ty::String) => {
                self.strs = true;
                p.shim_params.extend([format!("{a}: *const VoltStr"), format!("{a}_n: usize")]);
                p.shim_arg = match (t, &**e) {
                    (Ty::Vec(_), _) => format!("strs({a}, {a}_n).into_iter().map(String::from).collect()"),
                    (_, Ty::String) => format!("&strs({a}, {a}_n).into_iter().map(String::from).collect::<Vec<String>>()"),
                    _ => format!("&strs({a}, {a}_n)"),
                };
                p.volt_param = format!("{vn}: str[..]");
                p.volt_ext.extend([format!("{a}: void*"), format!("{a}_n: usize")]);
                p.volt_args.extend([format!("@cast<void*>({vn}.ptr)"), format!("{vn}.len")]);
            }
            Ty::Opt(inner) => match &**inner {
                Ty::Prim(x) => {
                    p.shim_params.extend([format!("{a}_has: bool"), format!("{a}: {x}")]);
                    p.shim_arg = format!("if {a}_has {{ Some({a}) }} else {{ None }}");
                    p.volt_param = format!("{vn}: {x}?");
                    p.volt_ext.extend([format!("{a}_has: bool"), format!("{a}: {x}")]);
                    p.volt_args.extend([format!("{vn} != null"), format!("{vn} ?? {}", Self::zero(x))]);
                }
                Ty::Str | Ty::String => {
                    p.shim_params.extend([format!("{a}: *const u8"), format!("{a}_n: usize")]);
                    let conv = if **inner == Ty::String { ".to_string()" } else { "" };
                    p.shim_arg = format!("if {a}.is_null() {{ None }} else {{ Some(s({a}, {a}_n){conv}) }}");
                    p.volt_param = format!("{vn}: str?");
                    p.volt_pre.extend([format!("var {a}: u8* = null;"), format!("var {a}_n: usize = 0;"), format!("if ({vn}) {{ {a} = @cast<u8*>({vn}.ptr); {a}_n = {vn}.len; }}")]);
                    p.volt_ext.extend([format!("{a}: u8*"), format!("{a}_n: usize")]);
                    p.volt_args.extend([a.clone(), format!("{a}_n")]);
                }
                _ => return None,
            },
            Ty::Named(_) | Ty::Ref(..) => {
                let (named, by_ref, mutable) = match t {
                    Ty::Ref(x, m) => (&**x, true, *m),
                    x => (x, false, false),
                };
                let ti = self.info(named, None)?;
                let (vp, rp, mg, kind) = (self.volt_path(&ti.def), self.rust_path(&ti.def), Self::mangle(&ti.def), ti.kind);
                match kind {
                    Kind::Plain => {
                        p.shim_params.push(format!("{a}: *mut V_{mg}"));
                        if mutable {
                            p.shim_pre.push(format!("let mut {a}_v = from_{mg}(&*{a});"));
                            p.shim_arg = format!("&mut {a}_v");
                            p.shim_post.push(format!("*{a} = to_{mg}(&{a}_v);"));
                            p.volt_param = format!("{vn}: {vp}&");
                            p.volt_args.push(vn);
                        } else {
                            p.shim_arg = if by_ref { format!("&from_{mg}(&*{a})") } else { format!("from_{mg}(&*{a})") };
                            p.volt_param = format!("{vn}: {vp}");
                            p.volt_args.push(format!("&{vn}"));
                        }
                        p.volt_ext.push(format!("{a}: {vp}*"));
                    }
                    Kind::Handle => {
                        p.shim_params.push(format!("{a}: *mut c_void"));
                        p.volt_ext.push(format!("{a}: void*"));
                        p.volt_pre.push(Self::not_empty(&vp, &format!("{vn}.h")));
                        if by_ref {
                            p.shim_arg = if mutable { format!("&mut *({a} as *mut {rp})") } else { format!("&*({a} as *const {rp})") };
                            p.volt_param = format!("{vn}: {vp}&");
                            p.volt_args.push(format!("{vn}.h"));
                        } else {
                            // taken: the Rust value moves into the call, the handle is left empty
                            p.shim_arg = format!("*Box::from_raw({a} as *mut {rp})");
                            p.volt_param = format!("var {vn}: {vp}");
                            p.volt_pre.extend([format!("val {a} = {vn}.h;"), format!("{vn}.h = null;")]);
                            p.volt_args.push(a.clone());
                        }
                    }
                    Kind::Enum => {
                        if mutable {
                            return None;
                        }
                        p.shim_params.push(format!("{a}: i64"));
                        p.shim_arg = if by_ref { format!("&from_{mg}({a})") } else { format!("from_{mg}({a})") };
                        p.volt_param = format!("{vn}: {vp}");
                        p.volt_ext.push(format!("{a}: i64"));
                        p.volt_args.push(format!("{}::rust_shim::tag_{mg}({vn})", self.alias));
                    }
                }
            }
            _ => return None,
        }
        Some(p)
    }

    /// how a returned value of type t comes back through out parameters named o...
    fn out(&mut self, t: &Ty, o: &str) -> Option<Out> {
        let al = self.alias.clone();
        Some(match t {
            Ty::Prim(x) => Out {
                shim_params: vec![format!("{o}: *mut {x}")],
                shim_store: format!("*{o} = v;"),
                volt_ext: vec![format!("{o}: {x}*")],
                volt_locals: vec![format!("var {o}: {x} = {};", Self::zero(x))],
                volt_args: vec![format!("&{o}")],
                volt_value: o.to_string(),
                volt_ty: x.to_string(),
            },
            Ty::Char => Out {
                shim_params: vec![format!("{o}: *mut u32")],
                shim_store: format!("*{o} = v as u32;"),
                volt_ext: vec![format!("{o}: u32*")],
                volt_locals: vec![format!("var {o}: u32 = 0;")],
                volt_args: vec![format!("&{o}")],
                volt_value: o.to_string(),
                volt_ty: "u32".into(),
            },
            Ty::Str | Ty::String => Out {
                shim_params: vec![format!("{o}: *mut *mut u8"), format!("{o}_n: *mut usize")],
                shim_store: format!("put_str(v.to_string(), {o}, {o}_n);"),
                volt_ext: vec![format!("{o}: u8**"), format!("{o}_n: usize*")],
                volt_locals: vec![format!("var {o}: u8* = null;"), format!("var {o}_n: usize = 0;")],
                volt_args: vec![format!("&{o}"), format!("&{o}_n")],
                volt_value: format!("{al}::rust_shim::take({o}, {o}_n)"),
                volt_ty: "std::string".into(),
            },
            Ty::Slice(e, _) | Ty::Vec(e) if matches!(**e, Ty::Prim(_)) => {
                let Ty::Prim(x) = **e else { unreachable!() };
                self.vec_elems.insert(x);
                Out {
                    shim_params: vec![format!("{o}: *mut *mut {x}"), format!("{o}_n: *mut usize")],
                    shim_store: format!("put_vec(v.to_vec(), {o}, {o}_n);"),
                    volt_ext: vec![format!("{o}: {x}**"), format!("{o}_n: usize*")],
                    volt_locals: vec![format!("var {o}: {x}* = null;"), format!("var {o}_n: usize = 0;")],
                    volt_args: vec![format!("&{o}"), format!("&{o}_n")],
                    volt_value: format!("{al}::rust_shim::take_{x}s({o}, {o}_n)"),
                    volt_ty: format!("std::vec<{x}>"),
                }
            }
            Ty::Slice(e, _) | Ty::Vec(e) if matches!(**e, Ty::Str | Ty::String) => {
                self.strs = true;
                Out {
                    shim_params: vec![format!("{o}: *mut *mut VoltOwnedStr"), format!("{o}_n: *mut usize")],
                    shim_store: format!("put_strs(v.iter().map(|x| x.to_string()).collect(), {o}, {o}_n);"),
                    volt_ext: vec![format!("{o}: {al}::rust_shim::owned_str**"), format!("{o}_n: usize*")],
                    volt_locals: vec![format!("var {o}: {al}::rust_shim::owned_str* = null;"), format!("var {o}_n: usize = 0;")],
                    volt_args: vec![format!("&{o}"), format!("&{o}_n")],
                    volt_value: format!("{al}::rust_shim::take_strs({o}, {o}_n)"),
                    volt_ty: "std::vec<std::string>".into(),
                }
            }
            Ty::Named(_) | Ty::Ref(..) => {
                let (named, by_ref) = match t {
                    Ty::Ref(x, _) => (&**x, true),
                    x => (x, false),
                };
                let ti = self.info(named, None)?;
                let (vp, rp, mg) = (self.volt_path(&ti.def), self.rust_path(&ti.def), Self::mangle(&ti.def));
                match ti.kind {
                    Kind::Plain => Out {
                        shim_params: vec![format!("{o}: *mut V_{mg}")],
                        shim_store: format!("*{o} = to_{mg}(&v);"),
                        volt_ext: vec![format!("{o}: {vp}*")],
                        volt_locals: vec![format!("var {o}: {vp} = {{}};")],
                        volt_args: vec![format!("&{o}")],
                        volt_value: o.to_string(),
                        volt_ty: vp,
                    },
                    Kind::Handle => {
                        // a reference into Rust-owned data can't be handed out; a clone can
                        let store = if by_ref {
                            if !ti.clone {
                                return None;
                            }
                            format!("*{o} = Box::into_raw(Box::new(<{rp} as Clone>::clone(v))) as *mut c_void;")
                        } else {
                            format!("*{o} = Box::into_raw(Box::new(v)) as *mut c_void;")
                        };
                        Out {
                            shim_params: vec![format!("{o}: *mut *mut c_void")],
                            shim_store: store,
                            volt_ext: vec![format!("{o}: void**")],
                            volt_locals: vec![format!("var {o}: void* = null;")],
                            volt_args: vec![format!("&{o}")],
                            volt_value: format!("{al}::rust_shim::own_{mg}({o})"),
                            volt_ty: vp,
                        }
                    }
                    Kind::Enum => Out {
                        shim_params: vec![format!("{o}: *mut i64")],
                        shim_store: format!("*{o} = to_{mg}(&v);"),
                        volt_ext: vec![format!("{o}: i64*")],
                        volt_locals: vec![format!("var {o}: i64 = 0;")],
                        volt_args: vec![format!("&{o}")],
                        volt_value: format!("{al}::rust_shim::of_{mg}({o})"),
                        volt_ty: vp,
                    },
                }
            }
            Ty::Opt(inner) => {
                if matches!(**inner, Ty::Opt(_) | Ty::Res(_) | Ty::Unit) {
                    return None;
                }
                let x = self.out(inner, o)?;
                let mut shim_params = vec![format!("{o}_has: *mut bool")];
                shim_params.extend(x.shim_params);
                let mut volt_ext = vec![format!("{o}_has: bool*")];
                volt_ext.extend(x.volt_ext);
                let mut volt_locals = vec![format!("var {o}_has = false;")];
                volt_locals.extend(x.volt_locals);
                let mut volt_args = vec![format!("&{o}_has")];
                volt_args.extend(x.volt_args);
                Out {
                    shim_params,
                    shim_store: format!("match v {{ Some(v) => {{ *{o}_has = true; {} }} None => *{o}_has = false }}", x.shim_store),
                    volt_ext,
                    volt_locals,
                    volt_args,
                    // the caller tests {o}_has
                    volt_value: x.volt_value,
                    volt_ty: format!("{}?", x.volt_ty),
                }
            }
            _ => return None,
        })
    }

    /// a fn or method: its shim function, Volt extern declaration and Volt function
    fn function(&mut self, module: &[String], s: &Sig, self_ty: Option<&str>) -> Result<String, String> {
        let what = match self_ty {
            Some(t) => format!("{t}::{}", s.name),
            None => s.name.clone(),
        };
        if let Some(why) = s.skip {
            return Err(format!("{what} ({why})"));
        }
        let ti = self_ty.and_then(|t| self.types.get(t));
        if self_ty.is_some() && ti.is_none() {
            return Err(format!("{what} (its type isn't one Volt can name)"));
        }
        let mut path: Vec<&str> = module.iter().map(String::as_str).collect();
        if let Some(t) = self_ty {
            path.push(t);
        }
        path.push(&s.name);
        let sym = self.sym(&path);
        let mut params = Vec::new();
        // the receiver
        let mut recv_p: Option<Param> = None;
        if let (Some(ti), true) = (ti, s.recv != Recv::None) {
            let (vp, rp, mg, kind) = (self.volt_path(&ti.def), self.rust_path(&ti.def), Self::mangle(&ti.def), ti.kind);
            let mut p = Param::default();
            match kind {
                Kind::Plain => {
                    p.shim_params.push(format!("this: *mut V_{mg}"));
                    match s.recv {
                        Recv::Mut => {
                            p.shim_pre.push(format!("let mut this_v = from_{mg}(&*this);"));
                            p.shim_arg = "(&mut this_v)".into();
                            p.shim_post.push(format!("*this = to_{mg}(&this_v);"));
                        }
                        Recv::Ref => p.shim_arg = format!("(&from_{mg}(&*this))"),
                        _ => p.shim_arg = format!("from_{mg}(&*this)"),
                    }
                    p.volt_param = format!("this: {vp}&");
                    p.volt_ext.push(format!("a_this: {vp}*"));
                    p.volt_args.push("this".into());
                }
                Kind::Handle => {
                    p.shim_params.push("this: *mut c_void".into());
                    match s.recv {
                        Recv::Mut => p.shim_arg = format!("(&mut *(this as *mut {rp}))"),
                        Recv::Ref => p.shim_arg = format!("(&*(this as *const {rp}))"),
                        _ => p.shim_arg = format!("(*Box::from_raw(this as *mut {rp}))"),
                    }
                    p.volt_ext.push("a_this: void*".into());
                    p.volt_pre.push(Self::not_empty(&vp, "this.h"));
                    if s.recv == Recv::Value {
                        p.volt_param = format!("var this: {vp}");
                        p.volt_pre.extend(["val a_this = this.h;".to_string(), "this.h = null;".to_string()]);
                        p.volt_args.push("a_this".into());
                    } else {
                        p.volt_param = format!("this: {vp}&");
                        p.volt_args.push("this.h".into());
                    }
                }
                Kind::Enum => {
                    if s.recv == Recv::Mut {
                        return Err(format!("{what} (&mut self of an enum)"));
                    }
                    p.shim_params.push("this: i64".into());
                    p.shim_arg = if s.recv == Recv::Ref { format!("(&from_{mg}(this))") } else { format!("from_{mg}(this)") };
                    p.volt_param = format!("this: {vp}&");
                    p.volt_ext.push("a_this: i64".into());
                    p.volt_args.push(format!("{}::rust_shim::tag_{mg}(*this)", self.alias));
                }
            }
            recv_p = Some(p);
        }
        for (i, (n, t)) in s.params.iter().enumerate() {
            let ty = parse_ty(t).map(|t| self.resolve(t, self_ty)).ok_or(format!("{what} (parameter {n}'s type)"))?;
            params.push(self.param(n, &ty, i).ok_or(format!("{what} (parameter {n}'s type)"))?);
        }
        let ret = parse_ty(&s.ret).map(|t| self.resolve(t, self_ty)).ok_or(format!("{what} (its return type)"))?;
        let (res, val_ty) = match ret {
            Ty::Res(x) => (true, *x),
            x => (false, x),
        };
        let out = if val_ty == Ty::Unit { None } else { Some(self.out(&val_ty, "o").ok_or(format!("{what} (its return type)"))?) };
        if res {
            self.errors = true;
        }

        // the shim
        let mut sp: Vec<String> = recv_p.iter().chain(&params).flat_map(|p| p.shim_params.clone()).collect();
        if let Some(o) = &out {
            sp.extend(o.shim_params.clone());
        }
        if res {
            sp.extend(["e: *mut *mut u8".to_string(), "e_n: *mut usize".to_string()]);
        }
        let args: Vec<String> = params.iter().map(|p| p.shim_arg.clone()).collect();
        let call = match (&recv_p, self_ty) {
            (Some(r), _) => format!("{}.{}({})", r.shim_arg, s.name, args.join(", ")),
            (None, Some(t)) => format!("{}::{}({})", self.rust_path(&self.types[t].def), s.name, args.join(", ")),
            (None, None) => {
                let mut p = vec![self.m.lib.clone()];
                p.extend(module.iter().cloned());
                p.push(s.name.clone());
                format!("::{}({})", p.join("::"), args.join(", "))
            }
        };
        let pre: String = recv_p.iter().chain(&params).flat_map(|p| p.shim_pre.clone()).map(|l| format!("    {l}\n")).collect();
        let post: String = recv_p.iter().chain(&params).flat_map(|p| p.shim_post.clone()).map(|l| format!("    {l}\n")).collect();
        let store = out.as_ref().map_or(String::new(), |o| o.shim_store.clone());
        let body = if res {
            format!("{pre}    let r = {call};\n{post}    match r {{\n        Ok(v) => {{ let _ = &v; {store} true }}\n        Err(err) => {{ put_str(err.to_string(), e, e_n); false }}\n    }}\n")
        } else {
            format!("{pre}    let v = {call};\n{post}    let _ = &v;\n    {store}\n")
        };
        let _ = writeln!(self.shim, "#[no_mangle]\npub unsafe extern \"C\" fn {sym}({}){} {{\n{body}}}\n", sp.join(", "), if res { " -> bool" } else { "" });

        // the Volt extern declaration
        let mut ve: Vec<String> = recv_p.iter().chain(&params).flat_map(|p| p.volt_ext.clone()).collect();
        if let Some(o) = &out {
            ve.extend(o.volt_ext.clone());
        }
        if res {
            ve.extend(["e: u8**".to_string(), "e_n: usize*".to_string()]);
        }
        let _ = writeln!(self.ext, "    extern \"C\" fn {sym}({}) -> {};", ve.join(", "), if res { "bool" } else { "void" });

        // the Volt function
        let vt = out.as_ref().map_or("void".to_string(), |o| o.volt_ty.clone());
        let ret_ty = if res { format!("{}::rust_error!{}", self.alias, if vt.ends_with('?') { format!("({vt})") } else { vt.clone() }) } else { vt.clone() };
        let vps: Vec<String> = recv_p.iter().chain(&params).map(|p| p.volt_param.clone()).collect();
        let mut vargs: Vec<String> = recv_p.iter().chain(&params).flat_map(|p| p.volt_args.clone()).collect();
        let mut lines: Vec<String> = recv_p.iter().chain(&params).flat_map(|p| p.volt_pre.clone()).collect();
        if let Some(o) = &out {
            lines.extend(o.volt_locals.clone());
            vargs.extend(o.volt_args.clone());
        }
        if res {
            lines.extend(["var e: u8* = null;".to_string(), "var e_n: usize = 0;".to_string()]);
            vargs.extend(["&e".to_string(), "&e_n".to_string()]);
        }
        let ext_call = format!("{}::rust_shim::{sym}({})", self.alias, vargs.join(", "));
        let give = |o: &Out| -> Vec<String> {
            if o.volt_ty.ends_with('?') {
                vec![format!("if (o_has) {{ return {}; }}", o.volt_value), "return null;".into()]
            } else {
                vec![format!("return {};", o.volt_value)]
            }
        };
        if res {
            lines.push(format!("if ({ext_call}) {{"));
            match &out {
                Some(o) => lines.extend(give(o).into_iter().map(|l| format!("    {l}"))),
                None => lines.push("    return;".into()),
            }
            lines.push("}".into());
            lines.push(format!("return {}::rust_error::ERROR({}::rust_shim::take(e, e_n));", self.alias, self.alias));
        } else {
            lines.push(format!("{ext_call};"));
            if let Some(o) = &out {
                lines.extend(give(o));
            }
        }
        let head = match (self_ty, s.recv) {
            (Some(t), Recv::None) => {
                let vp = self.volt_path(&self.types[t].def);
                let mut ps = vec![format!("static this: {vp}")];
                ps.extend(vps);
                format!("attach fn {}({}) -> {ret_ty}", volt_name(&s.name), ps.join(", "))
            }
            (Some(_), _) => format!("attach fn {}({}) -> {ret_ty}", volt_name(&s.name), vps.join(", ")),
            (None, _) => format!("fn {}({}) -> {ret_ty}", volt_name(&s.name), vps.join(", ")),
        };
        let mut f = format!("{head} {{\n");
        for l in lines {
            f.push_str(&format!("    {l}\n"));
        }
        f.push_str("}\n");
        Ok(f)
    }

    /// a type's Volt declaration and its shim helpers
    fn type_decl(&mut self, name: &str) -> String {
        let ti = &self.types[name];
        let (vp, rp, mg, kind, clone) = (self.volt_path(&ti.def), self.rust_path(&ti.def), Self::mangle(&ti.def), ti.kind, ti.clone);
        let def = ti.def.clone();
        let al = self.alias.clone();
        let mut v = String::new();
        match kind {
            Kind::Plain => {
                let fields = def.fields.clone().unwrap_or_default();
                let mut vf = String::new();
                let mut rf = String::new();
                let mut from = String::new();
                let mut to = String::new();
                for (f, _, t) in &fields {
                    let t = parse_ty(t).unwrap_or(Ty::Unit);
                    let fv = volt_name(f);
                    match &t {
                        Ty::Prim(x) => {
                            let _ = writeln!(vf, "    {fv}: {x} = {};", Self::zero(x));
                            let _ = writeln!(rf, "    pub {f}: {x},");
                            let _ = write!(from, "{f}: v.{f}, ");
                            let _ = write!(to, "{f}: v.{f}, ");
                        }
                        Ty::Char => {
                            let _ = writeln!(vf, "    {fv}: u32 = 0;");
                            let _ = writeln!(rf, "    pub {f}: u32,");
                            let _ = write!(from, "{f}: char::from_u32(v.{f}).unwrap_or('\\u{{fffd}}'), ");
                            let _ = write!(to, "{f}: v.{f} as u32, ");
                        }
                        Ty::Named(n) => {
                            let o = &self.types[n];
                            let (ovp, omg) = (self.volt_path(&o.def), Self::mangle(&o.def));
                            if o.kind == Kind::Enum {
                                let first = o.def.variants.as_ref().and_then(|vs| vs.first()).map_or(String::new(), |x| volt_name(&x.0));
                                let _ = writeln!(vf, "    {fv}: {ovp} = {ovp}::{first};");
                                let _ = writeln!(rf, "    pub {f}: i64,");
                                let _ = write!(from, "{f}: from_{omg}(v.{f}), ");
                                let _ = write!(to, "{f}: to_{omg}(&v.{f}), ");
                            } else {
                                let _ = writeln!(vf, "    {fv}: {ovp} = {{}};");
                                let _ = writeln!(rf, "    pub {f}: V_{omg},");
                                let _ = write!(from, "{f}: from_{omg}(&v.{f}), ");
                                let _ = write!(to, "{f}: to_{omg}(&v.{f}), ");
                            }
                        }
                        _ => {}
                    }
                }
                let _ = write!(v, "struct {} {{\n{vf}}}\n", def.name);
                let _ = write!(self.shim, "#[repr(C)]\n#[derive(Clone, Copy)]\npub struct V_{mg} {{\n{rf}}}\nfn from_{mg}(v: &V_{mg}) -> {rp} {{ {rp} {{ {from}}} }}\nfn to_{mg}(v: &{rp}) -> V_{mg} {{ V_{mg} {{ {to}}} }}\n\n");
            }
            Kind::Handle => {
                let drop = self.sym(&[&mg, "drop"]);
                let _ = write!(v, "// a Rust {} (owned: deleting it drops it)\nstruct {} {{\n    h: void* = null;\n}}\n\nattach fn delete(this: {vp}&) -> void {{\n    if (this.h != null) {{\n        {al}::rust_shim::{drop}(this.h);\n        this.h = null;\n    }}\n}}\n", def.name, def.name);
                let _ = writeln!(self.shim, "#[no_mangle]\npub unsafe extern \"C\" fn {drop}(h: *mut c_void) {{ drop(Box::from_raw(h as *mut {rp})) }}\n");
                let _ = writeln!(self.ext, "    extern \"C\" fn {drop}(h: void*) -> void;");
                if clone {
                    let cl = self.sym(&[&mg, "clone"]);
                    let _ = write!(v, "\nattach fn copy(this: {vp}&) -> {vp} {{\n    if (this.h == null) {{\n        return {{}};\n    }}\n    return {{ h: {al}::rust_shim::{cl}(this.h) }};\n}}\n");
                    let _ = writeln!(self.shim, "#[no_mangle]\npub unsafe extern \"C\" fn {cl}(h: *mut c_void) -> *mut c_void {{ Box::into_raw(Box::new((*(h as *const {rp})).clone())) as *mut c_void }}\n");
                    let _ = writeln!(self.ext, "    extern \"C\" fn {cl}(h: void*) -> void*;");
                }
                let _ = write!(self.helpers, "    fn own_{mg}(h: void*) -> {vp} {{\n        return {{ h: h }};\n    }}\n");
            }
            Kind::Enum => {
                let vs = def.variants.clone().unwrap_or_default();
                let mut body = String::new();
                for (n, x) in &vs {
                    let _ = writeln!(body, "    {} = {x},", volt_name(n));
                }
                let _ = write!(v, "enum {}: i64 {{\n{body}}}\n", def.name);
                let mut tag = format!("    fn tag_{mg}(x: {vp}) -> i64 {{\n        match (x) {{\n");
                let mut of = format!("    fn of_{mg}(x: i64) -> {vp} {{\n");
                let mut from = format!("fn from_{mg}(x: i64) -> {rp} {{\n    match x {{\n");
                let mut to = format!("fn to_{mg}(x: &{rp}) -> i64 {{\n    match x {{\n");
                for (n, x) in &vs {
                    let _ = writeln!(tag, "            .{} => {{ return {x}; }},", volt_name(n));
                    let _ = writeln!(of, "        if (x == {x}) {{\n            return {vp}::{};\n        }}", volt_name(n));
                    let _ = writeln!(from, "        {x} => {rp}::{n},");
                    let _ = writeln!(to, "        {rp}::{n} => {x},");
                }
                let first = vs.first().map_or(String::new(), |x| x.0.clone());
                tag.push_str("        }\n    }\n");
                let _ = write!(of, "        return {vp}::{};\n    }}\n", volt_name(&first));
                let _ = write!(from, "        _ => {rp}::{first},\n    }}\n}}\n");
                let _ = writeln!(to, "        _ => {},", vs.first().map_or(0, |x| x.1));
                to.push_str("    }\n}\n");
                self.helpers.push_str(&tag);
                self.helpers.push_str(&of);
                let _ = write!(self.shim, "{from}{to}\n");
            }
        }
        v
    }

    fn write(mut self) -> (String, String) {
        let names: Vec<String> = self.types.keys().cloned().collect();
        for n in &names {
            let module = self.types[n].def.module.clone();
            let d = self.type_decl(n);
            self.modules.entry(module).or_default().push_str(&format!("\n{d}"));
        }
        for n in &names {
            let module = self.types[n].def.module.clone();
            for s in self.m.methods.get(n).cloned().unwrap_or_default() {
                match self.function(&module, &s, Some(n)) {
                    Ok(f) => self.modules.entry(module.clone()).or_default().push_str(&format!("\n{f}")),
                    Err(why) => self.left_out.push(why),
                }
            }
        }
        for (module, s) in self.m.fns.clone() {
            match self.function(&module, &s, None) {
                Ok(f) => self.modules.entry(module.clone()).or_default().push_str(&format!("\n{f}")),
                Err(why) => self.left_out.push(why),
            }
        }
        for (module, name, t, value) in self.m.consts.clone() {
            let lit: Option<(String, String)> = match (parse_ty(&t), value.as_slice()) {
                (Some(Ty::Prim(x)), v) if int_value(v).is_some() && x != "bool" => Some((x.to_string(), int_value(v).unwrap().to_string())),
                (Some(Ty::Prim(x)), [Tok::Num(n)]) if x.starts_with('f') => Some((x.to_string(), n.trim_end_matches("f64").trim_end_matches("f32").to_string())),
                (Some(Ty::Prim("bool")), [Tok::Id(b)]) if b == "true" || b == "false" => Some(("bool".into(), b.clone())),
                (Some(Ty::Str), [Tok::Str(s)]) => Some(("str".into(), format!("\"{s}\""))),
                _ => None,
            };
            match lit {
                Some((ty, v)) => self.modules.entry(module).or_default().push_str(&format!("\nval {}: {ty} = {v};\n", volt_name(&name))),
                None => self.left_out.push(format!("const {name} (not a number, bool or string literal)")),
            }
        }
        for t in &self.m.types {
            if t.generic {
                self.left_out.push(format!("{} (it's generic)", t.name));
            }
        }

        // the shim's helpers
        let al = self.alias.clone();
        let mut shim = String::from("// the glue between a Volt program and this crate, written by bolt import (use rust)\n#![allow(non_snake_case, unused_unsafe, unused_mut, unused_variables, unreachable_patterns, clippy::all)]\nuse std::ffi::c_void;\n\n");
        shim.push_str("#[repr(C)]\npub struct VoltStr {\n    p: *const u8,\n    n: usize,\n}\n#[repr(C)]\npub struct VoltOwnedStr {\n    p: *mut u8,\n    n: usize,\n}\n\n");
        shim.push_str("unsafe fn s<'a>(p: *const u8, n: usize) -> &'a str {\n    if n == 0 {\n        return \"\";\n    }\n    let b = std::slice::from_raw_parts(p, n);\n    match std::str::from_utf8(b) {\n        Ok(s) => s,\n        Err(e) => std::str::from_utf8_unchecked(&b[..e.valid_up_to()]),\n    }\n}\n");
        shim.push_str("unsafe fn sl<'a, T>(p: *const T, n: usize) -> &'a [T] {\n    if n == 0 { &[] } else { std::slice::from_raw_parts(p, n) }\n}\nunsafe fn slm<'a, T>(p: *mut T, n: usize) -> &'a mut [T] {\n    if n == 0 { &mut [] } else { std::slice::from_raw_parts_mut(p, n) }\n}\n");
        shim.push_str("unsafe fn strs<'a>(p: *const VoltStr, n: usize) -> Vec<&'a str> {\n    sl(p, n).iter().map(|x| s(x.p, x.n)).collect()\n}\n");
        shim.push_str("unsafe fn put_str(v: String, p: *mut *mut u8, n: *mut usize) {\n    let b = v.into_bytes().into_boxed_slice();\n    *n = b.len();\n    *p = Box::into_raw(b) as *mut u8;\n}\n");
        shim.push_str("unsafe fn put_vec<T>(v: Vec<T>, p: *mut *mut T, n: *mut usize) {\n    let b = v.into_boxed_slice();\n    *n = b.len();\n    *p = Box::into_raw(b) as *mut T;\n}\n");
        shim.push_str("unsafe fn put_strs(v: Vec<String>, p: *mut *mut VoltOwnedStr, n: *mut usize) {\n    let xs: Vec<VoltOwnedStr> = v.into_iter().map(|x| { let mut q = std::ptr::null_mut(); let mut m = 0; put_str(x, &mut q, &mut m); VoltOwnedStr { p: q, n: m } }).collect();\n    put_vec(xs, p, n);\n}\n\n");
        let free_bytes = format!("volt_rs_{al}_free_bytes");
        let _ = writeln!(shim, "#[no_mangle]\npub unsafe extern \"C\" fn {free_bytes}(p: *mut u8, n: usize) {{\n    if !p.is_null() {{\n        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, n)));\n    }}\n}}\n");
        let mut ext = format!("    extern \"C\" fn {free_bytes}(p: u8*, n: usize) -> void;\n");
        let mut helpers = format!("    // Rust's bytes as a std::string; Rust's copy is freed\n    fn take(p: u8*, n: usize) -> std::string {{\n        if (n == 0) {{\n            return std::string::from(\"\");\n        }}\n        val s = std::string::from(@cast<str>(@slice(p, n)));\n        {free_bytes}(p, n);\n        return s;\n    }}\n");
        for x in &self.vec_elems {
            let f = format!("volt_rs_{al}_free_{x}s");
            let _ = writeln!(shim, "#[no_mangle]\npub unsafe extern \"C\" fn {f}(p: *mut {x}, n: usize) {{\n    if !p.is_null() {{\n        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, n)));\n    }}\n}}\n");
            let _ = writeln!(ext, "    extern \"C\" fn {f}(p: {x}*, n: usize) -> void;");
            let _ = write!(helpers, "    fn take_{x}s(p: {x}*, n: usize) -> std::vec<{x}> {{\n        var out: std::vec<{x}> = {{}};\n        if (n == 0) {{\n            return out;\n        }}\n        for (x) in @slice(p, n) {{\n            out.push(x) catch @panic(\"out of memory\");\n        }}\n        {f}(p, n);\n        return out;\n    }}\n");
        }
        if self.strs {
            let f = format!("volt_rs_{al}_free_strs");
            let _ = writeln!(shim, "#[no_mangle]\npub unsafe extern \"C\" fn {f}(p: *mut VoltOwnedStr, n: usize) {{\n    if !p.is_null() {{\n        for x in Box::from_raw(std::ptr::slice_from_raw_parts_mut(p, n)).iter() {{\n            {free_bytes}(x.p, x.n);\n        }}\n    }}\n}}\n");
            let _ = writeln!(ext, "    extern \"C\" fn {f}(p: owned_str*, n: usize) -> void;");
            let _ = write!(helpers, "    struct owned_str {{\n        p: u8*;\n        n: usize;\n    }}\n\n    fn take_strs(p: owned_str*, n: usize) -> std::vec<std::string> {{\n        var out: std::vec<std::string> = {{}};\n        if (n == 0) {{\n            return out;\n        }}\n        for (x) in @slice(p, n) {{\n            out.push(std::string::from(@cast<str>(@slice(x.p, x.n)))) catch @panic(\"out of memory\");\n        }}\n        {f}(p, n);\n        return out;\n    }}\n");
        }
        shim.push_str(&self.shim);
        helpers.push_str(&self.helpers);

        // the Volt source: the glue's declarations, then the crate's modules as namespaces
        let mut volt = format!("// use rust {{ ... }} as {al}: the crate's public API, called through its shim (written by bolt import)\n\nnamespace rust_shim {{\n{ext}{}\n{helpers}}}\n", self.ext);
        if self.errors {
            volt.push_str("\n// a Rust Err, as its to_string()\nerror rust_error {\n    ERROR: std::string,\n}\n");
        }
        volt.push_str(&nest(&self.modules));
        if !self.left_out.is_empty() {
            volt.push_str("\n// left out (Volt can't call these):\n");
            for l in &self.left_out {
                let _ = writeln!(volt, "//   {l}");
            }
        }
        (shim, volt)
    }
}

/// the modules' sources as nested namespaces
fn nest(modules: &BTreeMap<Vec<String>, String>) -> String {
    fn go(modules: &BTreeMap<Vec<String>, String>, at: &[String], depth: usize, out: &mut String) {
        if let Some(s) = modules.get(at) {
            for line in s.lines() {
                if line.is_empty() {
                    out.push('\n');
                } else {
                    out.push_str(&"    ".repeat(depth));
                    out.push_str(line);
                    out.push('\n');
                }
            }
        }
        let children: BTreeSet<&String> = modules.keys().filter(|k| k.len() > at.len() && k[..at.len()] == *at).map(|k| &k[at.len()]).collect();
        for c in children {
            let mut sub = at.to_vec();
            sub.push(c.clone());
            let _ = write!(out, "\n{}namespace {} {{\n", "    ".repeat(depth), volt_name(c));
            go(modules, &sub, depth + 1, out);
            let _ = writeln!(out, "{}}}", "    ".repeat(depth));
        }
    }
    let mut out = String::new();
    go(modules, &[], 0, &mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ty(s: &str) -> Option<Ty> {
        parse_ty(&lex(s))
    }

    #[test]
    fn import_types() {
        assert_eq!(ty("&str"), Some(Ty::Str));
        assert_eq!(ty("&'a str"), Some(Ty::Str));
        assert_eq!(ty("String"), Some(Ty::String));
        assert_eq!(ty("&[f64]"), Some(Ty::Slice(Box::new(Ty::Prim("f64")), false)));
        assert_eq!(ty("&mut [u8]"), Some(Ty::Slice(Box::new(Ty::Prim("u8")), true)));
        assert_eq!(ty("Vec<String>"), Some(Ty::Vec(Box::new(Ty::String))));
        assert_eq!(ty("Option<usize>"), Some(Ty::Opt(Box::new(Ty::Prim("usize")))));
        assert_eq!(ty("Result<i64, std::num::ParseIntError>"), Some(Ty::Res(Box::new(Ty::Prim("i64")))));
        assert_eq!(ty("&mut Shape"), Some(Ty::Ref(Box::new(Ty::Named("Shape".into())), true)));
        assert_eq!(ty("shapes::Shape"), Some(Ty::Named("Shape".into())));
        assert_eq!(ty("()"), Some(Ty::Unit));
        assert_eq!(ty("HashMap<String, i32>"), None);
        assert_eq!(ty("impl Fn(i32) -> i32"), None);
        assert_eq!(ty("(i32, i32)"), None);
    }

    #[test]
    fn import_signatures() {
        let s = sig(&lex("pub fn scale(&mut self, k: f64) -> Self"));
        assert!(s.recv == Recv::Mut && s.params.len() == 1 && s.params[0].0 == "k" && s.skip.is_none());
        let s = sig(&lex("pub fn first<'a>(s: &'a str) -> &'a str"));
        assert!(s.recv == Recv::None && s.skip.is_none() && ty_text(&s.ret) == "&str");
        assert_eq!(sig(&lex("pub fn id<T>(x: T) -> T")).skip, Some("it's generic"));
        assert!(sig(&lex("pub fn into_name(self) -> String")).recv == Recv::Value);
        assert!(sig(&lex("pub fn area(&self) -> f64")).recv == Recv::Ref);
    }

    fn ty_text(t: &[Tok]) -> String {
        t.iter().map(tok_text).collect()
    }

    #[test]
    fn import_walks_modules_and_impls() {
        let mut m = Model { lib: "geom".into(), ..Model::default() };
        let src = "pub mod shapes { #[derive(Clone)] pub struct Shape { name: String } impl Shape { pub fn new(n: &str) -> Self { todo!() } fn private(&self) {} } }\n#[derive(Clone, Copy)] pub struct Point { pub x: f64, pub y: f64 }\npub enum Color { Red, Green = 5, Blue }\n#[cfg(test)] mod tests { pub fn t() {} }\npub(crate) fn hidden() {}\npub const LIMIT: i32 = -3;";
        m.walk(&lex(src), &[], Path::new("/none"));
        let names: Vec<String> = m.types.iter().map(|t| format!("{}::{}", t.module.join("::"), t.name)).collect();
        assert_eq!(names, ["shapes::Shape", "::Point", "::Color"]);
        assert_eq!(m.methods["Shape"].len(), 1);
        assert!(m.fns.is_empty(), "the cfg(test) and pub(crate) fns aren't visible");
        assert_eq!(m.types[2].variants, Some(vec![("Red".into(), 0), ("Green".into(), 5), ("Blue".into(), 6)]));
        let g = Gen::new(&m, "geom");
        assert_eq!(g.types["Point"].kind, Kind::Plain);
        assert_eq!(g.types["Shape"].kind, Kind::Handle);
        assert!(g.types["Shape"].clone);
        assert_eq!(g.types["Color"].kind, Kind::Enum);
        let (_, volt) = g.write();
        assert!(volt.contains("namespace shapes {") && volt.contains("attach fn new(static this: geom::shapes::Shape, n: str) -> geom::shapes::Shape") && volt.contains("val LIMIT: i32 = -3;"), "{volt}");
    }
}
