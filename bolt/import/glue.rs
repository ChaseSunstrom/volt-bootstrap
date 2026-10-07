// The language-neutral half of an import: the model a language's parser fills (fns, types,
// methods, consts, as `Ty`s), how each type crosses between Volt and the shim (the C ABI), and
// the whole Volt side: extern declarations, wrapper functions, structs, handles, enums, helpers and
// namespaces. A language (rust.rs, zig.rs) supplies its parser and its shim's syntax: the `Lang`
// trait.
//
// The ABI, the same for every language (each line: Volt's extern parameters, in order):
//   number, bool         a: T                     (out: o: T*)
//   char                 a: u32                   (out: o: u32*)
//   text                 a: u8*, a_n: usize       (out: o: u8**, o_n: usize*, owned by the shim)
//   slice of numbers     a: T*, a_n: usize        (out: o: T**, o_n: usize*, owned by the shim)
//   slice of text        a: void* (str[..]'s items), a_n: usize (out: o: owned_str**, o_n: usize*)
//   T?                   a_has: bool, a: T; text: a null a  (out: o_has: bool*, then T's outs)
//   plain struct         a: T* (mirror layout)    (out: o: T*)
//   handle               a: void*                 (out: o: void**)
//   enum                 a: i64                   (out: o: i64*)
//   Result               the function returns bool (true: ok) and has e: u8**, e_n: usize* last
// Out parameters follow the parameters; owned buffers go back through the shim's free functions.
use super::volt_name;
use crate::foreign::Tok;
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write;

