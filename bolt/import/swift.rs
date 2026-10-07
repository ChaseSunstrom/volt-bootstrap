// use { "file.swift" } as NAME; — ordinary Swift, called from Volt. bolt reads the files' top-level
// declarations (funcs; structs, classes and enums with their initializers, methods and properties;
// lets of literals), all but the private and fileprivate ones, writes a shim of @_cdecl functions
// that call them, compiled into the same module (so internal declarations count), builds both with
// swiftc -emit-library, and writes the Volt side (glue.rs). Nothing in the Swift code changes.
//
//   Int, UInt -> isize, usize; Int8...UInt64, Double, Float, Bool -> the same sizes
//   String -> str in, std::string out; [T] -> T[..] in, std::vec<T> out (numbers and strings)
//   T? -> T?; throws -> swift_error!T (the error, described); inout S -> S& (a struct)
//   a struct whose stored properties are all plain, and that has no init of its own -> a Volt
//   struct, by value; a class -> an owned handle whose copy shares the object (Swift's
//   references); any other struct, or an enum with associated values -> a handle whose copy copies
//   the value; an enum without them -> a Volt enum (raw Int values kept)
//   init(...) -> T::new(...), a second init T::new_<its first label>(...); a computed property,
//   or a class's stored one -> a method without arguments
use super::glue::{number, prim, Gen, Kind, Lang, Model, Recv, ShimOut, ShimParam, Sig, Ty, TypeDef, TypeInfo};
use super::{arg_path, fresh, save, stamp, Made, Req};
use crate::foreign::{int_value, lex, Cur, Tok};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write;
use std::path::PathBuf;
use std::process::Command;

pub fn import(r: &Req) -> Result<(), String> {
    if r.args.is_empty() {
        return Err(format!("use {{ \"file.swift\" }} as {}: name the Swift files", r.alias));
    }
    let files: Vec<PathBuf> = r.args.iter().map(|a| arg_path(r, a)).collect();
    if let Some(f) = files.iter().find(|f| !f.is_file()) {
        return Err(format!("use swift: there's no {}", f.display()));
    }
    let swiftc = std::env::var("SWIFTC").unwrap_or_else(|_| "swiftc".into());
    let names: Vec<String> = files.iter().map(|f| f.display().to_string()).collect();
    let st = stamp(&files, &format!("swift {} {} release={} {swiftc}", r.alias, names.join(" "), r.release));
    if fresh(r, &st) {
        return Ok(());
    }

    let mut p = Parser::default();
    for f in &files {
        let text = std::fs::read_to_string(f).map_err(|e| format!("use swift: can't read {}: {e}", f.display()))?;
        p.decls(&lex(&plain_strings(&text)), None, false);
    }
    let (model, swift) = p.finish();
    let (shim, volt) = Gen::new(&model, &r.alias, &swift).write(if files.len() == 1 { "the file" } else { "the files" });

    let shim_file = r.out.join("shim.swift");
    crate::build::write_if_changed(&shim_file, &shim)?;
    // a shared library: swiftc links the Swift runtime it needs (and its runpath) itself
    // ponytail: the program loads it from bolt's cache; a static build if programs move elsewhere
    let lib = r.out.join(format!("libvolt_import_{}.so", r.alias));
    let mut c = Command::new(&swiftc);
    c.args(["-emit-library", "-parse-as-library", "-suppress-warnings", "-module-name"]).arg(format!("volt_swift_{}", r.alias));
    c.arg(if r.release { "-O" } else { "-Onone" });
    c.args(&files).arg(&shim_file).arg("-o").arg(&lib);
    let o = c.output().map_err(|e| format!("use swift: can't run {swiftc}: {e} (set $SWIFTC to the swiftc to use)"))?;
    if !o.status.success() {
        return Err(format!("use swift: swiftc couldn't build the glue for {}:\n{}", names.join(", "), String::from_utf8_lossy(&o.stderr)));
    }
    save(r, &Made { volt, flags: vec![lib.display().to_string(), format!("-Wl,-rpath,{}", r.out.display())], deps: files }, &st)
}

// ---------- the files' declarations ----------

/// what can come before a declaration's keyword
const MODIFIERS: &[&str] = &[
    "public", "open", "internal", "package", "private", "fileprivate", "final", "static", "class", "mutating", "nonmutating", "override", "required", "convenience", "lazy", "weak", "unowned",
    "indirect", "nonisolated", "dynamic", "optional", "consuming", "borrowing",
];

/// what a declaration starts with (past its attributes and modifiers)
const KEYWORDS: &[&str] = &[
    "func", "init", "deinit", "subscript", "struct", "class", "enum", "extension", "protocol", "actor", "let", "var", "case", "import", "typealias", "associatedtype", "operator", "precedencegroup",
    "macro",
];

#[derive(Default)]
struct Parser {
    m: Model,
    /// a type's declaration index in m.types
    at: BTreeMap<String, usize>,
    /// the argument labels of each function, by (type or "", name): "_" when there's none
    labels: BTreeMap<(String, String), Vec<String>>,
    /// properties read as methods, and initializers (T::new...), by (type, name)
    props: BTreeSet<(String, String)>,
    inits: BTreeSet<(String, String)>,
    classes: BTreeSet<String>,
    /// enums with Int raw values (enum E: Int), whose cases keep them
    raw: BTreeSet<String>,
    /// structs Volt can't build by value: an init of their own, or a let with a value
    not_plain: BTreeSet<String>,
    /// structs whose memberwise init isn't read (a lazy var), and enums whose raw values aren't
    /// all literals (their cases are numbered in order instead)
    no_memberwise: BTreeSet<String>,
    raw_lost: BTreeSet<String>,
    /// types with an init in their own body (no implicit ones), and each type's stored properties:
    /// name, type, whether it has a value, is a let, is private
    has_init: BTreeSet<String>,
    stored: BTreeMap<String, Vec<(String, Option<Ty>, bool, bool, bool)>>,
    /// the names taken in each scope (a type, or "")
    taken: BTreeSet<(String, String)>,
}

/// a declaration's modifiers
#[derive(Default, Clone, Copy)]
struct Mods {
    private: bool,
    is_static: bool,
    mutating: bool,
    lazy: bool,
    /// why Volt can't call it: an attribute says it's isolated to an actor, or unavailable
    barred: Option<&'static str>,
}

impl Parser {
    fn finish(mut self) -> (Model, Swift) {
        self.implicit_inits();
        for t in &mut self.m.types {
            if self.raw_lost.contains(&t.name) {
                if let Some(vs) = &mut t.variants {
                    for (i, v) in vs.iter_mut().enumerate() {
                        v.1 = i as i128;
                    }
                }
            }
            // a class is a reference: its handle's copy shares it (a retain); any other handle copies
            t.clone = true;
            t.opaque = self.classes.contains(&t.name) || self.not_plain.contains(&t.name);
        }
        let swift = Swift { labels: self.labels, props: self.props, inits: self.inits, classes: self.classes };
        (self.m, swift)
    }

    /// the inits Swift writes itself for a type without its own: T() when every stored property
    /// has a value, and a struct's memberwise init (unless a property is private)
    fn implicit_inits(&mut self) {
        let types: Vec<(String, bool)> = self.m.types.iter().filter(|t| !t.is_enum && !t.generic).map(|t| (t.name.clone(), self.classes.contains(&t.name))).collect();
        for (t, class) in types {
            if self.has_init.contains(&t) {
                continue;
            }
            let props = self.stored.get(&t).cloned().unwrap_or_default();
            let mut sigs = Vec::new();
            if props.iter().all(|p| p.2) {
                sigs.push((Vec::new(), Vec::new()));
            }
            // a let with a value isn't one of the memberwise init's parameters
            let members: Vec<_> = props.iter().filter(|p| !(p.3 && p.2)).collect();
            if !class && !members.is_empty() && !props.iter().any(|p| p.4) && !self.no_memberwise.contains(&t) {
                sigs.push((members.iter().map(|p| (p.0.clone(), p.1.clone())).collect(), members.iter().map(|p| p.0.clone()).collect()));
            }
            for (params, labels) in sigs {
                let name = if self.taken.contains(&(t.clone(), "new".to_string())) { format!("new_{}", labels.first().cloned().unwrap_or_default()) } else { "new".into() };
                let s = Sig { name: name.clone(), recv: Recv::None, params, ret: Some(Ty::SelfTy), skip: None, src: String::new(), generics: Vec::new(), call: None };
                self.inits.insert((t.clone(), name));
                self.add(Some(&t), s, labels);
            }
        }
    }

