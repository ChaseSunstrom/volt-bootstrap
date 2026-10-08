// use zig { "file.zig" } as NAME; — an ordinary Zig file, called from Volt. bolt reads its public
// declarations (pub fns; pub const T = struct/enum { ... } with their fields and pub fns; pub consts
// of literals; structs without fields and pub const x = @import("x.zig") as namespaces), writes a
// shim file that imports it as a module and exports a C function for each, builds it with
// zig build-lib, and writes the Volt side (glue.rs). Nothing in the Zig code changes.
//
//   []const u8 -> str in, std::string out ([]u8 out too); []const T, []T -> T[..] in, std::vec<T>
//   out; ?T -> T?; E!T -> zig_error!T (the error's name); *T, *const T of a struct -> T&
//   a std.mem.Allocator parameter -> none in Volt: the shim passes std.heap.c_allocator, and a
//   slice such a function returns is the shim's to free (others are copied)
//   a struct whose fields are all plain -> a Volt struct, by value; any other struct -> an owned
//   handle (made with the C allocator; delete calls its deinit, when it has one, and frees it)
//   an enum -> a Volt enum with the same values
use super::glue::{number, prim, Gen, Kind, Lang, Model, Recv, ShimOut, ShimParam, Sig, Ty, TypeDef, TypeInfo};
use super::{arg_path, fresh, save, stamp, Made, Req};
use crate::foreign::{int_value, lex, toks_line, Cur, Tok};
use std::collections::BTreeSet;
use std::fmt::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn import(r: &Req) -> Result<(), String> {
    let [file] = r.args.as_slice() else {
        return Err(format!("use zig {{ \"file.zig\" }} as {}: name one Zig file", r.alias));
    };
    let file = arg_path(r, file);
    if !file.is_file() {
        return Err(format!("use zig: there's no {}", file.display()));
    }
    // the file and what it imports: any .zig file next to it or below
    let mut files = Vec::new();
    if let Some(d) = file.parent() {
        zig_files(d, &mut files);
    }
    let st = stamp(&files, &format!("zig {} {} release={}", r.alias, file.display(), r.release));
    if fresh(r, &st) {
        return Ok(());
    }

    let mut w = Walker::default();
    w.file(&file, &[]);
    let model = w.model();
    let lang = Zig { deinit: w.deinit };
    let (shim, volt) = Gen::new(&model, &r.alias, &lang).write("the file");

    let shim_file = r.out.join("shim.zig");
    crate::build::write_if_changed(&shim_file, &shim)?;
    let lib_file = r.out.join(format!("libvolt_import_{}.a", r.alias));
    let zig = std::env::var("ZIG").unwrap_or_else(|_| "zig".into());
    let mode = if r.release { "ReleaseSafe" } else { "Debug" };
    let mut c = Command::new(&zig);
    c.args(["build-lib", "-fPIC", "-fcompiler-rt", "-lc", "-O", mode, "--dep", "user"]).arg(format!("-Mroot={}", shim_file.display())).arg(format!("-Muser={}", file.display())).arg(format!("-femit-bin={}", lib_file.display()));
    c.arg("--cache-dir").arg(r.out.join("zig-cache"));
    let o = c.output().map_err(|e| format!("use zig: can't run {zig}: {e} (set $ZIG to the zig to use)"))?;
    if !o.status.success() {
        return Err(format!("use zig: zig couldn't build the glue for {}:\n{}", file.display(), String::from_utf8_lossy(&o.stderr)));
    }
    save(r, &Made { volt, flags: vec![lib_file.display().to_string()], deps: files }, &st)
}

fn zig_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    let mut paths: Vec<_> = rd.filter_map(|e| e.ok().map(|e| e.path())).collect();
    paths.sort();
    for p in paths {
        let name = p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        if p.is_dir() && !name.starts_with('.') && name != "zig-cache" && name != ".zig-cache" && name != "zig-out" {
            zig_files(&p, out);
        } else if p.extension().is_some_and(|x| x == "zig") {
            out.push(p);
        }
    }
}

// ---------- the file's public API ----------

#[derive(Default)]
struct Walker {
    m: Model,
    /// types with a deinit method, and whether it takes an allocator
    deinit: std::collections::BTreeMap<String, bool>,
    seen: BTreeSet<PathBuf>,
}

impl Walker {
    fn model(&self) -> Model {
        let mut m = Model { fns: self.m.fns.clone(), types: self.m.types.clone(), consts: self.m.consts.clone(), methods: self.m.methods.clone(), left_out: self.m.left_out.clone(), ..Model::default() };
        for t in &mut m.types {
            // a type that frees what it holds can't be copied (or held by value) safely
            let has_deinit = self.deinit.contains_key(&t.name);
            t.clone = !has_deinit && !t.is_enum;
            t.opaque = has_deinit;
        }
        m
    }

