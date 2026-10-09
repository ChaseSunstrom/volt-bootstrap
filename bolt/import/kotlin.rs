// use { "file.kt" } as NAME; — ordinary Kotlin (Kotlin/Native), called from Volt. bolt reads the
// files' top-level declarations (funs; classes, data classes, enum classes and objects with their
// constructors, member funs, properties and companion objects; const vals of literals), all but the
// private and protected ones, writes a shim of @CName functions that call them, builds both with
// kotlinc-native -produce static (the archive carries the Kotlin/Native runtime), and writes the
// Volt side (glue.rs). Nothing in the Kotlin code changes.
//
//   Int, Long, Short, Byte, UInt.., Double, Float, Boolean -> i32, i64, i16, i8, u32.., f64, f32, bool
//   String -> str in, std::string out; List<T> (Collection, Iterable) -> T[..] in, std::vec<T> out
//   (numbers and strings); T? -> T?; a thrown exception -> the try_ form's PANIC (its toString())
//   a data class of vals that are all plain, with no other stored property -> a Volt struct, by
//   value; any other class, and an object -> a handle whose copy shares the object (Kotlin's
//   references); an enum class -> a Volt enum (its ordinals)
//   the primary constructor -> T::new(...), another T::new_<its first parameter>(...); a property
//   -> a method without arguments; an object's or a companion object's funs -> T::f(...)
use super::glue::{number, prim, Gen, Kind, Lang, Model, Recv, ShimOut, ShimParam, Sig, Ty, TypeDef, TypeInfo};
use super::{arg_path, fresh, save, stamp, Made, Req};
use crate::foreign::{int_value, lex, toks_line, Cur, Tok};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write;
use std::path::PathBuf;
use std::process::Command;

pub fn import(r: &Req) -> Result<(), String> {
    if r.args.is_empty() {
        return Err(format!("use {{ \"file.kt\" }} as {}: name the Kotlin files", r.alias));
    }
    let files: Vec<PathBuf> = r.args.iter().map(|a| arg_path(r, a)).collect();
    if let Some(f) = files.iter().find(|f| !f.is_file()) {
        return Err(format!("use kotlin: there's no {}", f.display()));
    }
    let kotlinc = std::env::var("KOTLINC_NATIVE").unwrap_or_else(|_| "kotlinc-native".into());
    let names: Vec<String> = files.iter().map(|f| f.display().to_string()).collect();
    // the compiler is stamped too: a new one rebuilds
    let mut stamped = files.clone();
    stamped.extend(on_path(&kotlinc));
    let st = stamp(&stamped, &format!("kotlin {} {} release={} {kotlinc}", r.alias, names.join(" "), r.release));
    if fresh(r, &st) {
        return Ok(());
    }

    let mut p = Parser::default();
    for f in &files {
        let text = std::fs::read_to_string(f).map_err(|e| format!("use kotlin: can't read {}: {e}", f.display()))?;
        p.decls(&lex(&plain_strings(&text)), None, false);
    }
    let (model, kotlin) = p.finish();
    let (shim, volt) = Gen::new(&model, &r.alias, &kotlin).write(if files.len() == 1 { "the file" } else { "the files" });

    let shim_file = r.out.join("shim.kt");
    crate::build::write_if_changed(&shim_file, &shim)?;
    // a static library: the files, the shim and the Kotlin/Native runtime (two imports' archives
    // link into one program and share one runtime)
    let name = format!("volt_import_{}", r.alias);
    let mut c = Command::new(&kotlinc);
    c.args(["-produce", "static", "-nowarn", "-o"]).arg(r.out.join(&name));
    if r.release {
        c.arg("-opt");
    }
    c.args(&files).arg(&shim_file);
    let o = c.output().map_err(|e| format!("use kotlin: can't run {kotlinc}: {e} (set $KOTLINC_NATIVE to the kotlinc-native to use)"))?;
    if !o.status.success() {
        return Err(format!("use kotlin: kotlinc-native couldn't build the glue for {}:\n{}{}", names.join(", "), String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr)));
    }
    let lib = r.out.join(format!("lib{name}.a"));
    let mut flags = vec![lib.display().to_string()];
    flags.extend(["-lpthread", "-ldl", "-lm", "-lstdc++"].map(String::from));
    save(r, &Made { volt, flags, deps: files }, &st)
}

/// the file a command runs: itself when it's a path, else the first on $PATH
fn on_path(cmd: &str) -> Option<PathBuf> {
    if cmd.contains('/') {
        return Some(PathBuf::from(cmd));
    }
    std::env::split_paths(&std::env::var_os("PATH")?).map(|d| d.join(cmd)).find(|p| p.is_file())
}

// ---------- the files' declarations ----------

/// what can come before a declaration's keyword
const MODIFIERS: &[&str] = &[
    "public", "internal", "private", "protected", "open", "abstract", "final", "override", "data", "enum", "sealed", "inline", "value", "inner", "companion", "suspend", "operator", "infix", "tailrec",
    "external", "const", "lateinit", "annotation", "expect", "actual", "noinline", "crossinline", "vararg",
];

/// what a declaration starts with (past its annotations and modifiers)
const KEYWORDS: &[&str] = &["fun", "class", "interface", "object", "val", "var", "typealias", "constructor", "init", "import", "package"];

#[derive(Default)]
struct Parser {
    m: Model,
    /// a type's declaration index in m.types
    at: BTreeMap<String, usize>,
    /// the packages the files are in (the shim imports each)
    packages: BTreeSet<String>,
    /// properties read without parentheses, and constructors (T::new...), by (type, name)
    props: BTreeSet<(String, String)>,
    inits: BTreeSet<(String, String)>,
    /// data classes whose primary constructor's parameters are all vals (fields, in order)
    data: BTreeSet<String>,
    /// types with a stored property of their own (not a data class's plain value), types with a
    /// constructor written, and types nothing outside can construct (abstract, sealed, objects)
    stored: BTreeSet<String>,
    has_ctor: BTreeSet<String>,
    no_ctor: BTreeSet<String>,
    /// the names taken in each scope (a type, or "")
    taken: BTreeSet<(String, String)>,
}

/// a declaration's modifiers
#[derive(Default, Clone, Copy)]
struct Mods {
    private: bool,
    abstract_: bool,
    data: bool,
    is_enum: bool,
    companion: bool,
    suspend: bool,
    vararg: bool,
}