    /// whether `class` at c is a modifier (class func, class var) rather than a class
    fn class_modifier(c: &Cur) -> bool {
        matches!(c.t.get(c.i + 1), Some(Tok::Id(w)) if ["func", "var", "let", "subscript", "final", "override", "static"].contains(&w.as_str()))
    }

    /// the declaration that starts at c: its attributes and modifiers are skipped
    fn mods(c: &mut Cur) -> Mods {
        let mut m = Mods::default();
        loop {
            match c.peek() {
                Some(Tok::Id(w)) if w.starts_with('@') => {
                    // @MainActor and other global actors: the shim's calls aren't on that actor
                    if w.ends_with("Actor") {
                        m.barred = Some("it's isolated to an actor");
                    }
                    let available = w == "@available";
                    c.i += 1;
                    if c.is("(") {
                        let s = c.i;
                        c.skip_group();
                        if available && c.t[s..c.i].iter().any(|x| matches!(x, Tok::Id(w) if w == "unavailable" || w == "obsoleted")) {
                            m.barred = Some("it's marked unavailable");
                        }
                    }
                }
                Some(Tok::Id(w)) if MODIFIERS.contains(&w.as_str()) && (w != "class" || Self::class_modifier(c)) => {
                    let w = w.clone();
                    c.i += 1;
                    // private(set): only the setter is private
                    if c.is("(") {
                        c.skip_group();
                        continue;
                    }
                    match w.as_str() {
                        "private" | "fileprivate" => m.private = true,
                        "static" | "class" => m.is_static = true,
                        "mutating" => m.mutating = true,
                        "lazy" => m.lazy = true,
                        _ => {}
                    }
                }
                _ => return m,
            }
        }
    }

    /// whether c is at the start of a declaration
    fn at_decl(c: &Cur) -> bool {
        c.is("#") || matches!(c.peek(), Some(Tok::Id(w)) if w.starts_with('@') || MODIFIERS.contains(&w.as_str()) || KEYWORDS.contains(&w.as_str()))
    }

    /// past what's left of a declaration (or a statement): to the start of the next one
    fn skip(c: &mut Cur) {
        let start = c.i;
        while c.i < c.t.len() && (c.i == start || !Self::at_decl(c)) {
            if c.is("(") || c.is("[") || c.is("{") {
                c.skip_group();
            } else {
                c.i += 1;
            }
        }
    }

    /// the tokens of a type, up to what ends it: a `{`, `=`, `where` or the next declaration
    fn ty_tokens(c: &mut Cur) -> Vec<Tok> {
        let s = c.i;
        while c.i < c.t.len() && !c.is("{") && !c.is("=") && !c.is(",") && !c.is_id("where") && !(c.i > s && Self::at_decl(c)) {
            if c.is("(") || c.is("[") || c.is("<") {
                c.skip_group();
            } else {
                c.i += 1;
            }
        }
        c.t[s..c.i].to_vec()
    }

    /// a scope's declarations: a file's, or a type's body (`owner`); `ext`: an extension's body
    fn decls(&mut self, t: &[Tok], owner: Option<&str>, ext: bool) {
        let mut c = Cur { t, i: 0 };
        while c.i < t.len() {
            let start = c.i;
            // #if ... #endif: swiftc picks the branch, so what's under it is left out
            if c.is("#") {
                c.i += 1;
                if c.is_id("if") {
                    let mut depth = 1; // this #if
                    while c.i < t.len() {
                        if c.is("#") && matches!(t.get(c.i + 1), Some(Tok::Id(w)) if w == "if" || w == "endif") {
                            let open = matches!(t.get(c.i + 1), Some(Tok::Id(w)) if w == "if");
                            c.i += 2;
                            depth += if open { 1 } else { -1 };
                            if depth == 0 {
                                break;
                            }
                        } else if c.is("(") || c.is("[") || c.is("{") {
                            c.skip_group();
                        } else {
                            c.i += 1;
                        }
                    }
                    self.m.left_out.push(format!("what's under #if in {} (swiftc decides which branch is in)", owner.unwrap_or("the file")));
                } else {
                    // #warning("..."), #sourceLocation(...)
                    c.id();
                    if c.is("(") {
                        c.skip_group();
                    }
                }
                continue;
            }
            let m = Self::mods(&mut c);
            let kw = match c.peek() {
                Some(Tok::Id(w)) => w.clone(),
                _ => {
                    Self::skip(&mut c);
                    continue;
                }
            };
            match kw.as_str() {
                "func" => self.func(&mut c, owner, m),
                "init" => self.init(&mut c, owner, m, ext),
                "struct" | "class" | "enum" | "extension" | "protocol" | "actor" => {
                    if owner.is_some() {
                        let name = match c.t.get(c.i + 1) {
                            Some(Tok::Id(n)) => n.clone(),
                            _ => String::new(),
                        };
                        if !m.private {
                            self.m.left_out.push(format!("{}.{name} (a nested type)", owner.unwrap_or_default()));
                        }
                        Self::skip(&mut c);
                    } else {
                        self.type_decl(&mut c, &kw, m);
                    }
                }
                "let" | "var" => self.property(&mut c, owner, m, ext),
                "case" if owner.is_some_and(|o| self.at.get(o).is_some_and(|&i| self.m.types[i].is_enum)) => self.case(&mut c, owner.unwrap_or_default()),
                "import" => {
                    // import Foundation, import struct Foo.Bar: a dotted path
                    c.i += 1;
                    if c.is_id("struct") || c.is_id("class") || c.is_id("enum") || c.is_id("func") || c.is_id("var") || c.is_id("let") || c.is_id("protocol") || c.is_id("typealias") {
                        c.i += 1;
                    }
                    c.id();
                    while c.eat(".") {
                        c.id();
                    }
                }
                _ => Self::skip(&mut c),
            }
            if c.i == start {
                c.i += 1;
            }
        }
    }

    /// a name in a scope, unless it's taken: Volt (and the shim's symbols) have one of each
    fn take(&mut self, owner: Option<&str>, name: &str) -> bool {
        self.taken.insert((owner.unwrap_or_default().to_string(), name.to_string()))
    }

    fn add(&mut self, owner: Option<&str>, s: Sig, labels: Vec<String>) {
        let who = match owner {
            Some(o) => format!("{o}.{}", s.name),
            None => s.name.clone(),
        };
        if !spellable(&s.name) {
            self.m.left_out.push(format!("{who} (its name isn't one Volt can spell)"));
            return;
        }
        if owner.is_some() && (s.name == "drop" || s.name == "clone") {
            self.m.left_out.push(format!("{who} (the glue's own name for the handle)"));
            return;
        }
        if !self.take(owner, &s.name) {
            self.m.left_out.push(format!("{who} (an overload: Volt has the first one of that name)"));
            return;
        }
        self.labels.insert((owner.unwrap_or_default().to_string(), s.name.clone()), labels);
        match owner {
            Some(o) => self.m.methods.entry(o.to_string()).or_default().push(s),
            None => self.m.fns.push((Vec::new(), s)),
        }
    }

    /// a parameter list: Volt's (name, type) and the call's labels
    fn params(items: &[Vec<Tok>], owner: Option<&str>, s: &mut Sig) -> Vec<String> {
        let mut labels = Vec::new();
        for (n, p) in items.iter().enumerate() {
            let Some(colon) = p.iter().position(|x| *x == Tok::P(":".into())) else {
                s.skip = Some("a parameter");
                continue;
            };
            let names: Vec<&str> = p[..colon].iter().filter_map(|x| if let Tok::Id(w) = x { Some(w.as_str()) } else { None }).collect();
            let (label, name) = match names.as_slice() {
                [l, n] => (l.to_string(), n.to_string()),
                [n] => (n.to_string(), n.to_string()),
                _ => ("_".to_string(), String::new()),
            };
            let pname = if name.is_empty() || name == "_" || !spellable(&name) { format!("a{n}") } else { name };
            // its type, up to a default value
            // (a variadic Int... isn't a type parse_ty knows)
            let mut c = Cur { t: &p[colon + 1..], i: 0 };
            let tt = Self::ty_tokens(&mut c);
            labels.push(label);
            s.params.push((pname, parse_ty(&tt, owner)));
        }
        labels
    }