    fn file(&mut self, path: &Path, module: &[String]) {
        let path = std::fs::canonicalize(path).unwrap_or(path.to_path_buf());
        if !self.seen.insert(path.clone()) {
            return;
        }
        let Ok(text) = std::fs::read_to_string(&path) else { return };
        let t = lex(&text);
        self.container(&t, module, None, path.parent().unwrap_or(Path::new(".")));
    }

    /// a container's declarations (a file's, or a struct's or enum's body); `owner` is the type
    /// whose methods its fns are
    fn container(&mut self, t: &[Tok], module: &[String], owner: Option<&str>, dir: &Path) {
        let mut c = Cur { t, i: 0 };
        while c.i < t.len() {
            let start = c.i;
            let public = c.eat("pub");
            // past qualifiers
            while c.is_id("export") || c.is_id("inline") || c.is_id("noinline") || c.is_id("extern") || matches!(c.peek(), Some(Tok::Str(_))) {
                c.i += 1;
            }
            let qualified = c.i > start + usize::from(public);
            if c.is_id("fn") {
                let s = c.i;
                // the signature up to its body (an error{...} set in it isn't the body)
                while c.i < t.len() && !c.is(";") {
                    if c.is("(") || (c.is("{") && c.i > 0 && t[c.i - 1] == Tok::Id("error".into())) {
                        c.skip_group();
                        continue;
                    }
                    if c.is("{") {
                        break;
                    }
                    c.i += 1;
                }
                let head = &t[s..c.i];
                let has_body = c.is("{");
                if has_body {
                    c.skip_group();
                } else {
                    c.i += 1;
                }
                if public && !has_body {
                    let name = match head.get(1) {
                        Some(Tok::Id(n)) => n.clone(),
                        _ => String::new(),
                    };
                    self.m.left_out.push(format!("{name} (a declaration without a body{})", if qualified { ", defined elsewhere" } else { "" }));
                } else if public {
                    let sig = sig(head, owner);
                    match owner {
                        Some(o) if sig.name == "deinit" => {
                            self.deinit.insert(o.to_string(), sig.params.iter().any(|p| p.1 == Some(Ty::Alloc)));
                        }
                        Some(o) => self.m.methods.entry(o.to_string()).or_default().push(sig),
                        None => self.m.fns.push((module.to_vec(), sig)),
                    }
                }
                continue;
            }
            if c.is_id("const") || c.is_id("var") {
                let is_var = c.is_id("var");
                c.i += 1;
                let Some(name) = c.id() else {
                    skip_decl(&mut c);
                    continue;
                };
                let mut ty: Vec<Tok> = Vec::new();
                if c.eat(":") {
                    while c.i < t.len() && !c.is("=") && !c.is(";") {
                        ty.push(t[c.i].clone());
                        c.i += 1;
                    }
                }
                if !c.eat("=") {
                    skip_decl(&mut c);
                    continue;
                }
                let vs = c.i;
                skip_decl(&mut c);
                let value = &t[vs..c.i.saturating_sub(1)];
                if public && !is_var {
                    self.decl(&name, &ty, value, module, dir);
                }
                continue;
            }
            if c.is_id("test") || c.is_id("comptime") || c.is_id("usingnamespace") {
                skip_decl(&mut c);
                continue;
            }
            // a field (name: Type [= default],) belongs to the container's struct, read elsewhere
            if c.i == start {
                c.i += 1;
            }
            while c.i < t.len() && !c.is(",") && !c.is(";") {
                if c.is("(") || c.is("{") || c.is("[") {
                    c.skip_group();
                    continue;
                }
                c.i += 1;
            }
            c.i += 1;
        }
    }