impl Parser {
    fn finish(mut self) -> (Model, Kotlin) {
        let types: Vec<String> = self.m.types.iter().filter(|t| !t.is_enum).map(|t| t.name.clone()).collect();
        for t in types {
            // a class without a constructor written has Kotlin's T()
            if !self.has_ctor.contains(&t) && !self.no_ctor.contains(&t) {
                self.ctor(&t, Vec::new(), None);
            }
        }
        // by value: a data class of vals with no stored property of its own, whose fields are
        // numbers, Booleans, enum classes or such data classes (until nothing changes); any other
        // data class is a handle, its fields methods
        let enums: BTreeSet<String> = self.m.types.iter().filter(|t| t.is_enum).map(|t| t.name.clone()).collect();
        let mut by_value: BTreeSet<String> = self.data.difference(&self.stored).cloned().collect();
        loop {
            let plain = |t: &Option<Ty>| match t {
                Some(Ty::Prim(_)) => true,
                Some(Ty::Named(n)) => enums.contains(n) || by_value.contains(n),
                _ => false,
            };
            let out: Vec<String> = self.m.types.iter().filter(|t| by_value.contains(&t.name) && !t.fields.iter().flatten().all(|f| plain(&f.2))).map(|t| t.name.clone()).collect();
            if out.is_empty() {
                break;
            }
            for n in out {
                by_value.remove(&n);
            }
        }
        let handles: Vec<(String, Vec<(String, bool, Option<Ty>)>)> = self.m.types.iter().filter(|t| self.data.contains(&t.name) && !by_value.contains(&t.name)).map(|t| (t.name.clone(), t.fields.clone().unwrap_or_default())).collect();
        for (t, fields) in handles {
            for (f, public, ty) in fields {
                if public {
                    self.property_method(&t, f, ty, false);
                }
            }
        }
        for t in &mut self.m.types {
            let by_value = by_value.contains(&t.name);
            if !by_value {
                t.fields = None;
            }
            // a reference: its handle's copy shares it
            t.clone = true;
            t.opaque = !by_value && !t.is_enum;
        }
        let kotlin = Kotlin { props: self.props, inits: self.inits, packages: self.packages };
        (self.m, kotlin)
    }

    /// the annotations and modifiers before a declaration (or a parameter)
    fn mods(c: &mut Cur) -> Mods {
        let mut m = Mods::default();
        loop {
            match c.peek() {
                Some(Tok::Id(w)) if w.starts_with('@') => {
                    c.i += 1;
                    // @file:Name, @get:Name
                    if c.eat(":") {
                        c.id();
                    }
                    while c.eat(".") {
                        c.id();
                    }
                    if c.is("(") {
                        c.skip_group();
                    }
                }
                Some(Tok::Id(w)) if MODIFIERS.contains(&w.as_str()) && Self::modifier_at(c) => {
                    match w.as_str() {
                        "private" | "protected" => m.private = true,
                        "abstract" | "sealed" => m.abstract_ = true,
                        "data" => m.data = true,
                        "enum" => m.is_enum = true,
                        "companion" => m.companion = true,
                        "suspend" => m.suspend = true,
                        "vararg" => m.vararg = true,
                        _ => {}
                    }
                    c.i += 1;
                }
                _ => return m,
            }
        }
    }

    /// whether the modifier word at c is one (followed by more modifiers and a declaration's or a
    /// parameter's start), not a name that happens to be spelled so (value, data)
    fn modifier_at(c: &Cur) -> bool {
        let mut k = c.i;
        while let Some(Tok::Id(w)) = c.t.get(k) {
            if KEYWORDS.contains(&w.as_str()) || w.starts_with('@') {
                return true;
            }
            if !MODIFIERS.contains(&w.as_str()) {
                // a parameter's name after its modifiers (vararg xs: Int)
                return k > c.i && matches!(c.t.get(k + 1), Some(Tok::P(p)) if p == ":");
            }
            k += 1;
        }
        false
    }

    /// whether c is at the start of a declaration
    fn at_decl(c: &Cur) -> bool {
        if c.i > 0 && matches!(&c.t[c.i - 1], Tok::P(p) if p == "::" || p == ".") {
            return false;
        }
        match c.peek() {
            Some(Tok::Id(w)) if w.starts_with('@') || KEYWORDS.contains(&w.as_str()) => true,
            Some(Tok::Id(w)) if MODIFIERS.contains(&w.as_str()) => Self::modifier_at(c),
            _ => false,
        }
    }

    /// past what's left of a declaration (or an expression body): to the start of the next one
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

    /// the tokens of a type: a name (dotted, with type arguments) or a function type, and a ?
    fn ty_tokens(c: &mut Cur) -> Vec<Tok> {
        let s = c.i;
        while matches!(c.peek(), Some(Tok::Id(w)) if w.starts_with('@') || w == "suspend") {
            c.i += 1;
        }
        if c.is("(") {
            c.skip_group();
            if c.eat("->") {
                Self::ty_tokens(c);
            }
        } else {
            while c.id().is_some() {
                if c.is("<") {
                    c.skip_group();
                }
                if !c.eat(".") {
                    break;
                }
            }
        }
        c.eat("?");
        c.t[s..c.i].to_vec()
    }