    /// func NAME[<...>](params) [async] [throws] [-> T] [where ...] { ... }
    fn func(&mut self, c: &mut Cur, owner: Option<&str>, m: Mods) {
        c.i += 1;
        let Some(name) = c.id() else {
            // an operator
            Self::skip(c);
            return;
        };
        let generic = c.is("<");
        if generic {
            c.skip_group();
        }
        if !c.is("(") {
            Self::skip(c);
            return;
        }
        let items = c.group_items();
        let (asyn, throws) = Self::effects(c);
        let ret = if c.eat("->") { parse_ty(&Self::ty_tokens(c), owner) } else { Some(Ty::Unit) };
        Self::past_body(c);
        if m.private {
            return;
        }
        let recv = match owner {
            None => Recv::None,
            Some(_) if m.is_static => Recv::None,
            Some(_) if m.mutating => Recv::Mut,
            Some(_) => Recv::Ref,
        };
        let mut s = Sig { name, recv, params: Vec::new(), ret: if throws { ret.map(|t| Ty::Res(Box::new(t))) } else { ret }, skip: None, src: String::new(), generics: Vec::new(), call: None };
        let labels = Self::params(&items, owner, &mut s);
        if generic {
            s.skip = Some("it's generic");
        } else if asyn {
            s.skip = Some("it's async");
        } else if m.barred.is_some() {
            s.skip = m.barred;
        }
        self.add(owner, s, labels);
    }

    /// async and throws, in either order (throws(E) too)
    fn effects(c: &mut Cur) -> (bool, bool) {
        let (mut asyn, mut throws) = (false, false);
        loop {
            if c.eat("async") {
                asyn = true;
            } else if c.eat("throws") || c.eat("rethrows") {
                throws = true;
                if c.is("(") {
                    c.skip_group();
                }
            } else {
                return (asyn, throws);
            }
        }
    }

    /// past a where clause and a body (when there's one)
    fn past_body(c: &mut Cur) {
        if c.is_id("where") {
            while c.i < c.t.len() && !c.is("{") && !Self::at_decl(c) {
                c.i += 1;
            }
        }
        if c.is("{") {
            c.skip_group();
        }
    }

    /// init[?](params) [throws] { ... }: T::new, then T::new_<first label>
    fn init(&mut self, c: &mut Cur, owner: Option<&str>, m: Mods, ext: bool) {
        c.i += 1;
        let failable = c.eat("?") || c.eat("!");
        let generic = c.is("<");
        if generic {
            c.skip_group();
        }
        if !c.is("(") {
            Self::skip(c);
            return;
        }
        let items = c.group_items();
        let (asyn, throws) = Self::effects(c);
        Self::past_body(c);
        let Some(o) = owner else { return };
        // an init in the type's own body takes away its memberwise one
        if !ext {
            self.not_plain.insert(o.to_string());
            self.has_init.insert(o.to_string());
        }
        if m.private {
            return;
        }
        let mut ret = if failable { Ty::Opt(Box::new(Ty::SelfTy)) } else { Ty::SelfTy };
        if throws {
            ret = Ty::Res(Box::new(ret));
        }
        let mut s = Sig { name: String::new(), recv: Recv::None, params: Vec::new(), ret: Some(ret), skip: None, src: String::new(), generics: Vec::new(), call: None };
        let labels = Self::params(&items, owner, &mut s);
        s.name = if self.taken.contains(&(o.to_string(), "new".to_string())) { format!("new_{}", labels.first().filter(|l| *l != "_").cloned().unwrap_or_default()) } else { "new".into() };
        if generic {
            s.skip = Some("it's generic");
        } else if asyn {
            s.skip = Some("it's async");
        } else if m.barred.is_some() {
            s.skip = m.barred;
        }
        self.inits.insert((o.to_string(), s.name.clone()));
        self.add(owner, s, labels);
    }

    /// struct, class, enum, extension, protocol or actor NAME [<...>] [: ...] { body }
    fn type_decl(&mut self, c: &mut Cur, kw: &str, m: Mods) {
        c.i += 1;
        let Some(name) = c.id() else {
            Self::skip(c);
            return;
        };
        // extension A.B: only top-level types are read
        let mut nested = false;
        while c.eat(".") {
            c.id();
            nested = true;
        }
        let generic = c.is("<");
        if generic {
            c.skip_group();
        }
        // the raw value type an enum names first (enum E: Int)
        let mut raw_int = false;
        let inherits = c.is(":");
        if c.eat(":") {
            raw_int = matches!(c.peek(), Some(Tok::Id(w)) if parse_ty(&[Tok::Id(w.clone())], None).is_some_and(|t| matches!(t, Ty::Prim(p) if p != "bool" && !p.starts_with('f'))));
        }
        while c.i < c.t.len() && !c.is("{") {
            if c.is("<") || c.is("(") {
                c.skip_group();
            } else {
                c.i += 1;
            }
        }
        if !c.is("{") {
            return;
        }
        let open = c.i;
        c.skip_group();
        let body = &c.t[open + 1..(c.i - 1).max(open + 1)];
        if m.private || nested {
            return;
        }
        if let Some(why) = m.barred {
            self.m.left_out.push(format!("{name} ({why})"));
            return;
        }
        if !spellable(&name) {
            self.m.left_out.push(format!("{name} (its name isn't one Volt can spell)"));
            return;
        }
        match kw {
            "protocol" => self.m.left_out.push(format!("{name} (a protocol)")),
            "actor" => self.m.left_out.push(format!("{name} (an actor: what it does is async)")),
            "extension" => self.decls(body, Some(&name), true),
            _ => {
                if !self.at.contains_key(&name) {
                    self.at.insert(name.clone(), self.m.types.len());
                    let is_enum = kw == "enum";
                    self.m.types.push(TypeDef {
                        module: Vec::new(),
                        name: name.clone(),
                        generic,
                        fields: if kw == "struct" { Some(Vec::new()) } else { None },
                        variants: if is_enum { Some(Vec::new()) } else { None },
                        is_enum,
                        clone: true,
                        opaque: false,
                        params: Vec::new(),
                        rust_name: None,
                    });
                    if kw == "class" {
                        self.classes.insert(name.clone());
                        // a subclass inherits its superclass's inits rather than having init()
                        if inherits {
                            self.has_init.insert(name.clone());
                        }
                    }
                    if raw_int {
                        self.raw.insert(name.clone());
                    }
                }
                self.decls(body, Some(&name), false);
            }
        }
    }

    /// let/var NAME [: T] [= value] [{ accessors }]: a constant at the top level; in a type, a
    /// stored property (a struct's field, a class's getter) or a computed one (a getter)
    fn property(&mut self, c: &mut Cur, owner: Option<&str>, m: Mods, ext: bool) {
        let is_let = c.is_id("let");
        c.i += 1;
        // var a = 1, b: Int = 2: one binding at a time
        loop {
            let Some(name) = c.id() else {
                Self::skip(c);
                return;
            };
            let tt = if c.eat(":") { Self::ty_tokens(c) } else { Vec::new() };
            let observers = |c: &Cur| c.is("{") && matches!(c.t.get(c.i + 1), Some(Tok::Id(w)) if w == "willSet" || w == "didSet");
            let mut value: Vec<Tok> = Vec::new();
            if c.eat("=") {
                // up to the next binding or declaration; braces are part of it (a trailing closure),
                // but for willSet and didSet
                let s = c.i;
                while c.i < c.t.len() && !Self::at_decl(c) && !c.is(",") && !observers(c) {
                    if c.is("(") || c.is("[") || c.is("{") {
                        c.skip_group();
                    } else {
                        c.i += 1;
                    }
                }
                value = c.t[s..c.i].to_vec();
            }
            // { get ... } or a getter's body: computed; { willSet / didSet }: stored, observed
            let (mut computed, mut getter) = (false, None);
            if c.is("{") {
                computed = !observers(c);
                let s = c.i;
                c.skip_group();
                let block = &c.t[s..c.i];
                if computed && block.windows(2).any(|w| w[0] == Tok::Id("get".into()) && matches!(&w[1], Tok::Id(x) if x == "throws" || x == "async")) {
                    getter = Some("its getter throws or is async");
                }
            }
            self.binding(owner, m, ext, is_let, name, &tt, &value, computed, getter);
            if !c.eat(",") {
                return;
            }
        }
    }