    /// pub const NAME [: T] = value
    fn decl(&mut self, name: &str, ty: &[Tok], value: &[Tok], module: &[String], dir: &Path) {
        let words: Vec<&str> = value.iter().take(3).filter_map(|x| if let Tok::Id(w) = x { Some(w.as_str()) } else { None }).collect();
        let open = value.iter().position(|x| *x == Tok::P("{".into()));
        let body = || -> Option<&[Tok]> {
            let o = open?;
            let mut c = Cur { t: value, i: o };
            c.skip_group();
            Some(&value[o + 1..c.i - 1])
        };
        for (what, why) in [("packed", "a packed struct"), ("union", "a union"), ("opaque", "an opaque type")] {
            if words.contains(&what) {
                self.m.left_out.push(format!("{name} ({why})"));
                return;
            }
        }
        match words.first().copied() {
            Some("struct") | Some("extern") if words.contains(&"struct") => {
                let Some(b) = body() else { return };
                let fields = fields(b);
                if fields.is_empty() {
                    // a struct without fields is a namespace
                    let mut sub = module.to_vec();
                    sub.push(name.to_string());
                    self.container(b, &sub, None, dir);
                    return;
                }
                self.m.types.push(TypeDef { module: module.to_vec(), name: name.to_string(), generic: false, fields: Some(fields), variants: None, is_enum: false, clone: false, opaque: false, params: Vec::new(), rust_name: None });
                self.container(b, module, Some(name), dir);
            }
            Some("enum") => {
                let Some(b) = body() else { return };
                let mut c = Cur { t: b, i: 0 };
                let mut vs = Vec::new();
                let mut next: i128 = 0;
                // the variants come first: names up to the first declaration
                while c.i < b.len() && !c.is_id("pub") && !c.is_id("fn") && !c.is_id("const") {
                    let Some(n) = c.id() else { break };
                    if c.eat("=") {
                        let s = c.i;
                        while c.i < b.len() && !c.is(",") {
                            c.i += 1;
                        }
                        next = int_value(&b[s..c.i]).unwrap_or(next);
                    }
                    vs.push((n, next));
                    next += 1;
                    if !c.eat(",") {
                        break;
                    }
                }
                self.m.types.push(TypeDef { module: module.to_vec(), name: name.to_string(), generic: false, fields: None, variants: Some(vs), is_enum: true, clone: true, opaque: false, params: Vec::new(), rust_name: None });
                self.container(&b[c.i..], module, Some(name), dir);
            }
            Some("@import") => {
                // pub const shapes = @import("shapes.zig"): a namespace
                if let Some(Tok::Str(f)) = value.get(2) {
                    if f.ends_with(".zig") {
                        let mut sub = module.to_vec();
                        sub.push(name.to_string());
                        self.file(&dir.join(f), &sub);
                    }
                }
            }
            _ => {
                // a literal: an integer, a float, a bool or a string
                let t = parse_ty(ty, None);
                let lit = match (t, value) {
                    (Some(Ty::Prim(x)), v) if x != "bool" && number(v).is_some_and(|n| x.starts_with('f') || !n.1) => Some((x.to_string(), number(v).unwrap().0)),
                    (None, v) if ty.is_empty() && number(v).is_some() => {
                        let (n, float) = number(v).unwrap();
                        Some((if float { "f64" } else { "i64" }.to_string(), n))
                    }
                    (Some(Ty::Prim("bool")) | None, [Tok::Id(b)]) if b == "true" || b == "false" => Some(("bool".into(), b.clone())),
                    (Some(Ty::Str) | None, [Tok::Str(s)]) => Some(("str".into(), format!("\"{s}\""))),
                    _ => None,
                };
                if let Some((ty, lit)) = lit {
                    self.m.consts.push((module.to_vec(), name.to_string(), ty, lit));
                }
            }
        }
    }
}

/// past a declaration: up to and past its `;` (or a block's end), groups included
fn skip_decl(c: &mut Cur) {
    while c.i < c.t.len() {
        if c.is(";") {
            c.i += 1;
            return;
        }
        if c.is("{") || c.is("(") || c.is("[") {
            let block = c.is("{");
            c.skip_group();
            // test "x" { } and comptime { } end at their block
            if block && !c.is(";") && !c.is(",") && !c.is(".") && !c.is("catch") && !c.is("orelse") && matches!(c.t.get(c.i), Some(Tok::Id(_)) | None) {
                return;
            }
            continue;
        }
        c.i += 1;
    }
}

/// a struct body's fields: name: Type [= default], (every Zig field is visible outside)
fn fields(b: &[Tok]) -> Vec<(String, bool, Option<Ty>)> {
    let mut out = Vec::new();
    let mut c = Cur { t: b, i: 0 };
    while c.i < b.len() {
        if c.is_id("pub") || c.is_id("fn") || c.is_id("const") || c.is_id("var") || c.is_id("test") || c.is_id("comptime") || c.is_id("usingnamespace") {
            skip_decl(&mut c);
            continue;
        }
        let Some(name) = c.id() else {
            c.i += 1;
            continue;
        };
        if !c.eat(":") {
            continue;
        }
        let s = c.i;
        while c.i < b.len() && !c.is(",") && !c.is("=") {
            if c.is("(") || c.is("{") || c.is("[") {
                c.skip_group();
                continue;
            }
            c.i += 1;
        }
        let ty = parse_ty(&b[s..c.i], None);
        while c.i < b.len() && !c.is(",") {
            if c.is("(") || c.is("{") || c.is("[") {
                c.skip_group();
                continue;
            }
            c.i += 1;
        }
        c.i += 1;
        out.push((name, true, ty));
    }
    out
}