/// a type, as the importing language's parser maps it
#[derive(Clone, Debug, PartialEq)]
pub enum Ty {
    Unit,
    /// a number or bool, by its Volt name (the same as Rust's and Zig's)
    Prim(&'static str),
    /// Rust's char: u32 in Volt
    Char,
    /// text: str in, std::string out
    Str,
    /// Rust's String: str in (made into a String), std::string out
    String,
    /// elements, mutable: T[..] in, std::vec<T> out
    Slice(Box<Ty>, bool),
    /// Rust's Vec<T>: T[..] in (made into a Vec), std::vec<T> out
    Vec(Box<Ty>),
    Opt(Box<Ty>),
    Res(Box<Ty>),
    Named(String),
    /// a reference to a named type, mutable
    Ref(Box<Ty>, bool),
    SelfTy,
    /// a Zig std.mem.Allocator parameter: the shim passes one, the Volt function has none
    Alloc,
}

pub const PRIMS: &[&str] = &["i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "isize", "usize", "f32", "f64", "bool"];

pub fn prim(p: &str) -> Option<&'static str> {
    PRIMS.iter().find(|x| **x == p).copied()
}

/// a number literal's Volt text, and whether it's a float: -3, 0x10, 1.5 (which lexes as 1 . 5),
/// 2.0e3; None when the tokens are anything more
pub fn number(t: &[Tok]) -> Option<(String, bool)> {
    let (neg, rest) = match t {
        [Tok::P(m), rest @ ..] if m == "-" => ("-", rest),
        _ => ("", t),
    };
    match rest {
        [Tok::Num(n)] => {
            // a Rust type suffix (10u8, 0xffi32) isn't Volt's
            const SUFFIXES: &[&str] = &["usize", "isize", "u128", "i128", "u64", "i64", "u32", "i32", "u16", "i16", "u8", "i8", "f64", "f32"];
            let hex = n.starts_with("0x");
            let n = SUFFIXES.iter().find(|x| n.len() > x.len() && n.ends_with(*x) && !(hex && x.starts_with('f'))).map_or(n.as_str(), |x| &n[..n.len() - x.len()]);
            Some((format!("{neg}{n}"), false))
        }
        [Tok::Num(a), Tok::P(dot), Tok::Num(b)] if dot == "." && b.chars().next().is_some_and(|c| c.is_ascii_digit()) => {
            let b = b.trim_end_matches("f64").trim_end_matches("f32");
            Some((format!("{neg}{a}.{b}"), true))
        }
        _ => None,
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Recv {
    None,
    Ref,
    Mut,
    Value,
}

/// a function or method, its types mapped (None: one Volt can't name)
#[derive(Clone)]
pub struct Sig {
    pub name: String,
    pub recv: Recv,
    pub params: Vec<(String, Option<Ty>)>,
    pub ret: Option<Ty>,
    /// why it can't be called from Volt at all, when it can't
    pub skip: Option<&'static str>,
    /// its declaration in its own language, on one line (shown above the Volt fn: hover shows it)
    pub src: String,
}

#[derive(Clone)]
pub struct TypeDef {
    pub module: Vec<String>,
    pub name: String,
    pub generic: bool,
    /// a struct's fields (name, visible from outside, type), None for one without named fields
    pub fields: Option<Vec<(String, bool, Option<Ty>)>>,
    /// an enum's variants (name, value), None when one holds data
    pub variants: Option<Vec<(String, i128)>>,
    pub is_enum: bool,
    pub clone: bool,
    /// never by value, whatever its fields (Rust's #[non_exhaustive]; a Zig type with deinit)
    pub opaque: bool,
}

/// a file's (or crate's) public API
#[derive(Default)]
pub struct Model {
    pub fns: Vec<(Vec<String>, Sig)>,
    pub types: Vec<TypeDef>,
    /// module, name, Volt type, Volt literal
    pub consts: Vec<(Vec<String>, String, String, String)>,
    /// methods by type name
    pub methods: BTreeMap<String, Vec<Sig>>,
    pub left_out: Vec<String>,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Kind {
    /// a struct Volt holds by value (every field plain): copied over field by field
    Plain,
    /// a value the other side owns, held by pointer
    Handle,
    /// a fieldless enum
    Enum,
}

pub struct TypeInfo {
    pub def: TypeDef,
    pub kind: Kind,
}

/// a parameter's (or receiver's) shim side: its C parameters, statements before and after the call,
/// and the argument the call gets
#[derive(Default)]
pub struct ShimParam {
    pub params: Vec<String>,
    pub pre: Vec<String>,
    pub arg: String,
    pub post: Vec<String>,
}

/// a returned value's shim side: its out parameters and the statement storing `$v` in them
pub struct ShimOut {
    pub params: Vec<String>,
    pub store: String,
}

/// the shim's half, in its language
pub trait Lang {
    /// "rust", "zig": the shim namespace (rust_shim), the error set (rust_error) and symbols
    fn short(&self) -> &'static str;
    /// "Rust", "Zig": in messages
    fn name(&self) -> &'static str;
    /// whether passing this handle type by value moves its value into the call, leaving the Volt
    /// handle empty (Rust's always do; Zig's do when the type has a deinit), or copies it
    fn by_value_moves(&self, ti: &TypeInfo) -> bool;
    fn param(&self, g: &Gen, t: &Ty, a: &str) -> Option<ShimParam>;
    fn receiver(&self, g: &Gen, ti: &TypeInfo, recv: Recv) -> Option<ShimParam>;
    /// `owned`: the function was given an allocator, so slices it returns are the shim's to free
    fn out(&self, g: &Gen, t: &Ty, o: &str, owned: bool) -> Option<ShimOut>;
    /// the call expression: f(args), recv.f(args), T.f(args)
    fn call(&self, g: &Gen, module: &[String], s: &Sig, self_ty: Option<&TypeInfo>, recv: Option<&str>, args: &[String]) -> String;
    /// the exported function around a call; `store` stores `$v`, the call's value; `res`: the call
    /// returns an error or a value
    fn function(&self, sym: &str, params: &[String], pre: &[String], call: &str, post: &[String], store: Option<&str>, res: bool) -> String;
    /// a type's glue: a plain struct's mirror and conversions, a handle's drop (and clone), an
    /// enum's conversions
    fn type_glue(&self, g: &Gen, ti: &TypeInfo) -> String;
    /// what every shim has: its helpers and the functions freeing what Volt was given
    fn prelude(&self, g: &Gen) -> String;
    /// a shim whose functions are found while the program runs (not linked): the Volt source, in
    /// the shim namespace, of `fn load(slot: void**, name: str) -> void*`, which finds function
    /// `name` (once: slot keeps it)
    fn loader(&self, _g: &Gen) -> Option<String> {
        None
    }
}

/// the Volt side of one parameter
#[derive(Default)]
struct VoltParam {
    param: String,
    pre: Vec<String>,
    ext: Vec<String>,
    args: Vec<String>,
}

/// the Volt side of a returned value: extern out parameters, locals, out arguments, and the Volt
/// expression of the value
struct VoltOut {
    ext: Vec<String>,
    locals: Vec<String>,
    args: Vec<String>,
    value: String,
    ty: String,
}

pub struct Gen<'a> {
    pub m: &'a Model,
    pub alias: String,
    pub lang: &'a dyn Lang,
    pub types: BTreeMap<String, TypeInfo>,
    /// number types whose slices come back (a free function each), and whether text slices do
    pub vec_elems: BTreeSet<&'static str>,
    pub strs: bool,
    errors: bool,
    shim: String,
    ext: String,
    helpers: String,
    modules: BTreeMap<Vec<String>, String>,
    left_out: Vec<String>,
    /// the shim's symbols so far (overloads get one each), and the Volt signatures
    syms: BTreeSet<String>,
    sigs: BTreeSet<String>,
}

pub fn zero(p: &str) -> &'static str {
    match p {
        "bool" => "false",
        "f32" | "f64" => "0.0",
        _ => "0",
    }
}

impl<'a> Gen<'a> {
    pub fn new(m: &'a Model, alias: &str, lang: &'a dyn Lang) -> Gen<'a> {
        let mut types: BTreeMap<String, TypeInfo> = BTreeMap::new();
        let mut dup = BTreeSet::new();
        for d in &m.types {
            if d.generic {
                continue;
            }
            if types.contains_key(&d.name) {
                dup.insert(d.name.clone());
            }
            let kind = if d.is_enum && d.variants.is_some() { Kind::Enum } else { Kind::Handle };
            types.insert(d.name.clone(), TypeInfo { def: d.clone(), kind });
        }
        for n in dup {
            types.remove(&n); // two types of one name in different modules: neither is used
        }
        // plain structs: every field visible and plain, until nothing changes
        loop {
            let mut changed = false;
            let names: Vec<String> = types.keys().cloned().collect();
            for n in names {
                let ti = &types[&n];
                if ti.kind != Kind::Handle || ti.def.is_enum || ti.def.opaque {
                    continue;
                }
                let Some(fields) = &ti.def.fields else { continue };
                let plain = !fields.is_empty()
                    && fields.iter().all(|(_, public, t)| {
                        *public
                            && match t {
                                Some(Ty::Prim(_) | Ty::Char) => true,
                                Some(Ty::Named(x)) => types.get(x).is_some_and(|o| o.kind != Kind::Handle),
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
        Gen { m, alias: alias.to_string(), lang, types, vec_elems: BTreeSet::new(), strs: false, errors: false, shim: String::new(), ext: String::new(), helpers: String::new(), modules: BTreeMap::new(), left_out: Vec::new(), syms: BTreeSet::new(), sigs: BTreeSet::new() }
    }

    /// the Volt declaration of shim function sym (params: "name: type"): an extern "C" fn, or for
    /// a shim found while the program runs, a function calling the address load finds
    fn ext_fn(&self, sym: &str, params: &[String], ret: &str) -> String {
        if self.lang.loader(self).is_none() {
            return format!("    extern \"C\" fn {sym}({}) -> {ret};\n", params.join(", "));
        }
        let (names, types): (Vec<&str>, Vec<&str>) = params.iter().map(|p| p.split_once(": ").unwrap_or(("", p))).unzip();
        let call = format!("@cast<extern \"C\" fn({}) -> {ret}>(load(&p_{sym}, \"{sym}\"))({})", types.join(", "), names.join(", "));
        let body = if ret == "void" { format!("{call};") } else { format!("return {call};") };
        format!("    var p_{sym}: void* = null;\n    fn {sym}({}) -> {ret} {{\n        {body}\n    }}\n", params.join(", "))
    }

    /// the exported symbol for a path of names
    pub fn sym(&self, parts: &[&str]) -> String {
        format!("volt_{}_{}_{}", self.lang.short(), self.alias, parts.join("_"))
    }

    /// the Volt namespace of the glue's declarations, from anywhere in the import
    pub fn shim_ns(&self) -> String {
        format!("{}::{}_shim", self.alias, self.lang.short())
    }

    /// the Volt path of a named type, from anywhere in the import
    pub fn volt_path(&self, def: &TypeDef) -> String {
        let mut p = vec![self.alias.clone()];
        p.extend(def.module.iter().map(|m| volt_name(m)));
        p.push(def.name.clone());
        p.join("::")
    }

    /// a name for the glue's helpers of a type (a__b__T: `__` keeps module a_b's T apart)
    pub fn mangle(def: &TypeDef) -> String {
        let mut p = def.module.clone();
        p.push(def.name.clone());
        p.join("__")
    }

    /// a parameter's Volt name, kept apart from the glue's own locals (o, e, a0...)
    fn param_name(n: &str) -> String {
        let v = volt_name(n);
        let glue = matches!(v.as_str(), "o" | "o_n" | "o_has" | "e" | "e_n" | "a_this") || (v.len() > 1 && v.starts_with('a') && v[1..].chars().all(|c| c.is_ascii_digit()));
        if glue { format!("{v}_") } else { v }
    }

    /// Volt code that stops the program when handle `h` (an expression) is empty
    fn not_empty(&self, vp: &str, h: &str) -> String {
        let n = self.lang.name();
        format!("if ({h} == null) {{ @panic(\"{vp} is empty: {n} never made it, or it was given to {n} already\"); }}")
    }

    pub fn info(&self, t: &Ty) -> Option<&TypeInfo> {
        match t {
            Ty::Named(n) => self.types.get(n),
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
            Ty::Slice(x, m) => Ty::Slice(Box::new(self.resolve(*x, self_ty)), m),
            t => t,
        }
    }

    /// a parameter's Volt side (the i-th: its extern names are a{i}...)
    fn volt_param(&mut self, name: &str, t: &Ty, i: usize) -> Option<VoltParam> {
        let a = format!("a{i}");
        let vn = Self::param_name(name);
        let ns = self.shim_ns();
        let mut p = VoltParam::default();
        match t {
            Ty::Prim(x) => {
                p.param = format!("{vn}: {x}");
                p.ext.push(format!("{a}: {x}"));
                p.args.push(vn);
            }
            Ty::Char => {
                p.param = format!("{vn}: u32");
                p.ext.push(format!("{a}: u32"));
                p.args.push(vn);
            }
            Ty::Str | Ty::String => {
                p.param = format!("{vn}: str");
                p.ext.extend([format!("{a}: u8*"), format!("{a}_n: usize")]);
                p.args.extend([format!("@cast<u8*>({vn}.ptr)"), format!("{vn}.len")]);
            }
            Ty::Slice(e, _) | Ty::Vec(e) => match **e {
                Ty::Prim(x) => {
                    p.param = format!("{vn}: {x}[..]");
                    p.ext.extend([format!("{a}: {x}*"), format!("{a}_n: usize")]);
                    p.args.extend([format!("@cast<{x}*>({vn}.ptr)"), format!("{vn}.len")]);
                }
                Ty::Str | Ty::String => {
                    p.param = format!("{vn}: str[..]");
                    p.ext.extend([format!("{a}: void*"), format!("{a}_n: usize")]);
                    p.args.extend([format!("@cast<void*>({vn}.ptr)"), format!("{vn}.len")]);
                }
                _ => return None,
            },
            Ty::Opt(inner) => match &**inner {
                Ty::Prim(x) => {
                    p.param = format!("{vn}: {x}?");
                    p.ext.extend([format!("{a}_has: bool"), format!("{a}: {x}")]);
                    p.args.extend([format!("{vn} != null"), format!("{vn} ?? {}", zero(x))]);
                }
                Ty::Str | Ty::String => {
                    p.param = format!("{vn}: str?");
                    p.pre.extend([format!("var {a}: u8* = null;"), format!("var {a}_n: usize = 0;"), format!("if ({vn}) {{ {a} = @cast<u8*>({vn}.ptr); {a}_n = {vn}.len; }}")]);
                    p.ext.extend([format!("{a}: u8*"), format!("{a}_n: usize")]);
                    p.args.extend([a.clone(), format!("{a}_n")]);
                }
                _ => return None,
            },
            Ty::Named(_) | Ty::Ref(..) => {
                let (named, by_ref, mutable) = match t {
                    Ty::Ref(x, m) => (&**x, true, *m),
                    x => (x, false, false),
                };
                let ti = self.info(named)?;
                let (vp, mg, kind, moves) = (self.volt_path(&ti.def), Self::mangle(&ti.def), ti.kind, self.lang.by_value_moves(ti));
                match kind {
                    Kind::Plain => {
                        if mutable {
                            p.param = format!("{vn}: {vp}&");
                            p.args.push(vn);
                        } else {
                            p.param = format!("{vn}: {vp}");
                            p.args.push(format!("&{vn}"));
                        }
                        p.ext.push(format!("{a}: {vp}*"));
                    }
                    Kind::Handle => {
                        p.ext.push(format!("{a}: void*"));
                        p.pre.push(self.not_empty(&vp, &format!("{vn}.h")));
                        if by_ref || !moves {
                            p.param = format!("{vn}: {vp}&");
                            p.args.push(format!("{vn}.h"));
                        } else {
                            // moved: the value goes into the call, the handle is left empty
                            p.param = format!("var {vn}: {vp}");
                            p.pre.extend([format!("val {a} = {vn}.h;"), format!("{vn}.h = null;")]);
                            p.args.push(a.clone());
                        }
                    }
                    Kind::Enum => {
                        if mutable {
                            return None;
                        }
                        p.param = format!("{vn}: {vp}");
                        p.ext.push(format!("{a}: i64"));
                        p.args.push(format!("{ns}::tag_{mg}({vn})"));
                    }
                }
            }
            _ => return None,
        }
        Some(p)
    }

    /// a returned value's Volt side (its out parameters are named o...)
    fn volt_out(&mut self, t: &Ty, o: &str) -> Option<VoltOut> {
        let ns = self.shim_ns();
        Some(match t {
            Ty::Prim(x) => VoltOut { ext: vec![format!("{o}: {x}*")], locals: vec![format!("var {o}: {x} = {};", zero(x))], args: vec![format!("&{o}")], value: o.to_string(), ty: x.to_string() },
            Ty::Char => VoltOut { ext: vec![format!("{o}: u32*")], locals: vec![format!("var {o}: u32 = 0;")], args: vec![format!("&{o}")], value: o.to_string(), ty: "u32".into() },
            Ty::Str | Ty::String => VoltOut {
                ext: vec![format!("{o}: u8**"), format!("{o}_n: usize*")],
                locals: vec![format!("var {o}: u8* = null;"), format!("var {o}_n: usize = 0;")],
                args: vec![format!("&{o}"), format!("&{o}_n")],
                value: format!("{ns}::take({o}, {o}_n)"),
                ty: "std::string".into(),
            },
            Ty::Slice(e, _) | Ty::Vec(e) => match **e {
                Ty::Prim(x) => {
                    self.vec_elems.insert(x);
                    VoltOut {
                        ext: vec![format!("{o}: {x}**"), format!("{o}_n: usize*")],
                        locals: vec![format!("var {o}: {x}* = null;"), format!("var {o}_n: usize = 0;")],
                        args: vec![format!("&{o}"), format!("&{o}_n")],
                        value: format!("{ns}::take_{x}s({o}, {o}_n)"),
                        ty: format!("std::vec<{x}>"),
                    }
                }
                Ty::Str | Ty::String => {
                    self.strs = true;
                    VoltOut {
                        ext: vec![format!("{o}: {ns}::owned_str**"), format!("{o}_n: usize*")],
                        locals: vec![format!("var {o}: {ns}::owned_str* = null;"), format!("var {o}_n: usize = 0;")],
                        args: vec![format!("&{o}"), format!("&{o}_n")],
                        value: format!("{ns}::take_strs({o}, {o}_n)"),
                        ty: "std::vec<std::string>".into(),
                    }
                }
                _ => return None,
            },
            Ty::Named(_) | Ty::Ref(..) => {
                let named = match t {
                    Ty::Ref(x, _) => &**x,
                    x => x,
                };
                let ti = self.info(named)?;
                let (vp, mg) = (self.volt_path(&ti.def), Self::mangle(&ti.def));
                match ti.kind {
                    Kind::Plain => VoltOut { ext: vec![format!("{o}: {vp}*")], locals: vec![format!("var {o}: {vp} = {{}};")], args: vec![format!("&{o}")], value: o.to_string(), ty: vp },
                    Kind::Handle => VoltOut { ext: vec![format!("{o}: void**")], locals: vec![format!("var {o}: void* = null;")], args: vec![format!("&{o}")], value: format!("{ns}::own_{mg}({o})"), ty: vp },
                    Kind::Enum => VoltOut { ext: vec![format!("{o}: i64*")], locals: vec![format!("var {o}: i64 = 0;")], args: vec![format!("&{o}")], value: format!("{ns}::of_{mg}({o})"), ty: vp },
                }
            }
            Ty::Opt(inner) => {
                if matches!(**inner, Ty::Opt(_) | Ty::Res(_) | Ty::Unit) {
                    return None;
                }
                let x = self.volt_out(inner, o)?;
                let mut ext = vec![format!("{o}_has: bool*")];
                ext.extend(x.ext);
                let mut locals = vec![format!("var {o}_has = false;")];
                locals.extend(x.locals);
                let mut args = vec![format!("&{o}_has")];
                args.extend(x.args);
                VoltOut { ext, locals, args, value: x.value, ty: format!("{}?", x.ty) }
            }
            _ => return None,
        })
    }

    /// a fn or method: its shim function and Volt extern declaration (added to the glue) and its
    /// Volt function (returned)
    fn function(&mut self, module: &[String], s: &Sig, self_ty: Option<&str>) -> Result<String, String> {
        let what = match self_ty {
            Some(t) => format!("{t}::{}", s.name),
            None => s.name.clone(),
        };
        if let Some(why) = s.skip {
            return Err(format!("{what} ({why})"));
        }
        let lang = self.lang;
        if self_ty.is_some_and(|t| !self.types.contains_key(t)) {
            return Err(format!("{what} (its type isn't one Volt can name)"));
        }
        let mut path: Vec<&str> = module.iter().map(String::as_str).collect();
        if let Some(t) = self_ty {
            path.push(t);
        }
        path.push(&s.name);
        // an overload gets a symbol of its own
        let mut sym = self.sym(&path);
        let base = sym.clone();
        for n in 2.. {
            if !self.syms.contains(&sym) {
                break;
            }
            sym = format!("{base}_{n}");
        }
        let ns = self.shim_ns();

        // the receiver
        let mut recv: Option<(ShimParam, VoltParam)> = None;
        if let (Some(t), true) = (self_ty, s.recv != Recv::None) {
            let ti = &self.types[t];
            let (vp, mg, kind) = (self.volt_path(&ti.def), Self::mangle(&ti.def), ti.kind);
            let shim = lang.receiver(self, ti, s.recv).ok_or(format!("{what} (its self parameter)"))?;
            let mut v = VoltParam::default();
            match kind {
                Kind::Plain => {
                    v.param = format!("this: {vp}&");
                    v.ext.push(format!("a_this: {vp}*"));
                    v.args.push("this".into());
                }
                Kind::Handle => {
                    v.ext.push("a_this: void*".into());
                    v.pre.push(self.not_empty(&vp, "this.h"));
                    if s.recv == Recv::Value && lang.by_value_moves(ti) {
                        v.param = format!("var this: {vp}");
                        v.pre.extend(["val a_this = this.h;".to_string(), "this.h = null;".to_string()]);
                        v.args.push("a_this".into());
                    } else {
                        v.param = format!("this: {vp}&");
                        v.args.push("this.h".into());
                    }
                }
                Kind::Enum => {
                    v.param = format!("this: {vp}&");
                    v.ext.push("a_this: i64".into());
                    v.args.push(format!("{ns}::tag_{mg}(*this)"));
                }
            }
            recv = Some((shim, v));
        }

        // the parameters (an allocator is the shim's alone)
        let mut params: Vec<(ShimParam, Option<VoltParam>)> = Vec::new();
        let mut owned = false;
        for (i, (n, t)) in s.params.iter().enumerate() {
            let t = t.clone().map(|t| self.resolve(t, self_ty)).ok_or(format!("{what} (parameter {n}'s type)"))?;
            let a = format!("a{i}");
            let shim = lang.param(self, &t, &a).ok_or(format!("{what} (parameter {n}'s type)"))?;
            if t == Ty::Alloc {
                owned = true;
                params.push((shim, None));
                continue;
            }
            let v = self.volt_param(n, &t, i).ok_or(format!("{what} (parameter {n}'s type)"))?;
            params.push((shim, Some(v)));
        }
        // two overloads Volt can't tell apart (their parameters are the same Volt types)
        let types: Vec<&str> = params.iter().filter_map(|p| p.1.as_ref()).map(|v| v.param.split_once(": ").map_or(v.param.as_str(), |x| x.1)).collect();
        // (in its module: two modules' fns of one name are different fns)
        let key = format!("{}::{what} {} ({})", module.join("::"), self_ty.is_some() && s.recv == Recv::None, types.join(", "));
        if self.sigs.contains(&key) {
            return Err(format!("{what} (an overload Volt sees as the same as another)"));
        }
        let ret = s.ret.clone().map(|t| self.resolve(t, self_ty)).ok_or(format!("{what} (its return type)"))?;
        let (res, val_ty) = match ret {
            Ty::Res(x) => (true, *x),
            x => (false, x),
        };
        let (shim_out, volt_out) = if val_ty == Ty::Unit {
            (None, None)
        } else {
            let so = lang.out(self, &val_ty, "o", owned).ok_or(format!("{what} (its return type)"))?;
            let vo = self.volt_out(&val_ty, "o").ok_or(format!("{what} (its return type)"))?;
            (Some(so), Some(vo))
        };
        if res {
            self.errors = true;
        }
        self.sigs.insert(key);
        self.syms.insert(sym.clone());

        // the shim
        let shims: Vec<&ShimParam> = recv.iter().map(|r| &r.0).chain(params.iter().map(|p| &p.0)).collect();
        let mut sp: Vec<String> = shims.iter().flat_map(|p| p.params.clone()).collect();
        if let Some(o) = &shim_out {
            sp.extend(o.params.clone());
        }
        let pre: Vec<String> = shims.iter().flat_map(|p| p.pre.clone()).collect();
        let post: Vec<String> = shims.iter().flat_map(|p| p.post.clone()).collect();
        let args: Vec<String> = params.iter().map(|p| p.0.arg.clone()).collect();
        let call = lang.call(self, module, s, self_ty.map(|t| &self.types[t]), recv.as_ref().map(|r| r.0.arg.as_str()), &args);
        let text = lang.function(&sym, &sp, &pre, &call, &post, shim_out.as_ref().map(|o| o.store.as_str()), res);
        self.shim.push_str(&text);

        // the Volt extern declaration
        let volts: Vec<&VoltParam> = recv.iter().map(|r| &r.1).chain(params.iter().filter_map(|p| p.1.as_ref())).collect();
        let mut ve: Vec<String> = volts.iter().flat_map(|p| p.ext.clone()).collect();
        if let Some(o) = &volt_out {
            ve.extend(o.ext.clone());
        }
        if res {
            ve.extend(["e: u8**".to_string(), "e_n: usize*".to_string()]);
        }
        let decl = self.ext_fn(&sym, &ve, if res { "bool" } else { "void" });
        self.ext.push_str(&decl);

        // the Volt function
        let vt = volt_out.as_ref().map_or("void".to_string(), |o| o.ty.clone());
        let err = format!("{}::{}_error", self.alias, lang.short());
        let ret_ty = if res { format!("{err}!{}", if vt.ends_with('?') { format!("({vt})") } else { vt.clone() }) } else { vt.clone() };
        let vps: Vec<String> = volts.iter().map(|p| p.param.clone()).collect();
        let mut vargs: Vec<String> = volts.iter().flat_map(|p| p.args.clone()).collect();
        let mut lines: Vec<String> = volts.iter().flat_map(|p| p.pre.clone()).collect();
        if let Some(o) = &volt_out {
            lines.extend(o.locals.clone());
            vargs.extend(o.args.clone());
        }
        if res {
            lines.extend(["var e: u8* = null;".to_string(), "var e_n: usize = 0;".to_string()]);
            vargs.extend(["&e".to_string(), "&e_n".to_string()]);
        }
        let ext_call = format!("{ns}::{sym}({})", vargs.join(", "));
        let give = |o: &VoltOut| -> Vec<String> {
            if o.ty.ends_with('?') {
                vec![format!("if (o_has) {{ return {}; }}", o.value), "return null;".into()]
            } else {
                vec![format!("return {};", o.value)]
            }
        };
        if res {
            lines.push(format!("if ({ext_call}) {{"));
            match &volt_out {
                Some(o) => lines.extend(give(o).into_iter().map(|l| format!("    {l}"))),
                None => lines.push("    return;".into()),
            }
            lines.push("}".into());
            lines.push(format!("return {err}::ERROR({ns}::take(e, e_n));"));
        } else {
            lines.push(format!("{ext_call};"));
            if let Some(o) = &volt_out {
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
        let mut f = String::new();
        if !s.src.is_empty() {
            f.push_str(&format!("// {}: {}\n", self.lang.name(), s.src));
        }
        f.push_str(&format!("{head} {{\n"));
        for l in lines {
            f.push_str(&format!("    {l}\n"));
        }
        f.push_str("}\n");
        Ok(f)
    }

    /// a type's Volt declaration, its Volt helpers and its shim glue
    fn type_decl(&mut self, name: &str) -> String {
        let ti = &self.types[name];
        let (vp, mg, kind, def) = (self.volt_path(&ti.def), Self::mangle(&ti.def), ti.kind, ti.def.clone());
        let glue = self.lang.type_glue(self, ti);
        self.shim.push_str(&glue);
        let ns = self.shim_ns();
        let mut v = String::new();
        match kind {
            Kind::Plain => {
                let mut fields = String::new();
                for (f, _, t) in def.fields.clone().unwrap_or_default() {
                    let fv = volt_name(&f);
                    match t {
                        Some(Ty::Prim(x)) => {
                            let _ = writeln!(fields, "    {fv}: {x} = {};", zero(x));
                        }
                        Some(Ty::Char) => {
                            let _ = writeln!(fields, "    {fv}: u32 = 0;");
                        }
                        Some(Ty::Named(n)) => {
                            let o = &self.types[&n];
                            let ovp = self.volt_path(&o.def);
                            if o.kind == Kind::Enum {
                                let first = o.def.variants.as_ref().and_then(|vs| vs.first()).map_or(String::new(), |x| volt_name(&x.0));
                                let _ = writeln!(fields, "    {fv}: {ovp} = {ovp}::{first};");
                            } else {
                                let _ = writeln!(fields, "    {fv}: {ovp} = {{}};");
                            }
                        }
                        _ => {}
                    }
                }
                let _ = write!(v, "struct {} {{\n{fields}}}\n", def.name);
            }
            Kind::Handle => {
                let drop = self.sym(&[&mg, "drop"]);
                let n = self.lang.name();
                let _ = write!(v, "// a {n} {} (owned: deleting it frees it)\nstruct {} {{\n    h: void* = null;\n}}\n\nattach fn delete(this: {vp}&) -> void {{\n    if (this.h != null) {{\n        {ns}::{drop}(this.h);\n        this.h = null;\n    }}\n}}\n", def.name, def.name);
                let decl = self.ext_fn(&drop, &["h: void*".to_string()], "void");
                self.ext.push_str(&decl);
                if def.clone {
                    let cl = self.sym(&[&mg, "clone"]);
                    let _ = write!(v, "\nattach fn copy(this: {vp}&) -> {vp} {{\n    if (this.h == null) {{\n        return {{}};\n    }}\n    return {{ h: {ns}::{cl}(this.h) }};\n}}\n");
                    let decl = self.ext_fn(&cl, &["h: void*".to_string()], "void*");
                    self.ext.push_str(&decl);
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
                for (n, x) in &vs {
                    let _ = writeln!(tag, "            .{} => {{ return {x}; }},", volt_name(n));
                    let _ = writeln!(of, "        if (x == {x}) {{\n            return {vp}::{};\n        }}", volt_name(n));
                }
                tag.push_str("        }\n    }\n");
                let first = vs.first().map_or(String::new(), |x| volt_name(&x.0));
                let _ = write!(of, "        return {vp}::{first};\n    }}\n");
                self.helpers.push_str(&tag);
                self.helpers.push_str(&of);
            }
        }
        v
    }

    /// the shim's source and the Volt source
    pub fn write(mut self, what: &str) -> (String, String) {
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
        for (module, name, ty, lit) in self.m.consts.clone() {
            self.modules.entry(module).or_default().push_str(&format!("\nval {}: {ty} = {lit};\n", volt_name(&name)));
        }
        for t in &self.m.types {
            if t.generic {
                self.left_out.push(format!("{} (it's generic)", t.name));
            }
        }
        self.left_out.extend(self.m.left_out.iter().cloned());

        // the shim: its prelude (helpers, free functions), then the types' and functions' glue
        let mut shim = self.lang.prelude(&self);
        shim.push_str(&self.shim);

        // the Volt helpers that take what the shim hands over (and free it through the shim)
        let free = |what: &str| format!("volt_{}_{}_free_{what}", self.lang.short(), self.alias);
        let mut ext = self.ext_fn(&free("bytes"), &["p: u8*".to_string(), "n: usize".to_string()], "void");
        let mut helpers = format!("    // the shim's bytes as a std::string; the shim's copy is freed\n    fn take(p: u8*, n: usize) -> std::string {{\n        if (n == 0) {{\n            return std::string::from(\"\");\n        }}\n        val s = std::string::from(@cast<str>(@slice(p, n)));\n        {}(p, n);\n        return s;\n    }}\n", free("bytes"));
        for x in &self.vec_elems {
            let f = free(&format!("{x}s"));
            ext.push_str(&self.ext_fn(&f, &["p: ".to_string() + x + "*", "n: usize".to_string()], "void"));
            let _ = write!(helpers, "    fn take_{x}s(p: {x}*, n: usize) -> std::vec<{x}> {{\n        var out: std::vec<{x}> = {{}};\n        if (n == 0) {{\n            return out;\n        }}\n        for (x) in @slice(p, n) {{\n            out.push(x) catch @panic(\"out of memory\");\n        }}\n        {f}(p, n);\n        return out;\n    }}\n");
        }
        if self.strs {
            let f = free("strs");
            ext.push_str(&self.ext_fn(&f, &["p: owned_str*".to_string(), "n: usize".to_string()], "void"));
            let _ = write!(helpers, "    struct owned_str {{\n        p: u8*;\n        n: usize;\n    }}\n\n    fn take_strs(p: owned_str*, n: usize) -> std::vec<std::string> {{\n        var out: std::vec<std::string> = {{}};\n        if (n == 0) {{\n            return out;\n        }}\n        for (x) in @slice(p, n) {{\n            out.push(std::string::from(@cast<str>(@slice(x.p, x.n)))) catch @panic(\"out of memory\");\n        }}\n        {f}(p, n);\n        return out;\n    }}\n");
        }
        helpers.push_str(&self.helpers);
        if let Some(l) = self.lang.loader(&self) {
            helpers.push_str(&l);
        }
        let short = self.lang.short();
        let mut volt = format!("// use {short} {{ ... }} as {}: {what}'s public API, called through its shim (written by bolt import)\n\nnamespace {short}_shim {{\n{ext}{}\n{helpers}}}\n", self.alias, self.ext);
        if self.errors {
            let _ = write!(volt, "\n// a {} error, as its message\nerror {short}_error {{\n    ERROR: std::string,\n}}\n", self.lang.name());
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn import_number_literals() {
        let n = |s: &str| number(&crate::foreign::lex(s));
        assert_eq!(n("10"), Some(("10".into(), false)));
        assert_eq!(n("-3"), Some(("-3".into(), false)));
        assert_eq!(n("10u8"), Some(("10".into(), false)));
        assert_eq!(n("0xffi32"), Some(("0xff".into(), false)));
        assert_eq!(n("1.5"), Some(("1.5".into(), true)));
        assert_eq!(n("-2.25f64"), Some(("-2.25".into(), true)));
        assert_eq!(n("1 + 2"), None);
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