    /// one binding of a let or var (see property)
    #[allow(clippy::too_many_arguments)]
    fn binding(&mut self, owner: Option<&str>, m: Mods, ext: bool, is_let: bool, name: String, tt: &[Tok], value: &[Tok], computed: bool, getter: Option<&'static str>) {
        let lit = literal(tt, value);
        let ty = if tt.is_empty() { lit.as_ref().map(|l| l.0.clone()) } else { parse_ty(tt, owner) };
        let Some(o) = owner else {
            if is_let && !m.private && spellable(&name) {
                if let Some((t, text)) = lit {
                    let vt = match t {
                        Ty::Prim(p) => p.to_string(),
                        _ => "str".to_string(),
                    };
                    self.m.consts.push((Vec::new(), name, vt, text));
                }
            }
            return;
        };
        if m.is_static {
            return;
        }
        let Some(&at) = self.at.get(o) else { return };
        let is_class = self.classes.contains(o);
        if !computed && !ext && !self.m.types[at].is_enum {
            // a stored property; a let with a value isn't in the memberwise init
            if is_let && !value.is_empty() {
                self.not_plain.insert(o.to_string());
            }
            // an optional var starts as nil
            let has_value = !value.is_empty() || (!is_let && matches!(ty, Some(Ty::Opt(_))));
            // a lazy var is set on first read: not a struct's plain field, nor a memberwise argument
            if m.lazy && !is_class {
                self.not_plain.insert(o.to_string());
                self.no_memberwise.insert(o.to_string());
                return;
            }
            self.stored.entry(o.to_string()).or_default().push((name.clone(), ty.clone(), has_value, is_let, m.private));
            if let Some(fields) = &mut self.m.types[at].fields {
                fields.push((name.clone(), !m.private && spellable(&name), ty.clone()));
            }
            if !is_class {
                return;
            }
        }
        if m.private {
            return;
        }
        let s = Sig { name: name.clone(), recv: Recv::Ref, params: Vec::new(), ret: ty, skip: getter.or(m.barred), src: String::new(), generics: Vec::new(), call: None };
        self.props.insert((o.to_string(), name));
        self.add(owner, s, Vec::new());
    }

    /// case a, b = 2, c(Int): an enum's cases (one with associated values makes it a handle)
    fn case(&mut self, c: &mut Cur, owner: &str) {
        c.i += 1;
        let at = self.at[owner];
        let raw = self.raw.contains(owner);
        loop {
            let Some(n) = c.id() else { break };
            let next = self.m.types[at].variants.as_ref().map_or(0, |vs| vs.last().map_or(0, |l| l.1 + 1));
            let mut value = next;
            if c.is("(") || !spellable(&n) {
                if c.is("(") {
                    c.skip_group();
                }
                self.m.types[at].variants = None;
            }
            if c.eat("=") {
                let s = c.i;
                while c.i < c.t.len() && !c.is(",") && !Self::at_decl(c) {
                    if c.is("(") {
                        c.skip_group();
                    } else {
                        c.i += 1;
                    }
                }
                // a literal (1 or -1), not an expression (1 << 2)
                let v = &c.t[s..c.i];
                match (raw, v) {
                    (true, [Tok::Num(_)] | [Tok::P(_), Tok::Num(_)]) if int_value(v).is_some() => value = int_value(v).unwrap_or(next),
                    (true, _) => {
                        self.raw_lost.insert(owner.to_string());
                    }
                    _ => {}
                }
            }
            if let Some(vs) = &mut self.m.types[at].variants {
                vs.push((n, value));
            }
            if !c.eat(",") {
                break;
            }
        }
    }
}

/// whether a Swift name is one Volt can spell (ASCII letters, digits and _)
fn spellable(n: &str) -> bool {
    !n.is_empty() && n.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') && !n.as_bytes()[0].is_ascii_digit()
}

/// Swift's source with each string bolt's lexer can't read whole made one it can: a multi-line
/// one, a raw one (#"..."#) or one with interpolations (which can hold quotes, parentheses and
/// braces of their own) becomes "\(...)", which no constant is read from
fn plain_strings(src: &str) -> String {
    let b = src.as_bytes();
    let (mut out, mut last, mut i) = (String::with_capacity(src.len()), 0, 0);
    while i < b.len() {
        if b[i..].starts_with(b"//") {
            while i < b.len() && b[i] != b'\n' {
                i += 1;
            }
        } else if b[i..].starts_with(b"/*") {
            let mut depth = 0;
            while i < b.len() {
                if b[i..].starts_with(b"/*") {
                    depth += 1;
                    i += 2;
                } else if b[i..].starts_with(b"*/") {
                    depth -= 1;
                    i += 2;
                    if depth == 0 {
                        break;
                    }
                } else {
                    i += 1;
                }
            }
        } else if string_start(b, i) {
            let (end, plain) = string_end(b, i);
            if !plain {
                out.push_str(&src[last..i]);
                out.push_str("\"\\(...)\"");
                last = end;
            }
            i = end;
        } else {
            i += 1;
        }
    }
    out.push_str(&src[last..]);
    out
}

/// whether a string literal starts at i: a quote, or #s and a quote
fn string_start(b: &[u8], i: usize) -> bool {
    let mut k = i;
    while b.get(k) == Some(&b'#') {
        k += 1;
    }
    b.get(k) == Some(&b'"')
}

/// where the string literal at i ends, and whether it's plain (one line, not raw, no interpolation)
fn string_end(b: &[u8], mut i: usize) -> (usize, bool) {
    let mut hashes = 0;
    while b.get(i) == Some(&b'#') {
        hashes += 1;
        i += 1;
    }
    let multi = b[i..].starts_with(b"\"\"\"");
    i += if multi { 3 } else { 1 };
    let mut close = vec![b'"'; if multi { 3 } else { 1 }];
    close.extend(std::iter::repeat_n(b'#', hashes));
    let mut plain = hashes == 0 && !multi;
    while i < b.len() {
        if b[i..].starts_with(&close) {
            return (i + close.len(), plain);
        }
        if b[i] == b'\\' && b[i + 1..].starts_with(&vec![b'#'; hashes]) {
            let at = i + 1 + hashes;
            if b.get(at) == Some(&b'(') {
                plain = false;
                i = interpolation_end(b, at + 1);
                continue;
            }
            i = at + 1;
            continue;
        }
        if !multi && b[i] == b'\n' {
            return (i, plain); // never closed
        }
        i += 1;
    }
    (i, plain)
}

/// past an interpolation, from just after its "(": to just after its ")"
fn interpolation_end(b: &[u8], mut i: usize) -> usize {
    let mut depth = 1;
    while i < b.len() {
        if string_start(b, i) {
            i = string_end(b, i).0;
            continue;
        }
        match b[i] {
            b'(' => depth += 1,
            b')' => {
                depth -= 1;
                if depth == 0 {
                    return i + 1;
                }
            }
            _ => {}
        }
        i += 1;
    }
    i
}

/// a literal value and its type: an integer, a float, a bool or a string without interpolation
fn literal(tt: &[Tok], value: &[Tok]) -> Option<(Ty, String)> {
    let t = if tt.is_empty() { None } else { parse_ty(tt, None) };
    // 1e3 (one token) is a Double
    if let [Tok::Num(n)] = value {
        if !n.starts_with("0x") && n.contains(['e', 'E']) && matches!(t, None | Some(Ty::Prim("f64" | "f32"))) {
            let v: f64 = n.parse().ok()?;
            let text = format!("{v:?}");
            return (!text.contains('e')).then(|| (t.unwrap_or(Ty::Prim("f64")), text));
        }
    }
    match (t, value) {
        (Some(Ty::Prim(x)), v) if x != "bool" && number(v).is_some_and(|n| x.starts_with('f') || !n.1) => Some((Ty::Prim(x), number(v)?.0)),
        (None, v) if tt.is_empty() && number(v).is_some() => {
            let (n, float) = number(v)?;
            Some((Ty::Prim(if float { "f64" } else { "isize" }), n))
        }
        (Some(Ty::Prim("bool")) | None, [Tok::Id(b)]) if (b == "true" || b == "false") && (tt.is_empty() || parse_ty(tt, None) == Some(Ty::Prim("bool"))) => Some((Ty::Prim("bool"), b.clone())),
        (Some(Ty::Str) | None, [Tok::Str(s)]) if !s.contains("\\(") && (tt.is_empty() || parse_ty(tt, None) == Some(Ty::Str)) => Some((Ty::Str, format!("\"{s}\""))),
        _ => None,
    }
}