/// a fn's signature: `fn name(params) Ret`; `owner` is the struct it's declared in
fn sig(head: &[Tok], owner: Option<&str>) -> Sig {
    let name = match head.get(1) {
        Some(Tok::Id(n)) => n.clone(),
        _ => String::new(),
    };
    let mut s = Sig { name, recv: Recv::None, params: Vec::new(), ret: None, skip: None, src: format!("pub {}", toks_line(head)), generics: Vec::new(), call: None };
    let mut c = Cur { t: head, i: 2 };
    if !c.is("(") {
        s.skip = Some("its parameters");
        return s;
    }
    for (n, p) in c.group_items().into_iter().enumerate() {
        if matches!(p.first(), Some(Tok::Id(w)) if w == "comptime") {
            s.skip = Some("it has comptime parameters");
            continue;
        }
        let p: Vec<Tok> = p.into_iter().filter(|x| *x != Tok::Id("noalias".into())).collect();
        let Some(colon) = p.iter().position(|x| *x == Tok::P(":".into())) else {
            s.skip = Some("a parameter");
            continue;
        };
        let pname = match p.first() {
            Some(Tok::Id(x)) if colon == 1 && x != "_" => x.clone(),
            _ => format!("a{n}"),
        };
        let ty = parse_ty(&p[colon + 1..], owner);
        // the first parameter of the owner's own type makes a method
        if n == 0 && owner.is_some() {
            let recv = match &ty {
                Some(Ty::SelfTy) => Some(Recv::Value),
                Some(Ty::Ref(x, m)) if **x == Ty::SelfTy => Some(if *m { Recv::Mut } else { Recv::Ref }),
                _ => None,
            };
            if let Some(r) = recv {
                s.recv = r;
                continue;
            }
        }
        if matches!(ty, Some(Ty::Named(ref x)) if x == "anytype") {
            s.skip = Some("it has anytype parameters");
        }
        s.params.push((pname, ty));
    }
    let rest = &head[c.i..];
    // callconv(...) and the like before the return type
    let mut rc = Cur { t: rest, i: 0 };
    while rc.is_id("callconv") || rc.is_id("align") || rc.is_id("addrspace") || rc.is_id("linksection") {
        rc.i += 1;
        rc.skip_group();
    }
    s.ret = parse_ty(&rest[rc.i..], owner).map(|t| match t {
        // bytes come back as text
        Ty::Slice(e, _) if *e == Ty::Prim("u8") => Ty::Str,
        Ty::Res(x) if matches!(&*x, Ty::Slice(e, _) if **e == Ty::Prim("u8")) => Ty::Res(Box::new(Ty::Str)),
        Ty::Opt(x) if matches!(&*x, Ty::Slice(e, _) if **e == Ty::Prim("u8")) => Ty::Opt(Box::new(Ty::Str)),
        t => t,
    });
    s
}

/// a Zig type from its tokens, when it's one Volt can name; `owner`'s name is Self
fn parse_ty(t: &[Tok], owner: Option<&str>) -> Option<Ty> {
    let is = |i: usize, p: &str| matches!(t.get(i), Some(Tok::P(q)) if q == p);
    match t {
        [Tok::Id(v)] if v == "void" => Some(Ty::Unit),
        [Tok::P(q), rest @ ..] if q == "?" => Some(Ty::Opt(Box::new(parse_ty(rest, owner)?))),
        [Tok::P(q), rest @ ..] if q == "!" => Some(Ty::Res(Box::new(parse_ty(rest, owner)?))),
        [Tok::P(q), rest @ ..] if q == "*" => {
            let (mutable, rest) = match rest {
                [Tok::Id(c), rest @ ..] if c == "const" => (false, rest),
                _ => (true, rest),
            };
            match parse_ty(rest, owner)? {
                x @ (Ty::Named(_) | Ty::SelfTy) => Some(Ty::Ref(Box::new(x), mutable)),
                _ => None,
            }
        }
        _ if is(0, "[") && is(1, "]") => {
            let (mutable, rest) = match &t[2..] {
                [Tok::Id(c), rest @ ..] if c == "const" => (false, rest),
                rest => (true, rest),
            };
            match parse_ty(rest, owner)? {
                Ty::Prim("u8") if !mutable => Some(Ty::Str),
                e @ (Ty::Prim(_) | Ty::Str) => Some(Ty::Slice(Box::new(e), mutable)),
                _ => None,
            }
        }
        _ => {
            // E!T: an error set before the !
            if let Some(bang) = t.iter().position(|x| *x == Tok::P("!".into())) {
                return Some(Ty::Res(Box::new(parse_ty(&t[bang + 1..], owner)?)));
            }
            if let [Tok::Id(f), Tok::P(a), Tok::P(b)] = t {
                if f == "@This" && a == "(" && b == ")" {
                    return Some(Ty::SelfTy);
                }
            }
            // a name, maybe dotted (std.mem.Allocator, shapes.Shape)
            if t.is_empty() || t.iter().enumerate().any(|(i, x)| if i % 2 == 0 { !matches!(x, Tok::Id(_)) } else { *x != Tok::P(".".into()) }) {
                return None;
            }
            let Some(Tok::Id(name)) = t.last() else { return None };
            Some(match name.as_str() {
                "Allocator" => Ty::Alloc,
                "Self" => Ty::SelfTy,
                "c_int" => Ty::Prim("i32"),
                "c_uint" => Ty::Prim("u32"),
                "c_long" | "c_longlong" => Ty::Prim("i64"),
                "c_ulong" | "c_ulonglong" => Ty::Prim("u64"),
                "c_short" => Ty::Prim("i16"),
                "c_ushort" => Ty::Prim("u16"),
                "c_char" => Ty::Prim("u8"),
                n if owner == Some(n) => Ty::SelfTy,
                n => match prim(n) {
                    Some(p) => Ty::Prim(p),
                    None if ["type", "comptime_int", "comptime_float", "noreturn", "anyopaque", "anyerror"].contains(&n) => return None,
                    None => Ty::Named(n.to_string()),
                },
            })
        }
    }
}