    /// a scope's declarations: a file's, or a type's body (`owner`); `statics`: an object's or a
    /// companion object's body, whose funs are the owner's T::f
    fn decls(&mut self, t: &[Tok], owner: Option<&str>, statics: bool) {
        let mut c = Cur { t, i: 0 };
        while c.i < t.len() {
            let start = c.i;
            let m = Self::mods(&mut c);
            let kw = match c.peek() {
                Some(Tok::Id(w)) => w.clone(),
                _ => {
                    Self::skip(&mut c);
                    continue;
                }
            };
            match kw.as_str() {
                "package" => {
                    c.i += 1;
                    let mut name = c.id().unwrap_or_default();
                    while c.eat(".") {
                        name = format!("{name}.{}", c.id().unwrap_or_default());
                    }
                    if owner.is_none() && !name.is_empty() {
                        self.packages.insert(name);
                    }
                }
                "import" => {
                    // import a.b.C, import a.b.*, import a.b.C as D
                    c.i += 1;
                    c.id();
                    while c.eat(".") {
                        if !c.eat("*") {
                            c.id();
                        }
                    }
                    if c.eat("as") {
                        c.id();
                    }
                }
                "fun" if matches!(c.t.get(c.i + 1), Some(Tok::Id(w)) if w == "interface") => {
                    c.i += 1;
                    self.type_decl(&mut c, owner, "interface", m);
                }
                "fun" => self.func(&mut c, owner, m, statics),
                "class" | "interface" => self.type_decl(&mut c, owner, &kw, m),
                "object" => {
                    if m.companion && !statics {
                        // companion object [Name] [: ...] { body }: the owner's statics
                        c.i += 1;
                        c.id();
                        while c.i < t.len() && !c.is("{") && !Self::at_decl(&c) {
                            c.i += 1;
                        }
                        if c.is("{") {
                            let open = c.i;
                            c.skip_group();
                            if let (Some(o), false) = (owner, m.private) {
                                self.decls(&t[open + 1..c.i - 1], Some(o), true);
                            }
                        }
                    } else {
                        self.type_decl(&mut c, owner, "object", m);
                    }
                }
                "val" | "var" => self.property(&mut c, owner, m, statics),
                "constructor" => self.secondary(&mut c, owner, m),
                "init" => {
                    c.i += 1;
                    if c.is("{") {
                        c.skip_group();
                    }
                }
                "typealias" => {
                    if !m.private {
                        let name = match c.t.get(c.i + 1) {
                            Some(Tok::Id(n)) => n.clone(),
                            _ => String::new(),
                        };
                        self.m.left_out.push(format!("{name} (a typealias)"));
                    }
                    Self::skip(&mut c);
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

    fn add(&mut self, owner: Option<&str>, s: Sig) -> bool {
        let who = match owner {
            Some(o) => format!("{o}.{}", s.name),
            None => s.name.clone(),
        };
        if !spellable(&s.name) {
            self.m.left_out.push(format!("{who} (its name isn't one Volt can spell)"));
            return false;
        }
        if owner.is_some() && (s.name == "drop" || s.name == "clone") {
            self.m.left_out.push(format!("{who} (the glue's own name for the handle)"));
            return false;
        }
        if !self.take(owner, &s.name) {
            self.m.left_out.push(format!("{who} (an overload: Volt has the first one of that name)"));
            return false;
        }
        match owner {
            Some(o) => self.m.methods.entry(o.to_string()).or_default().push(s),
            None => self.m.fns.push((Vec::new(), s)),
        }
        true
    }

    /// a parameter list: Volt's (name, type); `ctor`: a primary constructor's, whose val and var
    /// parameters are properties (name, type, a val, private)
    fn params(items: &[Vec<Tok>], owner: Option<&str>, s: &mut Sig, props: &mut Vec<(String, Option<Ty>, bool, bool)>) {
        for (n, p) in items.iter().enumerate() {
            let mut c = Cur { t: p, i: 0 };
            let m = Self::mods(&mut c);
            let is_val = c.is_id("val");
            let is_prop = c.eat("val") || c.eat("var");
            let name = c.id().unwrap_or_default();
            if !c.eat(":") {
                s.skip = Some("a parameter");
                continue;
            }
            // its type, up to a default value
            let t = parse_ty(&Self::ty_tokens(&mut c), owner);
            if m.vararg {
                s.skip = Some("a vararg parameter");
            }
            if is_prop {
                props.push((name.clone(), t.clone(), is_val, m.private));
            }
            let pname = if spellable(&name) { name } else { format!("a{n}") };
            s.params.push((pname, t));
        }
    }

    /// T::new for a constructor of owner's with these parameters (T::new_<first> when there's one)
    fn ctor(&mut self, owner: &str, params: Vec<(String, Option<Ty>)>, skip: Option<&'static str>) {
        let name = if self.taken.contains(&(owner.to_string(), "new".to_string())) { format!("new_{}", params.first().map_or("", |p| p.0.as_str())) } else { "new".into() };
        let s = Sig { name: name.clone(), recv: Recv::None, params, ret: Some(Ty::SelfTy), skip, src: String::new(), generics: Vec::new(), call: None };
        if self.add(Some(owner), s) {
            self.inits.insert((owner.to_string(), name));
        }
    }

    /// fun [<T>] [Recv.]NAME(params)[: T] [where ...] (= expr | { ... })
    fn func(&mut self, c: &mut Cur, owner: Option<&str>, m: Mods, statics: bool) {
        let start = c.i;
        c.i += 1;
        let generic = c.is("<");
        if generic {
            c.skip_group();
        }
        let Some(mut name) = c.id() else {
            Self::skip(c);
            return;
        };
        // an extension: fun Recv.name(), fun List<Int>.name()
        let mut extension = false;
        if c.is("<") {
            c.skip_group();
        }
        c.eat("?");
        while c.eat(".") {
            extension = true;
            name = c.id().unwrap_or_default();
        }
        if !c.is("(") {
            Self::skip(c);
            return;
        }
        let items = c.group_items();
        let mut ret = Some(Ty::Unit);
        let mut untyped = false;
        if c.eat(":") {
            ret = parse_ty(&Self::ty_tokens(c), owner);
        } else if c.is("=") {
            untyped = true;
        }
        let src = toks_line(&c.t[start..c.i]);
        if c.is_id("where") {
            while c.i < c.t.len() && !c.is("{") && !c.is("=") && !Self::at_decl(c) {
                c.i += 1;
            }
        }
        if c.eat("=") {
            Self::skip_expr(c);
        } else if c.is("{") {
            c.skip_group();
        }
        if m.private {
            return;
        }
        if extension {
            self.m.left_out.push(format!("{name} (an extension function)"));
            return;
        }
        let recv = if owner.is_none() || statics { Recv::None } else { Recv::Ref };
        let mut s = Sig { name, recv, params: Vec::new(), ret, skip: None, src, generics: Vec::new(), call: None };
        Self::params(&items, owner, &mut s, &mut Vec::new());
        if generic {
            s.skip = Some("it's generic");
        } else if m.suspend {
            s.skip = Some("it's a suspend fun");
        } else if untyped {
            s.skip = Some("its result type isn't written");
        }
        self.add(owner, s);
    }

    /// past an expression (a fun's body or a property's value): to the next declaration
    fn skip_expr(c: &mut Cur) {
        while c.i < c.t.len() && !Self::at_decl(c) {
            if c.is("(") || c.is("[") || c.is("{") {
                c.skip_group();
            } else {
                c.i += 1;
            }
        }
    }

    /// constructor(params) [: this(...)] [{ ... }]: T::new_<first parameter>
    fn secondary(&mut self, c: &mut Cur, owner: Option<&str>, m: Mods) {
        c.i += 1;
        let items = if c.is("(") { c.group_items() } else { Vec::new() };
        if c.eat(":") {
            c.id();
            if c.is("(") {
                c.skip_group();
            }
        }
        if c.is("{") {
            c.skip_group();
        }
        let Some(o) = owner else { return };
        self.has_ctor.insert(o.to_string());
        if m.private || self.no_ctor.contains(o) {
            return;
        }
        let mut s = Sig { name: String::new(), recv: Recv::None, params: Vec::new(), ret: None, skip: None, src: String::new(), generics: Vec::new(), call: None };
        Self::params(&items, Some(o), &mut s, &mut Vec::new());
        self.ctor(o, s.params, s.skip);
    }

    /// class, interface or object NAME [<...>] [mods constructor](params) [: supers] { body }
    fn type_decl(&mut self, c: &mut Cur, owner: Option<&str>, kw: &str, m: Mods) {
        c.i += 1;
        let Some(name) = c.id().filter(|n| !KEYWORDS.contains(&n.as_str()) && !MODIFIERS.contains(&n.as_str())) else {
            Self::skip(c);
            return;
        };
        let generic = c.is("<");
        if generic {
            c.skip_group();
        }
        // the primary constructor: [annotations, modifiers constructor] (params); modifiers not
        // followed by constructor are the next declaration's
        let back = c.i;
        let mut ctor_mods = Self::mods(c);
        if !c.eat("constructor") {
            c.i = back;
            ctor_mods = Mods::default();
        }
        let ctor = if c.is("(") { Some(c.group_items()) } else { None };
        // supertypes, a where clause: up to the body
        if c.eat(":") || c.is_id("where") {
            while c.i < c.t.len() && !c.is("{") && !Self::at_decl(c) {
                if c.is("(") || c.is("<") {
                    c.skip_group();
                } else {
                    c.i += 1;
                }
            }
        }
        let mut body: &[Tok] = &[];
        if c.is("{") {
            let open = c.i;
            c.skip_group();
            body = &c.t[open + 1..(c.i - 1).max(open + 1)];
        }
        if m.private {
            return;
        }
        if let Some(o) = owner {
            self.m.left_out.push(format!("{o}.{name} (a nested type)"));
            return;
        }
        if !spellable(&name) {
            self.m.left_out.push(format!("{name} (its name isn't one Volt can spell)"));
            return;
        }
        if kw == "interface" {
            self.m.left_out.push(format!("{name} (an interface)"));
            return;
        }
        if generic {
            self.m.left_out.push(format!("{name} (it's generic)"));
            return;
        }
        if self.at.contains_key(&name) {
            self.m.left_out.push(format!("{name} (declared twice)"));
            return;
        }
        self.at.insert(name.clone(), self.m.types.len());
        self.m.types.push(TypeDef {
            module: Vec::new(),
            name: name.clone(),
            generic: false,
            fields: Some(Vec::new()),
            variants: if m.is_enum { Some(Vec::new()) } else { None },
            is_enum: m.is_enum,
            clone: true,
            opaque: false,
            params: Vec::new(),
            rust_name: None,
        });
        if kw == "object" || m.abstract_ || m.is_enum {
            self.no_ctor.insert(name.clone());
        }
        // the primary constructor and its properties
        if let Some(items) = ctor {
            self.has_ctor.insert(name.clone());
            let mut s = Sig { name: String::new(), recv: Recv::None, params: Vec::new(), ret: None, skip: None, src: String::new(), generics: Vec::new(), call: None };
            let mut props = Vec::new();
            Self::params(&items, Some(&name), &mut s, &mut props);
            let all_vals = !props.is_empty() && props.len() == s.params.len() && props.iter().all(|p| p.2 && !p.3);
            // a data class of vals may be a Volt struct, whose fields are its properties (finish
            // gives it methods for them when it isn't one)
            let fields_only = m.data && all_vals && !ctor_mods.private;
            if fields_only {
                self.data.insert(name.clone());
            }
            for (p, t, _, private) in props {
                if let Some(fields) = &mut self.m.types[self.at[&name]].fields {
                    fields.push((p.clone(), !private && spellable(&p), t.clone()));
                }
                if !private && !fields_only {
                    self.property_method(&name, p, t, false);
                }
            }
            if !ctor_mods.private && !self.no_ctor.contains(&name) {
                self.ctor(&name, s.params, s.skip);
            }
        }
        if m.is_enum {
            body = self.entries(body, &name);
        }
        self.decls(body, Some(&name), kw == "object");
    }

    /// an enum class's entries (A, B(1), C { ... };): its variants, by ordinal; what's after them
    fn entries<'t>(&mut self, body: &'t [Tok], owner: &str) -> &'t [Tok] {
        let mut c = Cur { t: body, i: 0 };
        let at = self.at[owner];
        let mut k = 0;
        while c.i < body.len() {
            Self::mods(&mut c);
            let Some(n) = c.id() else { break };
            if c.is("(") {
                c.skip_group();
            }
            if c.is("{") {
                c.skip_group();
            }
            if let Some(vs) = &mut self.m.types[at].variants {
                if spellable(&n) {
                    vs.push((n, k));
                } else {
                    self.m.types[at].variants = None;
                }
            }
            k += 1;
            if !c.eat(",") {
                break;
            }
            if c.is(";") || c.i >= body.len() {
                break;
            }
        }
        c.eat(";");
        &body[c.i..]
    }

    /// a property read as a method without arguments (statics: an object's or a companion's)
    fn property_method(&mut self, owner: &str, name: String, t: Option<Ty>, statics: bool) {
        let recv = if statics { Recv::None } else { Recv::Ref };
        let s = Sig { name: name.clone(), recv, params: Vec::new(), ret: t, skip: None, src: String::new(), generics: Vec::new(), call: None };
        if self.add(Some(owner), s) {
            self.props.insert((owner.to_string(), name));
        }
    }

    /// val/var NAME[: T] [= value | by delegate] [get()...] [set...]: a constant at the top level;
    /// in a type, a property (stored, unless it has a getter and no value)
    fn property(&mut self, c: &mut Cur, owner: Option<&str>, m: Mods, statics: bool) {
        let is_var = c.is_id("var");
        c.i += 1;
        if c.is("<") {
            c.skip_group();
        }
        let Some(name) = c.id() else {
            Self::skip(c);
            return;
        };
        // an extension property: val Recv.name
        if c.is(".") || c.is("<") {
            Self::skip(c);
            return;
        }
        let tt = if c.eat(":") { Self::ty_tokens(c) } else { Vec::new() };
        let mut value: Vec<Tok> = Vec::new();
        let has_value = c.is("=") || c.is_id("by");
        if has_value {
            c.i += 1;
            let s = c.i;
            Self::skip_expr(c);
            value = c.t[s..c.i].to_vec();
        }
        // get() and set(): what's left of it
        let s = c.i;
        Self::skip_expr(c);
        let getter = c.t[s..c.i].windows(2).any(|w| w[0] == Tok::Id("get".into()) && w[1] == Tok::P("(".into())) || value.windows(2).any(|w| w[0] == Tok::Id("get".into()) && w[1] == Tok::P("(".into()));
        let Some(o) = owner else {
            if !m.private && !is_var && spellable(&name) {
                if let Some((t, text)) = literal(&tt, &value) {
                    let vt = match t {
                        Ty::Prim(p) => p.to_string(),
                        _ => "str".to_string(),
                    };
                    self.m.consts.push((Vec::new(), name, vt, text));
                }
            }
            return;
        };
        if !statics && (has_value || !getter) {
            self.stored.insert(o.to_string());
        }
        if m.private {
            return;
        }
        let ty = if tt.is_empty() { literal(&[], &value).map(|l| l.0) } else { parse_ty(&tt, Some(o)) };
        self.property_method(o, name, ty, statics);
    }
}

/// whether a Kotlin name is one Volt can spell (ASCII letters, digits and _)
fn spellable(n: &str) -> bool {
    !n.is_empty() && n.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') && !n.as_bytes()[0].is_ascii_digit()
}

/// Kotlin's source with each string bolt's lexer can't read whole made one it can: a raw one
/// ("""...""") or one with templates ($name, ${...}, which can hold quotes and braces of their own)
/// becomes "$", which no constant is read from
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
        } else if b[i] == b'\'' {
            // a char literal ('"', '\'', 'A')
            i += 1;
            while i < b.len() && b[i] != b'\'' && b[i] != b'\n' {
                i += if b[i] == b'\\' { 2 } else { 1 };
            }
            i += 1;
        } else if b[i] == b'"' {
            let (end, plain) = string_end(b, i);
            if !plain {
                out.push_str(&src[last..i]);
                out.push_str("\"$\"");
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

/// where the string literal at i ends, and whether it's plain (one line, not raw, no template)
fn string_end(b: &[u8], mut i: usize) -> (usize, bool) {
    if b[i..].starts_with(b"\"\"\"") {
        i += 3;
        while i < b.len() && !b[i..].starts_with(b"\"\"\"") {
            if b[i..].starts_with(b"${") {
                i = template_end(b, i + 2);
                continue;
            }
            i += 1;
        }
        // """ closes it; more quotes before those are the string's
        while b.get(i + 3) == Some(&b'"') {
            i += 1;
        }
        return ((i + 3).min(b.len()), false);
    }
    i += 1;
    let mut plain = true;
    while i < b.len() && b[i] != b'"' && b[i] != b'\n' {
        if b[i] == b'\\' {
            i += 2;
            continue;
        }
        if b[i] == b'$' {
            if b.get(i + 1) == Some(&b'{') {
                plain = false;
                i = template_end(b, i + 2);
                continue;
            }
            if b.get(i + 1).is_some_and(|c| c.is_ascii_alphabetic() || *c == b'_') {
                plain = false;
            }
        }
        i += 1;
    }
    ((i + 1).min(b.len()), plain)
}

/// past a ${...} template, from just after its "{": to just after its "}"
fn template_end(b: &[u8], mut i: usize) -> usize {
    let mut depth = 1;
    while i < b.len() {
        if b[i] == b'"' {
            i = string_end(b, i).0;
            continue;
        }
        if b[i] == b'\'' {
            i += 1;
            while i < b.len() && b[i] != b'\'' {
                i += if b[i] == b'\\' { 2 } else { 1 };
            }
            i += 1;
            continue;
        }
        match b[i] {
            b'{' => depth += 1,
            b'}' => {
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

/// a literal value and its type: an integer (10, 10L, 10u), a float (1.5, 1.5f), a bool or a
/// string without templates
fn literal(tt: &[Tok], value: &[Tok]) -> Option<(Ty, String)> {
    let t = if tt.is_empty() { None } else { parse_ty(tt, None) };
    // a suffix on the last number: L, u, uL, f
    let (neg, rest) = match value {
        [Tok::P(m), rest @ ..] if m == "-" => ("-", rest),
        _ => ("", value),
    };
    let num = |n: &str| -> Option<(String, &'static str)> {
        let n = n.to_ascii_lowercase();
        for (suf, ty) in [("ul", "u64"), ("u", "u32"), ("l", "i64"), ("f", "f32")] {
            if let Some(d) = n.strip_suffix(suf) {
                if !n.starts_with("0x") || suf != "f" {
                    return Some((d.to_string(), ty));
                }
            }
        }
        None
    };
    let (text, ty) = match rest {
        [Tok::Num(n)] if n.contains(['e', 'E']) && !n.starts_with("0x") => {
            let v: f64 = n.trim_end_matches(['f', 'F']).parse().ok()?;
            let text = format!("{v:?}");
            if text.contains('e') {
                return None;
            }
            (text, if n.ends_with(['f', 'F']) { "f32" } else { "f64" })
        }
        [Tok::Num(n)] => match num(n) {
            Some((d, ty)) => (d, ty),
            None => {
                let v = int_value(&[Tok::Num(n.clone())])?;
                (number(&[Tok::Num(n.clone())])?.0, if i32::try_from(if neg.is_empty() { v } else { -v }).is_ok() { "i32" } else { "i64" })
            }
        },
        [Tok::Num(a), Tok::P(dot), Tok::Num(f)] if dot == "." => {
            let (d, ty) = match num(f) {
                Some((d, "f32")) => (d, "f32"),
                _ => (f.clone(), "f64"),
            };
            (format!("{a}.{d}"), ty)
        }
        [Tok::Id(b)] if neg.is_empty() && (b == "true" || b == "false") => (b.clone(), "bool"),
        [Tok::Str(s)] if neg.is_empty() && !s.contains('$') => return matches!(t, None | Some(Ty::Str)).then(|| (Ty::Str, format!("\"{s}\""))),
        _ => return None,
    };
    let text = format!("{neg}{text}");
    match t {
        None => Some((Ty::Prim(ty), text)),
        Some(Ty::Prim(x)) if x == "bool" || ty == "bool" => (x == ty).then_some((Ty::Prim(x), text)),
        // a number fits a float of either size, an integer type takes an integer
        Some(Ty::Prim(x)) if x.starts_with('f') || !ty.starts_with('f') => Some((Ty::Prim(x), text)),
        _ => None,
    }
}

/// a Kotlin type from its tokens, when it's one Volt can name; `owner`'s name is Self
fn parse_ty(t: &[Tok], owner: Option<&str>) -> Option<Ty> {
    let is = |i: usize, p: &str| matches!(t.get(i), Some(Tok::P(q)) if q == p);
    // annotations on it
    if let [Tok::Id(w), rest @ ..] = t {
        if w.starts_with('@') {
            return parse_ty(rest, owner);
        }
    }
    let n = t.len();
    if n > 1 && is(n - 1, "?") {
        return match parse_ty(&t[..n - 1], owner)? {
            Ty::Opt(_) | Ty::Unit => None,
            x => Some(Ty::Opt(Box::new(x))),
        };
    }
    // a name, maybe dotted (kotlin.Int, geo.Point), with type arguments last (List<Int>)
    let (path, args) = match t.iter().position(|x| *x == Tok::P("<".into())) {
        Some(lt) if is(n - 1, ">") => (&t[..lt], Some(&t[lt + 1..n - 1])),
        Some(_) => return None,
        None => (t, None),
    };
    if path.is_empty() || path.iter().enumerate().any(|(i, x)| if i % 2 == 0 { !matches!(x, Tok::Id(_)) } else { *x != Tok::P(".".into()) }) {
        return None;
    }
    let Some(Tok::Id(name)) = path.last() else { return None };
    if let Some(args) = args {
        return match name.as_str() {
            "List" | "Collection" | "Iterable" => match parse_ty(args, owner)? {
                e @ (Ty::Prim(_) | Ty::Str) => Some(Ty::Vec(Box::new(e))),
                _ => None,
            },
            _ => None,
        };
    }
    Some(match name.as_str() {
        "Unit" => Ty::Unit,
        "Int" => Ty::Prim("i32"),
        "Long" => Ty::Prim("i64"),
        "Short" => Ty::Prim("i16"),
        "Byte" => Ty::Prim("i8"),
        "UInt" => Ty::Prim("u32"),
        "ULong" => Ty::Prim("u64"),
        "UShort" => Ty::Prim("u16"),
        "UByte" => Ty::Prim("u8"),
        "Double" => Ty::Prim("f64"),
        "Float" => Ty::Prim("f32"),
        "Boolean" => Ty::Prim("bool"),
        "String" => Ty::Str,
        n if owner == Some(n) => Ty::SelfTy,
        n if prim(n).is_some() => return None, // a Volt name, not a Kotlin type
        "Char" | "Any" | "Nothing" | "Array" | "List" | "MutableList" | "Map" | "MutableMap" | "Set" | "MutableSet" | "Pair" | "Triple" | "Sequence" | "Throwable" | "Exception" | "Number"
        | "CharSequence" | "Comparable" | "IntArray" | "LongArray" | "DoubleArray" | "FloatArray" | "ByteArray" | "ShortArray" | "BooleanArray" | "CharArray" => return None,
        n => Ty::Named(n.to_string()),
    })
}

// ---------- the shim, in Kotlin ----------

pub struct Kotlin {
    props: BTreeSet<(String, String)>,
    inits: BTreeSet<(String, String)>,
    packages: BTreeSet<String>,
}

/// a Volt number type's Kotlin name
fn kt_prim(x: &str) -> &'static str {
    match x {
        "i8" => "Byte",
        "i16" => "Short",
        "i32" => "Int",
        "i64" | "isize" => "Long",
        "u8" => "UByte",
        "u16" => "UShort",
        "u32" => "UInt",
        "u64" | "usize" => "ULong",
        "f32" => "Float",
        "f64" => "Double",
        _ => "Boolean",
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

impl Kotlin {
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

impl Lang for Kotlin {
    fn catches(&self) -> bool {
        // any call can throw: each shim function catches it (status 2, its text)
        true
    }

    fn short(&self) -> &'static str {
        "kotlin"
    }

    fn name(&self) -> &'static str {
        "Kotlin"
    }

    fn by_value_moves(&self, _ti: &TypeInfo) -> bool {
        // a data class's value copies, an object is shared: nothing is left empty
        false
    }

    fn param(&self, g: &Gen, t: &Ty, a: &str) -> Option<ShimParam> {
        let mut p = ShimParam::default();
        match t {
            Ty::Prim(x) => {
                p.params.push(format!("{a}: {}", kt_prim(x)));
                p.arg = a.to_string();
            }
            Ty::Str => {
                p.params.extend([format!("{a}: CPointer<ByteVar>?"), format!("{a}_n: ULong")]);
                p.arg = format!("__voltS({a}, {a}_n)");
            }
            Ty::Vec(e) => match &**e {
                Ty::Prim(x) => {
                    p.params.extend([format!("{a}: CPointer<{}Var>?", kt_prim(x)), format!("{a}_n: ULong")]);
                    p.arg = format!("List({a}_n.toInt()) {{ {a}!![it] }}");
                }
                Ty::Str => {
                    p.params.extend([format!("{a}: COpaquePointer?"), format!("{a}_n: ULong")]);
                    p.arg = format!("__voltStrs({a}, {a}_n)");
                }
                _ => return None,
            },
            Ty::Opt(inner) => match &**inner {
                Ty::Prim(x) => {
                    p.params.extend([format!("{a}_has: Boolean"), format!("{a}: {}", kt_prim(x))]);
                    p.arg = format!("(if ({a}_has) {a} else null)");
                }
                Ty::Str => {
                    p.params.extend([format!("{a}: CPointer<ByteVar>?"), format!("{a}_n: ULong")]);
                    p.arg = format!("(if ({a} == null) null else __voltS({a}, {a}_n))");
                }
                _ => return None,
            },
            Ty::Named(_) => {
                let ti = g.info(t)?;
                let n = &ti.def.name;
                match ti.kind {
                    Kind::Plain => {
                        p.params.push(format!("{a}: COpaquePointer?"));
                        p.arg = format!("__volt_from_{n}({a}!!)");
                    }
                    Kind::Handle => {
                        p.params.push(format!("{a}: COpaquePointer?"));
                        p.arg = format!("{a}!!.asStableRef<{n}>().get()");
                    }
                    Kind::Enum => {
                        p.params.push(format!("{a}: Long"));
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
        if recv != Recv::Ref {
            return None;
        }
        match ti.kind {
            Kind::Plain => {
                p.params.push("self: COpaquePointer?".into());
                p.pre.push(format!("val self_v = __volt_from_{n}(self!!)"));
                p.arg = "self_v".into();
            }
            Kind::Handle => {
                p.params.push("self: COpaquePointer?".into());
                p.arg = format!("self!!.asStableRef<{n}>().get()");
            }
            Kind::Enum => {
                p.params.push("self: Long".into());
                p.pre.push(format!("val self_v = __volt_from_{n}(self)"));
                p.arg = "self_v".into();
            }
        }
        Some(p)
    }

    fn out(&self, g: &Gen, t: &Ty, o: &str, _owned: bool) -> Option<ShimOut> {
        Some(match t {
            Ty::Prim(x) => ShimOut { params: vec![format!("{o}: CPointer<{}Var>?", kt_prim(x))], store: format!("{o}!!.pointed.value = $v") },
            Ty::Str => ShimOut { params: vec![format!("{o}: CPointer<CPointerVar<ByteVar>>?"), format!("{o}_n: CPointer<ULongVar>?")], store: format!("__voltPutS($v, {o}, {o}_n)") },
            Ty::Vec(e) => match &**e {
                Ty::Prim(x) => ShimOut {
                    params: vec![format!("{o}: CPointer<CPointerVar<{}Var>>?", kt_prim(x)), format!("{o}_n: CPointer<ULongVar>?")],
                    store: format!("__voltPut_{x}($v, {o}, {o}_n)"),
                },
                Ty::Str => ShimOut { params: vec![format!("{o}: CPointer<COpaquePointerVar>?"), format!("{o}_n: CPointer<ULongVar>?")], store: format!("__voltPutStrs($v, {o}, {o}_n)") },
                _ => return None,
            },
            Ty::Named(_) => {
                let ti = g.info(t)?;
                let n = &ti.def.name;
                match ti.kind {
                    Kind::Plain => ShimOut { params: vec![format!("{o}: COpaquePointer?")], store: format!("__volt_to_{n}($v, {o}!!)") },
                    Kind::Handle => ShimOut { params: vec![format!("{o}: CPointer<COpaquePointerVar>?")], store: format!("{o}!!.pointed.value = StableRef.create($v).asCPointer()") },
                    Kind::Enum => ShimOut { params: vec![format!("{o}: CPointer<LongVar>?")], store: format!("{o}!!.pointed.value = __volt_to_{n}($v)") },
                }
            }
            Ty::Opt(inner) => {
                let x = self.out(g, inner, o, false)?;
                let mut params = vec![format!("{o}_has: CPointer<BooleanVar>?")];
                params.extend(x.params);
                ShimOut { params, store: format!("val w = $v; if (w != null) {{ {o}_has!!.pointed.value = true; {} }} else {{ {o}_has!!.pointed.value = false }}", x.store.replace("$v", "w")) }
            }
            _ => return None,
        })
    }

    fn call(&self, _g: &Gen, _module: &[String], s: &Sig, self_ty: Option<&TypeInfo>, recv: Option<&str>, args: &[String]) -> String {
        let owner = self_ty.map(|t| t.def.name.clone()).unwrap_or_default();
        let key = (owner.clone(), s.name.clone());
        if self.props.contains(&key) {
            return match recv {
                Some(r) => format!("{r}.{}", s.name),
                None => format!("{owner}.{}", s.name),
            };
        }
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

    fn function(&self, sym: &str, params: &[String], pre: &[String], call: &str, post: &[String], store: Option<&str>, _res: bool) -> String {
        let mut ps = params.to_vec();
        ps.extend(["e: CPointer<CPointerVar<ByteVar>>?".to_string(), "e_n: CPointer<ULongVar>?".to_string()]);
        let mut body = String::new();
        for l in pre {
            let _ = writeln!(body, "        {l}");
        }
        match store {
            Some(st) => {
                let _ = writeln!(body, "        val v = {call}");
                for l in post {
                    let _ = writeln!(body, "        {l}");
                }
                let _ = writeln!(body, "        {}", st.replace("$v", "v"));
            }
            None => {
                let _ = writeln!(body, "        {call}");
                for l in post {
                    let _ = writeln!(body, "        {l}");
                }
            }
        }
        // what it threw, as its text: status 2 (Volt's try_ form gives it, the plain form stops)
        format!("@CName(\"{sym}\")\nfun {sym}({}): UByte {{\n    try {{\n{body}    }} catch (t: Throwable) {{\n        __voltPutS(t.toString(), e, e_n)\n        return 2u\n    }}\n    return 0u\n}}\n\n", ps.join(", "))
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
                            let k = kt_prim(&x);
                            from.push(format!("__voltAt(p, {at}).reinterpret<{k}Var>().pointed.value"));
                            let _ = writeln!(to, "    __voltAt(p, {at}).reinterpret<{k}Var>().pointed.value = v.{f}");
                        }
                        Ty::Named(o) if g.types.get(&o).is_some_and(|x| x.kind == Kind::Enum) => {
                            from.push(format!("__volt_from_{o}(__voltAt(p, {at}).reinterpret<LongVar>().pointed.value)"));
                            let _ = writeln!(to, "    __voltAt(p, {at}).reinterpret<LongVar>().pointed.value = __volt_to_{o}(v.{f})");
                        }
                        Ty::Named(o) => {
                            from.push(format!("__volt_from_{o}(__voltAt(p, {at}))"));
                            let _ = writeln!(to, "    __volt_to_{o}(v.{f}, __voltAt(p, {at}))");
                        }
                        _ => {}
                    }
                }
                let _ = write!(out, "fun __volt_from_{n}(p: COpaquePointer): {n} = {n}({})\n\nfun __volt_to_{n}(v: {n}, p: COpaquePointer) {{\n{to}}}\n\n", from.join(", "));
            }
            Kind::Handle => {
                // the object behind a StableRef: dropping disposes it, a copy is another ref to it
                let drop = g.sym(&[&mg, "drop"]);
                let _ = write!(out, "@CName(\"{drop}\")\nfun {drop}(h: COpaquePointer?) {{\n    h!!.asStableRef<Any>().dispose()\n}}\n\n");
                if ti.def.clone {
                    let cl = g.sym(&[&mg, "clone"]);
                    let _ = write!(out, "@CName(\"{cl}\")\nfun {cl}(h: COpaquePointer?): COpaquePointer? = StableRef.create(h!!.asStableRef<Any>().get()).asCPointer()\n\n");
                }
            }
            Kind::Enum => {
                let _ = write!(out, "fun __volt_from_{n}(x: Long): {n} = {n}.entries[x.toInt()]\n\nfun __volt_to_{n}(v: {n}): Long = v.ordinal.toLong()\n\n");
            }
        }
        out
    }

    fn prelude(&self, g: &Gen) -> String {
        let free = |what: &str| format!("volt_kotlin_{}_free_{what}", g.alias);
        let mut s = String::from("// the glue between a Volt program and this Kotlin, written by bolt import (use kotlin)\n");
        s.push_str("@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlin.experimental.ExperimentalNativeApi::class)\n\n");
        s.push_str("import kotlinx.cinterop.*\nimport kotlin.native.CName\n");
        for p in &self.packages {
            let _ = writeln!(s, "import {p}.*");
        }
        s.push_str("\n// the byte at offset at of p\nfun __voltAt(p: COpaquePointer, at: Int): COpaquePointer = interpretCPointer<ByteVar>(p.rawValue + at.toLong())!!\n\n");
        s.push_str("fun __voltS(p: CPointer<ByteVar>?, n: ULong): String = if (p == null || n == 0uL) \"\" else p.readBytes(n.toInt()).decodeToString()\n\n");
        s.push_str("// Volt's str[..]: a pointer and a length each\nfun __voltStrs(p: COpaquePointer?, n: ULong): List<String> {\n    if (p == null) return emptyList()\n    val w = p.reinterpret<LongVar>()\n    return List(n.toInt()) { i -> __voltS(w[2 * i].toCPointer<ByteVar>(), w[2 * i + 1].toULong()) }\n}\n\n");
        s.push_str("// a copy for Volt, which gives it back to the free functions below\nfun __voltPutS(s: String, o: CPointer<CPointerVar<ByteVar>>?, n: CPointer<ULongVar>?) {\n    val b = s.encodeToByteArray()\n    n!!.pointed.value = b.size.toULong()\n    if (b.isEmpty()) {\n        o!!.pointed.value = null\n        return\n    }\n    val m = nativeHeap.allocArray<ByteVar>(b.size)\n    for (i in b.indices) m[i] = b[i]\n    o!!.pointed.value = m\n}\n\n");
        s.push_str("fun __voltPutStrs(v: List<String>, o: CPointer<COpaquePointerVar>?, n: CPointer<ULongVar>?) {\n    n!!.pointed.value = v.size.toULong()\n    if (v.isEmpty()) {\n        o!!.pointed.value = null\n        return\n    }\n    val b = nativeHeap.allocArray<LongVar>(v.size * 2)\n    v.forEachIndexed { i, s ->\n        memScoped {\n            val p = alloc<CPointerVar<ByteVar>>()\n            val k = alloc<ULongVar>()\n            __voltPutS(s, p.ptr, k.ptr)\n            b[2 * i] = p.value.toLong()\n            b[2 * i + 1] = k.value.toLong()\n        }\n    }\n    o!!.pointed.value = b\n}\n\n");
        for x in &g.vec_elems {
            let k = kt_prim(x);
            let _ = write!(s, "fun __voltPut_{x}(v: List<{k}>, o: CPointer<CPointerVar<{k}Var>>?, n: CPointer<ULongVar>?) {{\n    n!!.pointed.value = v.size.toULong()\n    if (v.isEmpty()) {{\n        o!!.pointed.value = null\n        return\n    }}\n    val b = nativeHeap.allocArray<{k}Var>(v.size)\n    for (i in v.indices) b[i] = v[i]\n    o!!.pointed.value = b\n}}\n\n");
        }
        let q = format!("volt_kotlin_{}_quiet", g.alias);
        let _ = write!(s, "// a try_ form's call: what the shim catches it only hands back, so there's nothing to quiet\n@CName(\"{q}\")\nfun {q}(on: Boolean): Boolean = false\n\n");
        let bytes = free("bytes");
        let _ = write!(s, "@CName(\"{bytes}\")\nfun {bytes}(p: CPointer<ByteVar>?, n: ULong) {{\n    if (p != null) nativeHeap.free(p.rawValue)\n}}\n\n");
        for x in &g.vec_elems {
            let f = free(&format!("{x}s"));
            let _ = write!(s, "@CName(\"{f}\")\nfun {f}(p: CPointer<{}Var>?, n: ULong) {{\n    if (p != null) nativeHeap.free(p.rawValue)\n}}\n\n", kt_prim(x));
        }
        if g.strs {
            let f = free("strs");
            let _ = write!(s, "@CName(\"{f}\")\nfun {f}(p: COpaquePointer?, n: ULong) {{\n    if (p == null) return\n    val w = p.reinterpret<LongVar>()\n    for (i in 0 until n.toInt()) {{\n        val b = w[2 * i]\n        if (b != 0L) nativeHeap.free(b.toCPointer<ByteVar>()!!.rawValue)\n    }}\n    nativeHeap.free(p.rawValue)\n}}\n\n");
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
    fn import_kotlin_types() {
        assert_eq!(ty("Int"), Some(Ty::Prim("i32")));
        assert_eq!(ty("kotlin.Long"), Some(Ty::Prim("i64")));
        assert_eq!(ty("String?"), Some(Ty::Opt(Box::new(Ty::Str))));
        assert_eq!(ty("List<Double>"), Some(Ty::Vec(Box::new(Ty::Prim("f64")))));
        assert_eq!(ty("Map<String, Int>"), None);
        assert_eq!(ty("(Int) -> Int"), None);
        assert_eq!(ty("Shape"), Some(Ty::SelfTy));
        assert_eq!(ty("Point"), Some(Ty::Named("Point".into())));
        assert_eq!(ty("Int??"), None);
        assert_eq!(ty("i64"), None);
    }

    #[test]
    fn import_kotlin_decls() {
        let src = r#"
package geo
import kotlin.math.*
const val LIMIT = 10L
val NAME = "it's ${1 + "x".length} $LIMIT"
data class Point(val x: Double, val y: Double) {
    fun length(): Double = sqrt(x * x + y * y)
    companion object { fun origin(): Point = Point(0.0, 0.0) }
}
class Counter(val label: String) {
    var count: Int = 0
        private set
    constructor(label: String, start: Int) : this(label) { count = start }
    fun bump(k: Int): Int { count += k; return count }
    private fun hidden() = 1
}
enum class Color(val code: Int) { RED(1), GREEN(2) { override fun toString() = "g" }; fun next(): Color = RED }
object Registry { fun size(value: Int): Int = value }
fun <T> pick(x: T): T = x
fun String.shout(): String = uppercase()
fun noType(value: Int) = value + 1
"#;
        let mut p = Parser::default();
        p.decls(&lex(&plain_strings(src)), None, false);
        let (m, k) = p.finish();
        assert_eq!(m.consts.iter().map(|c| format!("{} {} {}", c.1, c.2, c.3)).collect::<Vec<_>>(), ["LIMIT i64 10"]);
        let names = |t: &str| m.methods.get(t).map(|ms| ms.iter().map(|s| s.name.clone()).collect::<Vec<_>>()).unwrap_or_default();
        assert_eq!(names("Point"), ["new", "length", "origin"]);
        assert_eq!(names("Counter"), ["label", "new", "count", "new_label", "bump"]);
        assert_eq!(names("Color"), ["code", "next"]);
        assert_eq!(names("Registry"), ["size"]);
        let ty = |n: &str| m.types.iter().find(|t| t.name == n).unwrap();
        assert!(!ty("Point").opaque && ty("Point").fields.as_ref().is_some_and(|f| f.len() == 2));
        assert!(ty("Counter").opaque && ty("Registry").opaque);
        assert_eq!(ty("Color").variants.clone().unwrap(), [("RED".to_string(), 0), ("GREEN".to_string(), 1)]);
        let fns: Vec<(String, Option<&str>)> = m.fns.iter().map(|f| (f.1.name.clone(), f.1.skip)).collect();
        assert_eq!(fns, [("pick".into(), Some("it's generic")), ("noType".into(), Some("its result type isn't written"))]);
        assert!(m.left_out.iter().any(|l| l.starts_with("shout")));
        assert!(k.inits.contains(&("Counter".into(), "new_label".into())) && k.props.contains(&("Counter".into(), "count".into())));
        assert_eq!(k.packages.iter().collect::<Vec<_>>(), ["geo"]);
    }

    /// what review found: `::class` and a modifier word in an expression, a private constructor,
    /// a data class with a field that isn't plain, a top-level var, an Int literal that's a Long,
    /// a property and a fun of one name
    #[test]
    fn import_kotlin_edges() {
        let src = r#"
fun kc() = Foo::class
fun g(): Int = 1
val k = Foo::class
fun f(m: Holder): Int = m.data
class Bar(val a: Int)
data class Money private constructor(val cents: Long) { companion object { fun of(c: Long): Money = Money(c) } }
data class User(val name: String, val age: Int)
data class Pt(val x: Int)
data class Line(val a: Pt, val b: Pt)
var hits = 0
const val BIG = 3000000000
const val SMALL = -5
class Twice { fun n(): Int = 2
    val n: Int = 1 }
"#;
        let mut p = Parser::default();
        p.decls(&lex(&plain_strings(src)), None, false);
        let (m, k) = p.finish();
        let fns: Vec<&str> = m.fns.iter().map(|f| f.1.name.as_str()).collect();
        assert_eq!(fns, ["kc", "g", "f"]);
        let names: Vec<&str> = m.types.iter().map(|t| t.name.as_str()).collect();
        assert_eq!(names, ["Bar", "Money", "User", "Pt", "Line", "Twice"]);
        let ty = |n: &str| m.types.iter().find(|t| t.name == n).unwrap();
        // by value only when Volt can build and read it: Pt and Line, not Bar (no data),
        // Money (its constructor is private) or User (a String)
        assert!(!ty("Pt").opaque && !ty("Line").opaque);
        assert!(ty("Bar").opaque && ty("Money").opaque && ty("User").opaque);
        let methods = |t: &str| m.methods.get(t).map(|ms| ms.iter().map(|s| s.name.clone()).collect::<Vec<_>>()).unwrap_or_default();
        assert_eq!(methods("Money"), ["cents", "of"]);
        assert_eq!(methods("User"), ["new", "name", "age"]);
        assert_eq!(methods("Twice"), ["n", "new"]);
        assert!(!k.props.contains(&("Twice".into(), "n".into())), "n is the fun, called with ()");
        let consts: Vec<String> = m.consts.iter().map(|c| format!("{} {} {}", c.1, c.2, c.3)).collect();
        assert_eq!(consts, ["BIG i64 3000000000", "SMALL i32 -5"]);
    }
}