/// a Swift type from its tokens, when it's one Volt can name; `owner`'s name is Self
fn parse_ty(t: &[Tok], owner: Option<&str>) -> Option<Ty> {
    let is = |i: usize, p: &str| matches!(t.get(i), Some(Tok::P(q)) if q == p);
    // attributes and ownership words before it
    if let [Tok::Id(w), rest @ ..] = t {
        if w.starts_with('@') || ["__owned", "__shared", "borrowing", "consuming", "sending"].contains(&w.as_str()) {
            return parse_ty(rest, owner);
        }
        if w == "inout" {
            return match parse_ty(rest, owner)? {
                x @ (Ty::Named(_) | Ty::SelfTy) => Some(Ty::Ref(Box::new(x), true)),
                _ => None,
            };
        }
    }
    let n = t.len();
    if n > 1 && (is(n - 1, "?") || is(n - 1, "!")) {
        return match parse_ty(&t[..n - 1], owner)? {
            Ty::Opt(_) | Ty::Unit => None,
            x => Some(Ty::Opt(Box::new(x))),
        };
    }
    if is(0, "(") && is(1, ")") && n == 2 {
        return Some(Ty::Unit);
    }
    // [T] (not [K: V])
    if is(0, "[") && is(n - 1, "]") && !t.contains(&Tok::P(":".into())) {
        return match parse_ty(&t[1..n - 1], owner)? {
            e @ (Ty::Prim(_) | Ty::Str) => Some(Ty::Vec(Box::new(e))),
            _ => None,
        };
    }
    if let [Tok::Id(a), Tok::P(lt), inner @ .., Tok::P(gt)] = t {
        if a == "Array" && lt == "<" && gt == ">" {
            return parse_ty(&[vec![Tok::P("[".into())], inner.to_vec(), vec![Tok::P("]".into())]].concat(), owner);
        }
        if a == "Optional" && lt == "<" && gt == ">" {
            return parse_ty(&[inner.to_vec(), vec![Tok::P("?".into())]].concat(), owner);
        }
    }
    // a name, maybe dotted (Swift.Int, Shapes.Point)
    if t.is_empty() || t.iter().enumerate().any(|(i, x)| if i % 2 == 0 { !matches!(x, Tok::Id(_)) } else { *x != Tok::P(".".into()) }) {
        return None;
    }
    let Some(Tok::Id(name)) = t.last() else { return None };
    Some(match name.as_str() {
        "Void" => Ty::Unit,
        "Int" => Ty::Prim("isize"),
        "UInt" => Ty::Prim("usize"),
        "Int8" | "CChar" | "CSignedChar" => Ty::Prim("i8"),
        "Int16" | "CShort" => Ty::Prim("i16"),
        "Int32" | "CInt" => Ty::Prim("i32"),
        "Int64" | "CLong" | "CLongLong" => Ty::Prim("i64"),
        "UInt8" | "CUnsignedChar" => Ty::Prim("u8"),
        "UInt16" | "CUnsignedShort" => Ty::Prim("u16"),
        "UInt32" | "CUnsignedInt" => Ty::Prim("u32"),
        "UInt64" | "CUnsignedLong" | "CUnsignedLongLong" => Ty::Prim("u64"),
        "Double" | "Float64" | "CDouble" => Ty::Prim("f64"),
        "Float" | "Float32" | "CFloat" => Ty::Prim("f32"),
        "Bool" | "CBool" => Ty::Prim("bool"),
        "String" => Ty::Str,
        "Self" => Ty::SelfTy,
        n if owner == Some(n) => Ty::SelfTy,
        n if prim(n).is_some() => return None, // a Volt name, not a Swift type
        "Character" | "Substring" | "Any" | "AnyObject" | "Never" | "Error" | "Data" | "Date" | "URL" | "Float16" | "Float80" | "Int128" | "UInt128" => return None,
        n => Ty::Named(n.to_string()),
    })
}

// ---------- the shim, in Swift ----------

pub struct Swift {
    labels: BTreeMap<(String, String), Vec<String>>,
    props: BTreeSet<(String, String)>,
    inits: BTreeSet<(String, String)>,
    classes: BTreeSet<String>,
}

/// a Volt number type's Swift name
fn swift_prim(x: &str) -> &'static str {
    match x {
        "i8" => "Int8",
        "i16" => "Int16",
        "i32" => "Int32",
        "i64" => "Int64",
        "u8" => "UInt8",
        "u16" => "UInt16",
        "u32" => "UInt32",
        "u64" => "UInt64",
        "isize" => "Int",
        "usize" => "UInt",
        "f32" => "Float",
        "f64" => "Double",
        _ => "Bool",
    }
}

/// a number's size (and alignment) in bytes
fn prim_size(x: &str) -> usize {
    match x {
        "i8" | "u8" | "bool" => 1,
        "i16" | "u16" => 2,
        "i32" | "u32" | "f32" => 4,
        _ => 8,
    }
}

impl Swift {
    /// a handle's Swift value: the class, or the value in its box
    fn unbox(&self, ti: &TypeInfo, h: &str) -> String {
        let n = &ti.def.name;
        if self.classes.contains(n) {
            format!("Unmanaged<{n}>.fromOpaque({h}).takeUnretainedValue()")
        } else {
            format!("Unmanaged<__VoltBox<{n}>>.fromOpaque({h}).takeUnretainedValue().v")
        }
    }

    /// a new handle for value `v`
    fn boxed(&self, ti: &TypeInfo, v: &str) -> String {
        if self.classes.contains(&ti.def.name) {
            format!("Unmanaged.passRetained({v}).toOpaque()")
        } else {
            format!("Unmanaged.passRetained(__VoltBox({v})).toOpaque()")
        }
    }

    /// a plain struct's C layout: each field's offset, and the struct's size and alignment
    fn layout(g: &Gen, ti: &TypeInfo) -> (Vec<(String, usize, Ty)>, usize, usize) {
        let (mut out, mut at, mut align): (Vec<(String, usize, Ty)>, usize, usize) = (Vec::new(), 0, 1);
        for (f, _, t) in ti.def.fields.clone().unwrap_or_default() {
            let (size, al) = match &t {
                Some(Ty::Prim(x)) => (prim_size(x), prim_size(x)),
                Some(Ty::Named(n)) => match g.types.get(n) {
                    Some(o) if o.kind == Kind::Enum => (8, 8),
                    Some(o) => {
                        let (_, s, a) = Self::layout(g, o);
                        (s, a)
                    }
                    None => (0, 1),
                },
                _ => (0, 1),
            };
            at = at.div_ceil(al) * al;
            if let Some(t) = t {
                out.push((f, at, t));
            }
            at += size;
            align = align.max(al);
        }
        (out, at.div_ceil(align) * align, align)
    }
}