// ---------- the shim, in Zig ----------

struct Zig {
    /// types with a deinit, and whether it takes an allocator
    deinit: std::collections::BTreeMap<String, bool>,
}

impl Zig {
    /// the Zig path of a named type, from the shim (m is the user's file)
    fn path(def: &TypeDef) -> String {
        let mut p = vec!["m".to_string()];
        p.extend(def.module.iter().cloned());
        p.push(def.name.clone());
        p.join(".")
    }
}

impl Lang for Zig {
    fn short(&self) -> &'static str {
        "zig"
    }

    fn name(&self) -> &'static str {
        "Zig"
    }

    fn by_value_moves(&self, ti: &TypeInfo) -> bool {
        // a type that frees what it holds: its value moves, so it's freed once
        ti.def.opaque
    }

    fn param(&self, g: &Gen, t: &Ty, a: &str) -> Option<ShimParam> {
        let mut p = ShimParam::default();
        match t {
            Ty::Alloc => p.arg = "alloc".into(),
            Ty::Prim(x) => {
                p.params.push(format!("{a}: {x}"));
                p.arg = a.to_string();
            }
            Ty::Str => {
                p.params.extend([format!("{a}: ?[*]const u8"), format!("{a}_n: usize")]);
                p.arg = format!("s({a}, {a}_n)");
            }
            Ty::Slice(e, mutable) => match &**e {
                Ty::Prim(x) => {
                    if *mutable {
                        p.params.extend([format!("{a}: ?[*]{x}"), format!("{a}_n: usize")]);
                        p.arg = format!("slm({x}, {a}, {a}_n)");
                    } else {
                        p.params.extend([format!("{a}: ?[*]const {x}"), format!("{a}_n: usize")]);
                        p.arg = format!("sl({x}, {a}, {a}_n)");
                    }
                }
                Ty::Str if !mutable => {
                    p.params.extend([format!("{a}: ?[*]const VoltStr"), format!("{a}_n: usize")]);
                    p.pre.extend([format!("const {a}_v = strs({a}, {a}_n);"), format!("defer alloc.free({a}_v);")]);
                    p.arg = format!("{a}_v");
                }
                _ => return None,
            },
            Ty::Opt(inner) => match &**inner {
                Ty::Prim(x) => {
                    p.params.extend([format!("{a}_has: bool"), format!("{a}: {x}")]);
                    p.arg = format!("if ({a}_has) {a} else null");
                }
                Ty::Str => {
                    p.params.extend([format!("{a}: ?[*]const u8"), format!("{a}_n: usize")]);
                    p.arg = format!("if ({a}) |{a}_q| {a}_q[0..{a}_n] else null");
                }
                _ => return None,
            },
            Ty::Named(_) | Ty::Ref(..) => {
                let (named, by_ref, mutable) = match t {
                    Ty::Ref(x, m) => (&**x, true, *m),
                    x => (x, false, false),
                };
                let ti = g.info(named)?;
                let (zp, mg) = (Self::path(&ti.def), Gen::mangle(&ti.def));
                match ti.kind {
                    Kind::Plain => {
                        p.params.push(format!("{a}: *V_{mg}"));
                        if mutable {
                            p.pre.push(format!("var {a}_v = from_{mg}({a}.*);"));
                            p.arg = format!("&{a}_v");
                            p.post.push(format!("{a}.* = to_{mg}({a}_v);"));
                        } else if by_ref {
                            p.pre.push(format!("const {a}_v = from_{mg}({a}.*);"));
                            p.arg = format!("&{a}_v");
                        } else {
                            p.arg = format!("from_{mg}({a}.*)");
                        }
                    }
                    Kind::Handle => {
                        p.params.push(format!("{a}: *anyopaque"));
                        let ptr = format!("@as(*{zp}, @ptrCast(@alignCast({a})))");
                        if by_ref {
                            p.arg = ptr;
                        } else if ti.def.opaque {
                            // moved: the value comes out of its box, which is freed
                            p.pre.extend([format!("const {a}_p: *{zp} = @ptrCast(@alignCast({a}));"), format!("const {a}_v = {a}_p.*;"), format!("alloc.destroy({a}_p);")]);
                            p.arg = format!("{a}_v");
                        } else {
                            p.arg = format!("{ptr}.*");
                        }
                    }
                    Kind::Enum => {
                        if mutable {
                            return None;
                        }
                        p.params.push(format!("{a}: i64"));
                        if by_ref {
                            p.pre.push(format!("const {a}_v: {zp} = @enumFromInt({a});"));
                            p.arg = format!("&{a}_v");
                        } else {
                            p.arg = format!("@as({zp}, @enumFromInt({a}))");
                        }
                    }
                }
            }
            _ => return None,
        }
        Some(p)
    }

    fn receiver(&self, _g: &Gen, ti: &TypeInfo, recv: Recv) -> Option<ShimParam> {
        let (zp, mg) = (Self::path(&ti.def), Gen::mangle(&ti.def));
        let mut p = ShimParam::default();
        match ti.kind {
            Kind::Plain => {
                p.params.push(format!("this: *V_{mg}"));
                match recv {
                    Recv::Mut => {
                        p.pre.push(format!("var this_v = from_{mg}(this.*);"));
                        p.post.push(format!("this.* = to_{mg}(this_v);"));
                    }
                    _ => p.pre.push(format!("const this_v = from_{mg}(this.*);")),
                }
                p.arg = "this_v".into();
            }
            Kind::Handle => {
                p.params.push("this: *anyopaque".into());
                if recv == Recv::Value && ti.def.opaque {
                    p.pre.extend([format!("const this_p: *{zp} = @ptrCast(@alignCast(this));"), "const this_v = this_p.*;".to_string(), "alloc.destroy(this_p);".to_string()]);
                    p.arg = "this_v".into();
                } else {
                    p.arg = format!("@as(*{zp}, @ptrCast(@alignCast(this)))");
                }
            }
            Kind::Enum => {
                if recv == Recv::Mut {
                    return None;
                }
                p.params.push("this: i64".into());
                p.pre.push(format!("const this_v: {zp} = @enumFromInt(this);"));
                p.arg = "this_v".into();
            }
        }
        Some(p)
    }

    fn out(&self, g: &Gen, t: &Ty, o: &str, owned: bool) -> Option<ShimOut> {
        let put = if owned { "put_owned" } else { "put_copy" };
        Some(match t {
            Ty::Prim(x) => ShimOut { params: vec![format!("{o}: *{x}")], store: format!("{o}.* = $v;") },
            Ty::Str => ShimOut { params: vec![format!("{o}: *?[*]u8"), format!("{o}_n: *usize")], store: format!("{put}(u8, $v, {o}, {o}_n);") },
            Ty::Slice(e, _) => match **e {
                Ty::Prim(x) => ShimOut { params: vec![format!("{o}: *?[*]{x}"), format!("{o}_n: *usize")], store: format!("{put}({x}, $v, {o}, {o}_n);") },
                _ => return None,
            },
            Ty::Named(_) => {
                let ti = g.info(t)?;
                let (zp, mg) = (Self::path(&ti.def), Gen::mangle(&ti.def));
                match ti.kind {
                    Kind::Plain => ShimOut { params: vec![format!("{o}: *V_{mg}")], store: format!("{o}.* = to_{mg}($v);") },
                    Kind::Handle => ShimOut { params: vec![format!("{o}: *?*anyopaque")], store: format!("{{ const {o}_p = alloc.create({zp}) catch @panic(\"out of memory\"); {o}_p.* = $v; {o}.* = {o}_p; }}") },
                    Kind::Enum => ShimOut { params: vec![format!("{o}: *i64")], store: format!("{o}.* = @as(i64, @intFromEnum($v));") },
                }
            }
            Ty::Opt(inner) => {
                let x = self.out(g, inner, o, owned)?;
                let mut params = vec![format!("{o}_has: *bool")];
                params.extend(x.params);
                ShimOut { params, store: format!("if ($v) |w| {{ {o}_has.* = true; {} }} else {{ {o}_has.* = false; }}", x.store.replace("$v", "w")) }
            }
            _ => return None,
        })
    }

    fn call(&self, _g: &Gen, module: &[String], s: &Sig, self_ty: Option<&TypeInfo>, recv: Option<&str>, args: &[String]) -> String {
        let args = args.join(", ");
        match (recv, self_ty) {
            (Some(r), _) => format!("{r}.{}({args})", s.name),
            (None, Some(ti)) => format!("{}.{}({args})", Self::path(&ti.def), s.name),
            (None, None) => {
                let mut p = vec!["m".to_string()];
                p.extend(module.iter().cloned());
                p.push(s.name.clone());
                format!("{}({args})", p.join("."))
            }
        }
    }

    fn function(&self, sym: &str, params: &[String], pre: &[String], call: &str, post: &[String], store: Option<&str>, res: bool) -> String {
        let mut ps = params.to_vec();
        if res {
            ps.extend(["e: *?[*]u8".to_string(), "e_n: *usize".to_string()]);
        }
        let mut body = String::new();
        for l in pre {
            let _ = writeln!(body, "    {l}");
        }
        let fail = "|err| {\n        put_copy(u8, @errorName(err), e, e_n);\n        return false;\n    }";
        match (store, res) {
            (Some(st), true) => {
                let _ = writeln!(body, "    const v = {call} catch {fail};");
                for l in post {
                    let _ = writeln!(body, "    {l}");
                }
                let _ = writeln!(body, "    {}\n    return true;", st.replace("$v", "v"));
            }
            (None, true) => {
                let _ = writeln!(body, "    {call} catch {fail};");
                for l in post {
                    let _ = writeln!(body, "    {l}");
                }
                body.push_str("    return true;\n");
            }
            (Some(st), false) => {
                let _ = writeln!(body, "    const v = {call};");
                for l in post {
                    let _ = writeln!(body, "    {l}");
                }
                let _ = writeln!(body, "    {}", st.replace("$v", "v"));
            }
            (None, false) => {
                let _ = writeln!(body, "    {call};");
                for l in post {
                    let _ = writeln!(body, "    {l}");
                }
            }
        }
        format!("export fn {sym}({}) {} {{\n{body}}}\n\n", ps.join(", "), if res { "bool" } else { "void" })
    }

    fn type_glue(&self, g: &Gen, ti: &TypeInfo) -> String {
        let (zp, mg) = (Self::path(&ti.def), Gen::mangle(&ti.def));
        let mut out = String::new();
        match ti.kind {
            Kind::Plain => {
                let (mut fields, mut from, mut to) = (String::new(), String::new(), String::new());
                for (f, _, t) in ti.def.fields.clone().unwrap_or_default() {
                    match t {
                        Some(Ty::Prim(x)) => {
                            let _ = writeln!(fields, "    {f}: {x},");
                            let _ = write!(from, ".{f} = v.{f}, ");
                            let _ = write!(to, ".{f} = v.{f}, ");
                        }
                        Some(Ty::Named(n)) => {
                            let o = &g.types[&n];
                            let omg = Gen::mangle(&o.def);
                            if o.kind == Kind::Enum {
                                let _ = writeln!(fields, "    {f}: i64,");
                                let _ = write!(from, ".{f} = @enumFromInt(v.{f}), ");
                                let _ = write!(to, ".{f} = @as(i64, @intFromEnum(v.{f})), ");
                            } else {
                                let _ = writeln!(fields, "    {f}: V_{omg},");
                                let _ = write!(from, ".{f} = from_{omg}(v.{f}), ");
                                let _ = write!(to, ".{f} = to_{omg}(v.{f}), ");
                            }
                        }
                        _ => {}
                    }
                }
                let _ = write!(out, "const V_{mg} = extern struct {{\n{fields}}};\nfn from_{mg}(v: V_{mg}) {zp} {{\n    return .{{ {from}}};\n}}\nfn to_{mg}(v: {zp}) V_{mg} {{\n    return .{{ {to}}};\n}}\n\n");
            }
            Kind::Handle => {
                let drop = g.sym(&[&mg, "drop"]);
                let deinit = match self.deinit.get(&ti.def.name) {
                    Some(true) => "p.deinit(alloc);\n    ",
                    Some(false) => "p.deinit();\n    ",
                    None => "",
                };
                let _ = writeln!(out, "export fn {drop}(h: *anyopaque) void {{\n    const p: *{zp} = @ptrCast(@alignCast(h));\n    {deinit}alloc.destroy(p);\n}}\n");
                if ti.def.clone {
                    let cl = g.sym(&[&mg, "clone"]);
                    let _ = writeln!(out, "export fn {cl}(h: *anyopaque) *anyopaque {{\n    const p: *{zp} = @ptrCast(@alignCast(h));\n    const q = alloc.create({zp}) catch @panic(\"out of memory\");\n    q.* = p.*;\n    return q;\n}}\n");
                }
            }
            Kind::Enum => {}
        }
        out
    }

    fn prelude(&self, g: &Gen) -> String {
        let free = |what: &str| format!("volt_zig_{}_free_{what}", g.alias);
        let mut s = String::from("// the glue between a Volt program and this file, written by bolt import (use zig)\nconst std = @import(\"std\");\nconst m = @import(\"user\");\nconst alloc = std.heap.c_allocator;\n\n");
        s.push_str("const VoltStr = extern struct { p: ?[*]const u8, n: usize };\nconst VoltOwnedStr = extern struct { p: ?[*]u8, n: usize };\n\n");
        s.push_str("fn s(p: ?[*]const u8, n: usize) []const u8 {\n    return if (p) |q| q[0..n] else \"\";\n}\n");
        s.push_str("fn sl(comptime T: type, p: ?[*]const T, n: usize) []const T {\n    return if (p) |q| q[0..n] else &[_]T{};\n}\n");
        s.push_str("fn slm(comptime T: type, p: ?[*]T, n: usize) []T {\n    return if (p) |q| q[0..n] else @as([*]T, undefined)[0..0];\n}\n");
        s.push_str("fn strs(p: ?[*]const VoltStr, n: usize) [][]const u8 {\n    const out = alloc.alloc([]const u8, n) catch @panic(\"out of memory\");\n    for (sl(VoltStr, p, n), 0..) |x, i| out[i] = s(x.p, x.n);\n    return out;\n}\n");
        s.push_str("// a slice made with alloc: handed over as it is\nfn put_owned(comptime T: type, v: []const T, p: *?[*]T, n: *usize) void {\n    p.* = @constCast(v.ptr);\n    n.* = v.len;\n}\n");
        s.push_str("// a slice someone else owns: a copy made with alloc\nfn put_copy(comptime T: type, v: []const T, p: *?[*]T, n: *usize) void {\n    const d = alloc.dupe(T, v) catch @panic(\"out of memory\");\n    p.* = d.ptr;\n    n.* = d.len;\n}\n\n");
        let _ = writeln!(s, "export fn {}(p: ?[*]u8, n: usize) void {{\n    if (p) |q| alloc.free(q[0..n]);\n}}\n", free("bytes"));
        for x in &g.vec_elems {
            let _ = writeln!(s, "export fn {}(p: ?[*]{x}, n: usize) void {{\n    if (p) |q| alloc.free(q[0..n]);\n}}\n", free(&format!("{x}s")));
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
    fn import_zig_types() {
        assert_eq!(ty("[]const u8"), Some(Ty::Str));
        assert_eq!(ty("[]u8"), Some(Ty::Slice(Box::new(Ty::Prim("u8")), true)));
        assert_eq!(ty("[]const f64"), Some(Ty::Slice(Box::new(Ty::Prim("f64")), false)));
        assert_eq!(ty("[]const []const u8"), Some(Ty::Slice(Box::new(Ty::Str), false)));
        assert_eq!(ty("?u32"), Some(Ty::Opt(Box::new(Ty::Prim("u32")))));
        assert_eq!(ty("!i64"), Some(Ty::Res(Box::new(Ty::Prim("i64")))));
        assert_eq!(ty("ParseError!i64"), Some(Ty::Res(Box::new(Ty::Prim("i64")))));
        assert_eq!(ty("std.mem.Allocator"), Some(Ty::Alloc));
        assert_eq!(ty("*const Shape"), Some(Ty::Ref(Box::new(Ty::SelfTy), false)));
        assert_eq!(ty("*Self"), Some(Ty::Ref(Box::new(Ty::SelfTy), true)));
        assert_eq!(ty("@This()"), Some(Ty::SelfTy));
        assert_eq!(ty("shapes.Point"), Some(Ty::Named("Point".into())));
        assert_eq!(ty("void"), Some(Ty::Unit));
        assert_eq!(ty("c_int"), Some(Ty::Prim("i32")));
        assert_eq!(ty("[4]u8"), None);
        assert_eq!(ty("type"), None);
    }

    #[test]
    fn import_zig_walk() {
        let src = "const std = @import(\"std\");\npub const Point = struct {\n    x: f64,\n    y: f64 = 0,\n    pub fn norm(self: Point) f64 { return self.x; }\n    pub fn scale(self: *Point, k: f64) void { self.x *= k; }\n};\npub const Color = enum(u8) { red, green = 5, blue, pub fn name(self: Color) []const u8 { return @tagName(self); } };\npub const util = struct { pub fn twice(x: i32) i32 { return x * 2; } };\npub fn add(a: i32, b: i32) i32 { return a + b; }\nfn hidden() void {}\npub const LIMIT = 10;\ntest \"x\" { }\n";
        let dir = std::env::temp_dir().join(format!("volt-zig-walk-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("m.zig");
        std::fs::write(&f, src).unwrap();
        let mut w = Walker::default();
        w.file(&f, &[]);
        let m = w.model();
        let _ = std::fs::remove_dir_all(&dir);
        let types: Vec<&str> = m.types.iter().map(|t| t.name.as_str()).collect();
        assert_eq!(types, ["Point", "Color"]);
        assert_eq!(m.types[1].variants, Some(vec![("red".into(), 0), ("green".into(), 5), ("blue".into(), 6)]));
        let fns: Vec<String> = m.fns.iter().map(|(p, s)| format!("{}{}", p.iter().map(|x| format!("{x}.")).collect::<String>(), s.name)).collect();
        assert_eq!(fns, ["util.twice", "add"]);
        assert_eq!(m.methods["Point"].iter().map(|s| (s.name.as_str(), s.recv)).collect::<Vec<_>>(), [("norm", Recv::Value), ("scale", Recv::Mut)]);
        assert_eq!(m.methods["Color"][0].ret, Some(Ty::Str));
        assert_eq!(m.consts, [(vec![], "LIMIT".to_string(), "i64".to_string(), "10".to_string())]);
    }

    #[test]
    fn import_zig_left_out() {
        let src = "pub const Flags = packed struct { a: bool = false };\npub const U = union { a: i32, b: f32 };\npub extern fn c_side(x: i32) i32;\npub fn ok() void {}\n";
        let dir = std::env::temp_dir().join(format!("volt-zig-left-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("m.zig");
        std::fs::write(&f, src).unwrap();
        let mut w = Walker::default();
        w.file(&f, &[]);
        let _ = std::fs::remove_dir_all(&dir);
        assert!(w.m.types.is_empty());
        assert_eq!(w.m.fns.len(), 1);
        assert_eq!(w.m.left_out, ["Flags (a packed struct)", "U (a union)", "c_side (a declaration without a body, defined elsewhere)"]);
    }
}