impl Lang for Swift {
    fn short(&self) -> &'static str {
        "swift"
    }

    fn name(&self) -> &'static str {
        "Swift"
    }

    fn by_value_moves(&self, _ti: &TypeInfo) -> bool {
        // a struct copies, a class is shared (retained): nothing is left empty
        false
    }

    fn param(&self, g: &Gen, t: &Ty, a: &str) -> Option<ShimParam> {
        let mut p = ShimParam::default();
        match t {
            Ty::Prim(x) => {
                p.params.push(format!("_ {a}: {}", swift_prim(x)));
                p.arg = a.to_string();
            }
            Ty::Str => {
                p.params.extend([format!("_ {a}: UnsafePointer<UInt8>?"), format!("_ {a}_n: Int")]);
                p.arg = format!("__voltS({a}, {a}_n)");
            }
            Ty::Vec(e) => match &**e {
                Ty::Prim(x) => {
                    p.params.extend([format!("_ {a}: UnsafePointer<{}>?", swift_prim(x)), format!("_ {a}_n: Int")]);
                    p.arg = format!("__voltSl({a}, {a}_n)");
                }
                Ty::Str => {
                    p.params.extend([format!("_ {a}: UnsafeRawPointer?"), format!("_ {a}_n: Int")]);
                    p.arg = format!("__voltStrs({a}, {a}_n)");
                }
                _ => return None,
            },
            Ty::Opt(inner) => match &**inner {
                Ty::Prim(x) => {
                    p.params.extend([format!("_ {a}_has: Bool"), format!("_ {a}: {}", swift_prim(x))]);
                    p.arg = format!("({a}_has ? {a} : nil)");
                }
                Ty::Str => {
                    p.params.extend([format!("_ {a}: UnsafePointer<UInt8>?"), format!("_ {a}_n: Int")]);
                    p.arg = format!("({a} == nil ? nil : __voltS({a}, {a}_n))");
                }
                _ => return None,
            },
            Ty::Named(_) | Ty::Ref(..) => {
                let (named, mutable) = match t {
                    Ty::Ref(x, m) => (&**x, *m),
                    x => (x, false),
                };
                let ti = g.info(named)?;
                let n = &ti.def.name;
                match ti.kind {
                    Kind::Plain => {
                        if mutable {
                            p.params.push(format!("_ {a}: UnsafeMutableRawPointer"));
                            p.pre.push(format!("var {a}_v = __volt_from_{n}(UnsafeRawPointer({a}))"));
                            p.arg = format!("&{a}_v");
                            p.post.push(format!("__volt_to_{n}({a}_v, {a})"));
                        } else {
                            p.params.push(format!("_ {a}: UnsafeRawPointer"));
                            p.arg = format!("__volt_from_{n}({a})");
                        }
                    }
                    Kind::Handle => {
                        // inout of a class would rebind the reference: not something a handle can follow
                        if mutable && self.classes.contains(n) {
                            return None;
                        }
                        p.params.push(format!("_ {a}: UnsafeMutableRawPointer"));
                        p.arg = if mutable { format!("&{}", self.unbox(ti, a)) } else { self.unbox(ti, a) };
                    }
                    Kind::Enum => {
                        if mutable {
                            return None;
                        }
                        p.params.push(format!("_ {a}: Int64"));
                        p.arg = format!("__volt_from_{n}({a})");
                    }
                }
            }
            _ => return None,
        }
        Some(p)
    }

    fn receiver(&self, _g: &Gen, ti: &TypeInfo, recv: Recv) -> Option<ShimParam> {
        let n = &ti.def.name;
        let mut p = ShimParam::default();
        match ti.kind {
            Kind::Plain => {
                if recv == Recv::Mut {
                    p.params.push("_ this: UnsafeMutableRawPointer".into());
                    p.pre.push(format!("var this_v = __volt_from_{n}(UnsafeRawPointer(this))"));
                    p.post.push(format!("__volt_to_{n}(this_v, this)"));
                } else {
                    p.params.push("_ this: UnsafeRawPointer".into());
                    p.pre.push(format!("let this_v = __volt_from_{n}(this)"));
                }
                p.arg = "this_v".into();
            }
            Kind::Handle => {
                p.params.push("_ this: UnsafeMutableRawPointer".into());
                p.arg = self.unbox(ti, "this");
            }
            Kind::Enum => {
                if recv == Recv::Mut {
                    return None;
                }
                p.params.push("_ this: Int64".into());
                p.pre.push(format!("let this_v = __volt_from_{n}(this)"));
                p.arg = "this_v".into();
            }
        }
        Some(p)
    }

    fn out(&self, g: &Gen, t: &Ty, o: &str, _owned: bool) -> Option<ShimOut> {
        Some(match t {
            Ty::Prim(x) => ShimOut { params: vec![format!("_ {o}: UnsafeMutablePointer<{}>", swift_prim(x))], store: format!("{o}.pointee = $v") },
            Ty::Str => ShimOut { params: vec![format!("_ {o}: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>"), format!("_ {o}_n: UnsafeMutablePointer<Int>")], store: format!("__voltPutS($v, {o}, {o}_n)") },
            Ty::Vec(e) => match &**e {
                Ty::Prim(x) => ShimOut {
                    params: vec![format!("_ {o}: UnsafeMutablePointer<UnsafeMutablePointer<{}>?>", swift_prim(x)), format!("_ {o}_n: UnsafeMutablePointer<Int>")],
                    store: format!("__voltPut($v, {o}, {o}_n)"),
                },
                Ty::Str => ShimOut { params: vec![format!("_ {o}: UnsafeMutablePointer<UnsafeMutableRawPointer?>"), format!("_ {o}_n: UnsafeMutablePointer<Int>")], store: format!("__voltPutStrs($v, {o}, {o}_n)") },
                _ => return None,
            },
            Ty::Named(_) => {
                let ti = g.info(t)?;
                let n = &ti.def.name;
                match ti.kind {
                    Kind::Plain => ShimOut { params: vec![format!("_ {o}: UnsafeMutableRawPointer")], store: format!("__volt_to_{n}($v, {o})") },
                    Kind::Handle => ShimOut { params: vec![format!("_ {o}: UnsafeMutablePointer<UnsafeMutableRawPointer?>")], store: format!("{o}.pointee = {}", self.boxed(ti, "$v")) },
                    Kind::Enum => ShimOut { params: vec![format!("_ {o}: UnsafeMutablePointer<Int64>")], store: format!("{o}.pointee = __volt_to_{n}($v)") },
                }
            }
            Ty::Opt(inner) => {
                let x = self.out(g, inner, o, false)?;
                let mut params = vec![format!("_ {o}_has: UnsafeMutablePointer<Bool>")];
                params.extend(x.params);
                ShimOut { params, store: format!("if let w = $v {{ {o}_has.pointee = true; {} }} else {{ {o}_has.pointee = false }}", x.store.replace("$v", "w")) }
            }
            _ => return None,
        })
    }

    fn call(&self, _g: &Gen, _module: &[String], s: &Sig, self_ty: Option<&TypeInfo>, recv: Option<&str>, args: &[String]) -> String {
        let owner = self_ty.map(|t| t.def.name.clone()).unwrap_or_default();
        let key = (owner.clone(), s.name.clone());
        if let (true, Some(r)) = (self.props.contains(&key), recv) {
            return format!("{r}.{}", s.name);
        }
        let labels = self.labels.get(&key);
        let args: Vec<String> = args
            .iter()
            .enumerate()
            .map(|(i, a)| match labels.and_then(|l| l.get(i)) {
                Some(l) if l != "_" => format!("{l}: {a}"),
                _ => a.clone(),
            })
            .collect();
        let args = args.join(", ");
        if self.inits.contains(&key) {
            return format!("{owner}({args})");
        }
        match (recv, self_ty) {
            (Some(r), _) => format!("{r}.{}({args})", s.name),
            (None, Some(_)) => format!("{owner}.{}({args})", s.name),
            (None, None) => format!("{}({args})", s.name),
        }
    }

    fn function(&self, sym: &str, params: &[String], pre: &[String], call: &str, post: &[String], store: Option<&str>, res: bool) -> String {
        let mut ps = params.to_vec();
        if res {
            ps.extend(["_ e: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>".to_string(), "_ e_n: UnsafeMutablePointer<Int>".to_string()]);
        }
        let mut body = String::new();
        for l in pre {
            let _ = writeln!(body, "    {l}");
        }
        let (ind, tr) = if res { ("        ", "try ") } else { ("    ", "") };
        let mut inner = String::new();
        match store {
            Some(st) => {
                let _ = writeln!(inner, "{ind}let v = {tr}{call}");
                for l in post {
                    let _ = writeln!(inner, "{ind}{l}");
                }
                let _ = writeln!(inner, "{ind}{}", st.replace("$v", "v"));
            }
            None => {
                let _ = writeln!(inner, "{ind}_ = {tr}{call}");
                for l in post {
                    let _ = writeln!(inner, "{ind}{l}");
                }
            }
        }
        if res {
            let _ = write!(body, "    do {{\n{inner}        return true\n    }} catch {{\n        __voltPutS(String(describing: error), e, e_n)\n        return false\n    }}\n");
        } else {
            body.push_str(&inner);
        }
        format!("@_cdecl(\"{sym}\") public func {sym}({}){} {{\n{body}}}\n\n", ps.join(", "), if res { " -> Bool" } else { "" })
    }

    fn type_glue(&self, g: &Gen, ti: &TypeInfo) -> String {
        let n = &ti.def.name;
        let mg = Gen::mangle(&ti.def);
        let mut out = String::new();
        match ti.kind {
            Kind::Plain => {
                // read and written at C's offsets, as the Volt struct lays them out
                let (fields, _, _) = Self::layout(g, ti);
                let (mut from, mut to) = (Vec::new(), String::new());
                for (f, at, t) in fields {
                    match t {
                        Ty::Prim(x) => {
                            let st = swift_prim(&x);
                            from.push(format!("{f}: p.load(fromByteOffset: {at}, as: {st}.self)"));
                            let _ = writeln!(to, "    p.storeBytes(of: v.{f}, toByteOffset: {at}, as: {st}.self)");
                        }
                        Ty::Named(o) if g.types.get(&o).is_some_and(|x| x.kind == Kind::Enum) => {
                            from.push(format!("{f}: __volt_from_{o}(p.load(fromByteOffset: {at}, as: Int64.self))"));
                            let _ = writeln!(to, "    p.storeBytes(of: __volt_to_{o}(v.{f}), toByteOffset: {at}, as: Int64.self)");
                        }
                        Ty::Named(o) => {
                            from.push(format!("{f}: __volt_from_{o}(p + {at})"));
                            let _ = writeln!(to, "    __volt_to_{o}(v.{f}, p + {at})");
                        }
                        _ => {}
                    }
                }
                let _ = write!(out, "func __volt_from_{n}(_ p: UnsafeRawPointer) -> {n} {{\n    return {n}({})\n}}\n\nfunc __volt_to_{n}(_ v: {n}, _ p: UnsafeMutableRawPointer) {{\n{to}}}\n\n", from.join(", "));
            }
            Kind::Handle => {
                let drop = g.sym(&[&mg, "drop"]);
                let held = if self.classes.contains(n) { n.clone() } else { format!("__VoltBox<{n}>") };
                let _ = write!(out, "@_cdecl(\"{drop}\") public func {drop}(_ h: UnsafeMutableRawPointer) {{\n    Unmanaged<{held}>.fromOpaque(h).release()\n}}\n\n");
                if ti.def.clone {
                    let cl = g.sym(&[&mg, "clone"]);
                    let _ = write!(out, "@_cdecl(\"{cl}\") public func {cl}(_ h: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {{\n    return {}\n}}\n\n", self.boxed(ti, &self.unbox(ti, "h")));
                }
            }
            Kind::Enum => {
                let vs = ti.def.variants.clone().unwrap_or_default();
                let mut from = format!("func __volt_from_{n}(_ x: Int64) -> {n} {{\n    switch x {{\n");
                let mut to = format!("func __volt_to_{n}(_ v: {n}) -> Int64 {{\n    switch v {{\n");
                for (c, x) in &vs {
                    let _ = writeln!(from, "    case {x}: return .{c}");
                    let _ = writeln!(to, "    case .{c}: return {x}");
                }
                let first = vs.first().map_or(String::new(), |v| v.0.clone());
                let _ = write!(from, "    default: return .{first}\n    }}\n}}\n\n");
                to.push_str("    }\n}\n\n");
                out.push_str(&from);
                out.push_str(&to);
            }
        }
        out
    }

    fn prelude(&self, g: &Gen) -> String {
        let free = |what: &str| format!("volt_swift_{}_free_{what}", g.alias);
        let mut s = String::from("// the glue between a Volt program and this Swift, written by bolt import (use swift)\n\n");
        s.push_str("// a value Volt holds by handle\nfinal class __VoltBox<T> {\n    var v: T\n    init(_ v: T) { self.v = v }\n}\n\n");
        s.push_str("func __voltS(_ p: UnsafePointer<UInt8>?, _ n: Int) -> String {\n    guard let p = p else { return \"\" }\n    return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)\n}\n\n");
        s.push_str("func __voltSl<T>(_ p: UnsafePointer<T>?, _ n: Int) -> [T] {\n    guard let p = p else { return [] }\n    return Array(UnsafeBufferPointer(start: p, count: n))\n}\n\n");
        s.push_str("// Volt's str[..]: a pointer and a length each\nfunc __voltStrs(_ p: UnsafeRawPointer?, _ n: Int) -> [String] {\n    guard let p = p else { return [] }\n    return (0..<n).map { i in __voltS(p.load(fromByteOffset: i * 16, as: UnsafePointer<UInt8>?.self), p.load(fromByteOffset: i * 16 + 8, as: Int.self)) }\n}\n\n");
        s.push_str("// a copy for Volt, which gives it back to the free functions below\nfunc __voltPut<T>(_ v: [T], _ o: UnsafeMutablePointer<UnsafeMutablePointer<T>?>, _ n: UnsafeMutablePointer<Int>) {\n    n.pointee = v.count\n    if v.isEmpty {\n        o.pointee = nil\n        return\n    }\n    let b = UnsafeMutablePointer<T>.allocate(capacity: v.count)\n    b.initialize(from: v, count: v.count)\n    o.pointee = b\n}\n\n");
        s.push_str("func __voltPutS(_ s: String, _ o: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, _ n: UnsafeMutablePointer<Int>) {\n    __voltPut(Array(s.utf8), o, n)\n}\n\n");
        s.push_str("func __voltPutStrs(_ v: [String], _ o: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ n: UnsafeMutablePointer<Int>) {\n    n.pointee = v.count\n    if v.isEmpty {\n        o.pointee = nil\n        return\n    }\n    let b = UnsafeMutableRawPointer.allocate(byteCount: v.count * 16, alignment: 8)\n    for (i, s) in v.enumerated() {\n        var p: UnsafeMutablePointer<UInt8>? = nil\n        var k = 0\n        __voltPutS(s, &p, &k)\n        b.storeBytes(of: p, toByteOffset: i * 16, as: UnsafeMutablePointer<UInt8>?.self)\n        b.storeBytes(of: k, toByteOffset: i * 16 + 8, as: Int.self)\n    }\n    o.pointee = b\n}\n\n");
        let bytes = free("bytes");
        let _ = write!(s, "@_cdecl(\"{bytes}\") public func {bytes}(_ p: UnsafeMutablePointer<UInt8>?, _ n: Int) {{\n    p?.deallocate()\n}}\n\n");
        for x in &g.vec_elems {
            let f = free(&format!("{x}s"));
            let _ = write!(s, "@_cdecl(\"{f}\") public func {f}(_ p: UnsafeMutablePointer<{}>?, _ n: Int) {{\n    p?.deallocate()\n}}\n\n", swift_prim(x));
        }
        if g.strs {
            let f = free("strs");
            let _ = write!(s, "@_cdecl(\"{f}\") public func {f}(_ p: UnsafeMutableRawPointer?, _ n: Int) {{\n    guard let p = p else {{ return }}\n    for i in 0..<n {{\n        p.load(fromByteOffset: i * 16, as: UnsafeMutablePointer<UInt8>?.self)?.deallocate()\n    }}\n    p.deallocate()\n}}\n\n");
        }
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ty(s: &str) -> Option<Ty> {
        parse_ty(&lex(s), Some("Shape"))
    }

    #[test]
    fn import_swift_types() {
        assert_eq!(ty("Int"), Some(Ty::Prim("isize")));
        assert_eq!(ty("UInt8"), Some(Ty::Prim("u8")));
        assert_eq!(ty("Double"), Some(Ty::Prim("f64")));
        assert_eq!(ty("Swift.Int32"), Some(Ty::Prim("i32")));
        assert_eq!(ty("String"), Some(Ty::Str));
        assert_eq!(ty("String?"), Some(Ty::Opt(Box::new(Ty::Str))));
        assert_eq!(ty("[Double]"), Some(Ty::Vec(Box::new(Ty::Prim("f64")))));
        assert_eq!(ty("Array<String>"), Some(Ty::Vec(Box::new(Ty::Str))));
        assert_eq!(ty("[String: Int]"), None);
        assert_eq!(ty("inout Point"), Some(Ty::Ref(Box::new(Ty::Named("Point".into())), true)));
        assert_eq!(ty("inout Int"), None);
        assert_eq!(ty("Shape"), Some(Ty::SelfTy));
        assert_eq!(ty("Self"), Some(Ty::SelfTy));
        assert_eq!(ty("Void"), Some(Ty::Unit));
        assert_eq!(ty("()"), Some(Ty::Unit));
        assert_eq!(ty("(Int) -> Int"), None);
        assert_eq!(ty("Int??"), None);
        assert_eq!(ty("Character"), None);
        assert_eq!(ty("i64"), None);
        assert_eq!(ty("__owned Point"), Some(Ty::Named("Point".into())));
    }

    #[test]
    fn import_swift_decls() {
        let src = r#"
import Foundation
public struct Point: Equatable {
    public var x: Double
    var y: Double = 0
    var norm: Double { (x * x + y * y).squareRoot() }
    func scaled(by k: Double) -> Point { Point(x: x * k, y: y * k) }
    mutating func move(dx: Double, _ dy: Double) { x += dx; y += dy }
    static func origin() -> Point { Point(x: 0, y: 0) }
    private func hidden() {}
}
final class Counter {
    private(set) var count = 0
    let name: String
    init(name: String) { self.name = name }
    convenience init(start: Int) { self.init(name: "n"); count = start }
    func bump(by k: Int = 1) -> Int { count += k; return count }
    func wait() async {}
}
enum Color: Int { case red = 1, green, blue = 7
    var hex: String { "x" }
}
enum Shape { case circle(Double), square(Double) }
enum ParseError: Error { case bad }
func parse(_ text: String) throws -> Int { 0 }
func add(_ a: Int, _ b: Int) -> Int { a + b }
func add(_ a: Double, _ b: Double) -> Double { a + b }
func pick<T>(_ x: T) -> T { x }
private func secret() {}
let LIMIT = 10
let NAME: String = "geom"
let GREETING = "hi \(NAME)"
protocol Drawable { func draw() }
extension Point { func dot(_ o: Point) -> Double { x * o.x + y * o.y } }
"#;
        let mut p = Parser::default();
        p.decls(&lex(src), None, false);
        let (m, sw) = p.finish();
        let types: Vec<&str> = m.types.iter().map(|t| t.name.as_str()).collect();
        assert_eq!(types, ["Point", "Counter", "Color", "Shape", "ParseError"]);
        assert_eq!(m.types[0].fields, Some(vec![("x".into(), true, Some(Ty::Prim("f64"))), ("y".into(), true, Some(Ty::Prim("f64")))]));
        assert!(!m.types[0].opaque, "Point has its memberwise init");
        assert!(m.types[1].opaque, "a class is a handle");
        assert_eq!(m.types[2].variants, Some(vec![("red".into(), 1), ("green".into(), 2), ("blue".into(), 7)]));
        assert_eq!(m.types[3].variants, None, "cases with values: a handle");
        let methods = |t: &str| m.methods[t].iter().map(|s| (s.name.as_str(), s.recv)).collect::<Vec<_>>();
        assert_eq!(methods("Point"), [("norm", Recv::Ref), ("scaled", Recv::Ref), ("move", Recv::Mut), ("origin", Recv::None), ("dot", Recv::Ref), ("new", Recv::None)]);
        assert_eq!(sw.labels[&("Point".to_string(), "new".to_string())], ["x", "y"], "the memberwise init");
        assert_eq!(methods("Counter"), [("count", Recv::Ref), ("name", Recv::Ref), ("new", Recv::None), ("new_start", Recv::None), ("bump", Recv::Ref), ("wait", Recv::Ref)]);
        assert_eq!(m.methods["Counter"][5].skip, Some("it's async"));
        assert_eq!(sw.labels[&("Point".to_string(), "move".to_string())], ["dx", "_"]);
        assert_eq!(sw.labels[&("Counter".to_string(), "bump".to_string())], ["by"]);
        assert!(sw.inits.contains(&("Counter".to_string(), "new_start".to_string())));
        assert!(sw.props.contains(&("Point".to_string(), "norm".to_string())));
        let fns: Vec<(&str, Option<Ty>)> = m.fns.iter().map(|(_, s)| (s.name.as_str(), s.ret.clone())).collect();
        assert_eq!(fns, [("parse", Some(Ty::Res(Box::new(Ty::Prim("isize"))))), ("add", Some(Ty::Prim("isize"))), ("pick", Some(Ty::Named("T".into())))]);
        assert_eq!(m.fns[2].1.skip, Some("it's generic"));
        assert_eq!(m.consts, [(vec![], "LIMIT".to_string(), "isize".to_string(), "10".to_string()), (vec![], "NAME".to_string(), "str".to_string(), "\"geom\"".to_string())]);
        assert_eq!(m.left_out, ["add (an overload: Volt has the first one of that name)", "Drawable (a protocol)"]);
    }

    #[test]
    fn import_swift_hard_cases() {
        // each of these once mis-read (a panic, or a shim that wouldn't build)
        let src = "\u{feff}/* naïve */ let π = 3.14
let BIG = 1e3
let label = \"\\(true ? \"{\" : \"\")\"
let block = \"\"\"
  a \" quote and a { brace
  \"\"\"
struct Outer { var a: Int }
extension Outer.Inner { func f() {} }
class Animal { init(name: String) {} }
class Dog: Animal { var tricks = 0 }
struct Pair {
    var x: Double = 0, y: Double = 0
    var n: Int = [1, 2].map { $0 }.count
    var z: Int { get throws { 1 } }
    func clone() -> Pair { self }
}
struct Lazy { lazy var cache: Int = 1 }
@MainActor func onMain() {}
@available(*, unavailable) func gone() {}
#if DEBUG
func dbg() {}
#endif
enum Flags: Int { case a = 1 << 0, b = 1 << 1 }
func after() {}
";
        let mut p = Parser::default();
        p.decls(&lex(&plain_strings(src)), None, false);
        let (m, _) = p.finish();
        let consts: Vec<(&str, &str, &str)> = m.consts.iter().map(|c| (c.1.as_str(), c.2.as_str(), c.3.as_str())).collect();
        assert_eq!(consts, [("BIG", "f64", "1000.0")]);
        let fields = |t: &str| m.types.iter().find(|x| x.name == t).and_then(|x| x.fields.clone()).unwrap_or_default().into_iter().map(|f| f.0).collect::<Vec<_>>();
        assert_eq!(fields("Pair"), ["x", "y", "n"]);
        let methods = |t: &str| m.methods.get(t).map(|v| v.iter().map(|s| (s.name.clone(), s.skip)).collect::<Vec<_>>()).unwrap_or_default();
        assert_eq!(methods("Outer"), [("new".to_string(), None)], "Outer.Inner's f isn't Outer's");
        assert_eq!(methods("Dog"), [("tricks".to_string(), None)], "a subclass has its superclass's inits, not init()");
        assert_eq!(methods("Pair")[0], ("z".to_string(), Some("its getter throws or is async")));
        assert!(methods("Lazy").iter().all(|x| x.0 != "new_cache"), "no memberwise init with a lazy var");
        assert!(m.types.iter().find(|x| x.name == "Lazy").is_some_and(|x| x.opaque));
        let fns: Vec<(String, Option<&str>)> = m.fns.iter().map(|(_, s)| (s.name.clone(), s.skip)).collect();
        assert_eq!(fns, [("onMain".to_string(), Some("it's isolated to an actor")), ("gone".to_string(), Some("it's marked unavailable")), ("after".to_string(), None)], "left out {:?}, types {:?}", m.left_out, m.types.iter().map(|t| &t.name).collect::<Vec<_>>());
        assert_eq!(m.types.iter().find(|x| x.name == "Flags").and_then(|x| x.variants.clone()), Some(vec![("a".into(), 0), ("b".into(), 1)]));
        assert!(m.left_out.iter().any(|l| l.contains("Pair.clone")), "{:?}", m.left_out);
        assert!(m.left_out.iter().any(|l| l.contains("#if")), "{:?}", m.left_out);
    }
}
