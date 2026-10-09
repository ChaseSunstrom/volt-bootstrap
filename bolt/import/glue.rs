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
//   slice of named types a: void* (T[..]'s items: mirrors, handles, enums), a_n: usize (out: o: T**)
//   &mut of a number     a: T* (out: none)
//   tuple                (out: each element's outs, o0..., o1...)
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
    /// a Zig comptime parameter (by name; an instance's, by its argument as Zig spells it): the
    /// shim passes it, the Volt function has none (it's the generic's parameter)
    Comptime(String),
    /// a generic function's type parameter (each instance has a type in its place)
    Generic(String),
    /// a closure: its parameters, result, how it's passed (in) or held (out), and whether it can
    /// only be called once
    Fn(Vec<Ty>, Box<Ty>, FnPass, bool),
    /// a value of one of the crate's traits (by name), passed as a closure is: lent (&dyn T, &impl
    /// T, &S of an S: T), by value (impl T, S: T) or boxed (Box<dyn T>)
    Dyn(String, FnPass),
    /// text a trait's method lends (a str into the other side's memory, never copied)
    StrRef,
    /// a Result whose error is one of the crate's enums (by name): a Volt error set of its
    /// variants
    Fails(Box<Ty>, String),
    /// an async function's result (a future of it): a Volt async fn
    Future(Box<Ty>),
    /// several results (Go's): a Volt tuple, its elements named when they have names
    Tuple(Vec<(String, Ty)>),
    /// a fixed number of elements (Go's [N]T): T[..] in (the shim checks the count), std::vec<T> out
    Array(Box<Ty>, usize),
    /// a generic type's instance in a generic declaration (Stack<T>), by the generic type's name
    Inst(String, Vec<Ty>),
}

/// an enum's variant, with its fields' names (a tuple variant's are 0, 1..) and types
#[derive(Clone, Debug)]
pub struct Variant {
    pub name: String,
    pub fields: Vec<(String, Option<Ty>)>,
    /// its fields have names (V { a, b }), or it's a tuple variant (V(a, b), V())
    pub named: bool,
    pub tuple: bool,
}

/// how a closure crosses: by value (impl Fn, a generic F), lent (&dyn Fn, &mut dyn FnMut), or boxed
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum FnPass {
    Value,
    Ref,
    MutRef,
    Boxed,
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
    /// self: Box<Self>, Rc<Self>, Arc<Self> (that pointer's path): by value, through it
    Own(&'static str),
    /// self: &Rc<Self>, &Arc<Self>: lent, the value in that pointer for the call
    Shared(&'static str),
    /// self: Pin<&mut Self> (true) or Pin<&Self>
    Pin(bool),
}

impl Recv {
    /// the value goes into the call (a handle is left empty)
    pub fn moves(self) -> bool {
        matches!(self, Recv::Value | Recv::Own(_))
    }
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
    /// a generic one's type parameters: Volt gets a generic declaration, and a function per
    /// instance a program uses (made with `call` set)
    pub generics: Vec<String>,
    /// an instance's callee in its own language (largest::<i32>), in place of name
    pub call: Option<String>,
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
    /// a generic one's type parameters (Volt gets a type per instance a program names)
    pub params: Vec<String>,
    /// an instance's name in its own language (Stack<i32>), in place of name
    pub rust_name: Option<String>,
}

/// a trait: Volt gets a trait of its own, a handle for the language's objects of it (dyn_T)
/// attaching it, and its types attaching it; Volt's types attaching it pass where it's wanted
#[derive(Clone)]
pub struct TraitDef {
    pub module: Vec<String>,
    pub name: String,
    /// its methods, each with whether it has a body there (a Volt type may leave those out)
    pub methods: Vec<(Sig, bool)>,
    /// why Volt can't use it, when it can't
    pub skip: Option<String>,
}

/// a file's (or crate's) public API
#[derive(Default, Clone)]
pub struct Model {
    pub fns: Vec<(Vec<String>, Sig)>,
    pub types: Vec<TypeDef>,
    /// module, name, Volt type, Volt literal
    pub consts: Vec<(Vec<String>, String, String, String)>,
    /// methods by type name
    pub methods: BTreeMap<String, Vec<Sig>>,
    pub traits: Vec<TraitDef>,
    /// (type, trait): the types implementing the traits
    pub impls: Vec<(String, String)>,
    /// each enum's variants, and whether more may come (#[non_exhaustive], hidden ones)
    pub enums: BTreeMap<String, (Vec<Variant>, bool)>,
    pub left_out: Vec<String>,
    /// type aliases (module, name, the type it names): Volt's `type name = T;`
    pub aliases: Vec<(Vec<String>, String, Ty)>,
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
    /// its shim functions catch the language's panics: each returns a status (0 ok, 1 an error
    /// it returned, 2 a panic) and the error's or the panic's text in e, e_n; each Volt function
    /// then has a try_ form that returns the panic as an error (PANIC) instead of stopping
    fn catches(&self) -> bool {
        false
    }
    /// its shim hands the Volt functions it calls (closures, a Volt type's trait methods) the
    /// import's types too (a plain struct's copy, a handle the function owns, an enum) and slices
    /// of numbers, and takes them back as results; else numbers, bools, chars and text alone
    fn cb_types(&self) -> bool {
        false
    }
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
    /// a function whose error is one of the crate's enums: as `function` with res, its error's
    /// variant stored by err_store (`$e` the error)
    #[allow(clippy::too_many_arguments)]
    fn function_err(&self, _sym: &str, _params: &[String], _pre: &[String], _call: &str, _post: &[String], _store: Option<&str>, _err_store: &str) -> Option<String> {
        None
    }
    /// an async function's start: SYM(params.., h) makes its future, which runs nothing yet; the
    /// prelude's poll(h, outs, e, e_n) runs it until it's done (3: not yet; else a status, its
    /// value stored through outs, the out parameters' addresses in order), future_drop(h) frees
    /// it. res: its result is a Result (err_store: an enum error's, else its text)
    #[allow(clippy::too_many_arguments)]
    fn async_function(&self, _sym: &str, _params: &[String], _pre: &[String], _call: &str, _post: &[String], _outs: &[String], _store: Option<&str>, _res: bool, _err_store: Option<&str>) -> Option<String> {
        None
    }
    /// an enum error's shim side: its out parameters (k, the variant, then each variant's fields
    /// as `out` gives them, x{variant}_{field}...) and the statement storing `$e` in them
    fn err_out(&self, _g: &Gen, _e: &str) -> Option<ShimOut> {
        None
    }
    /// a closure handed to Volt: the shim functions calling it (SYM_call(h, args.., out)) and
    /// freeing it (SYM_drop(h))
    fn fn_glue(&self, _g: &Gen, _sym: &str, _ps: &[Ty], _r: &Ty, _once: bool) -> Option<String> {
        None
    }
    /// a trait's glue: a type implementing it by calling a table of Volt functions (the methods
    /// in ms, over a Volt value; see Gen::trait_decl)
    fn trait_glue(&self, _g: &Gen, _t: &TraitDef, _ms: &[(Sig, bool)]) -> Option<String> {
        None
    }
    /// the function Volt gives a String result through: put(o, p, n) stores text p, n where o (a
    /// String of the shim's language) points
    fn put_glue(&self, _sym: &str) -> Option<String> {
        None
    }
    /// the function a Volt closure's slice result goes through, an element at a time:
    /// push(o, the element as a parameter of type e is passed) appends it to the slice o (a
    /// handle of the shim's) says; for a catching shim it also takes e and e_n (out) and gives
    /// status 2 and the text there when it panics
    fn push_glue(&self, _g: &Gen, _sym: &str, _e: &Ty) -> Option<String> {
        None
    }
    /// a shim whose functions are found while the program runs (not linked): the Volt source, in
    /// the shim namespace, of `fn load(slot: void**, name: str) -> void*`, which finds function
    /// `name` (once: slot keeps it)
    fn loader(&self, _g: &Gen) -> Option<String> {
        None
    }
    /// Volt source the shim calls by its C name (in the shim namespace)
    fn volt_glue(&self, _g: &Gen) -> String {
        String::new()
    }
}

/// the Volt side of one parameter
#[derive(Default)]
struct VoltParam {
    param: String,
    /// a template parameter the Volt function takes for it (T0: a trait)
    generic: Option<String>,
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
    /// named types whose slices or vecs come back (a take helper each)
    pub elem_types: BTreeSet<String>,
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
    /// closure signatures Volt gives (a trampoline each: tramp_K) and takes back (a handle type
    /// each: fn_K), by their Volt fn type
    tramps: Vec<String>,
    fn_handles: Vec<String>,
    /// each fn_K's signature, in the same order, and its call's Volt parameter types and result
    fn_tys: Vec<(Vec<Ty>, Ty, Vec<String>, String)>,
    /// the traits by name, those Volt got (a declaration and its glue), and the one whose attach
    /// block function() is writing methods for
    pub traits: BTreeMap<String, TraitDef>,
    made_traits: BTreeSet<String>,
    block: Option<String>,
    put_string: bool,
    /// the push functions made (by element type)
    pushes: BTreeMap<String, String>,
    /// the enums Volt gets as error sets, and their sets' names (the enum's own, or NAME_error
    /// when it's a value too)
    err_sets: BTreeMap<String, String>,
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
        let mut traits: BTreeMap<String, TraitDef> = BTreeMap::new();
        let mut dup = BTreeSet::new();
        for t in &m.traits {
            if traits.insert(t.name.clone(), t.clone()).is_some() {
                dup.insert(t.name.clone());
            }
        }
        for n in dup {
            traits.remove(&n);
        }
        // an enum only ever an error is an error set of its name (not a type too)
        let mut err_sets = BTreeMap::new();
        for e in fails_of(m) {
            if !m.enums.contains_key(&e) || !types.contains_key(&e) {
                continue;
            }
            if value_use(m, &e) {
                err_sets.insert(e.clone(), format!("{e}_error"));
            } else {
                types.remove(&e);
                err_sets.insert(e.clone(), e.clone());
            }
        }
        Gen { m, alias: alias.to_string(), lang, types, vec_elems: BTreeSet::new(), elem_types: BTreeSet::new(), strs: false, errors: false, shim: String::new(), ext: String::new(), helpers: String::new(), modules: BTreeMap::new(), left_out: Vec::new(), syms: BTreeSet::new(), sigs: BTreeSet::new(), tramps: Vec::new(), fn_handles: Vec::new(), fn_tys: Vec::new(), traits, made_traits: BTreeSet::new(), block: None, put_string: false, pushes: BTreeMap::new(), err_sets }
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
        let glue = matches!(v.as_str(), "o" | "o_n" | "o_has" | "e" | "e_n" | "a_this" | "this") || (v.len() > 1 && (v.starts_with('a') || v.starts_with('o')) && v[1..].chars().all(|c| c.is_ascii_digit()));
        if glue { format!("{v}_") } else { v }
    }

    /// Volt code that stops the program when handle `h` (an expression) is empty
    fn not_empty(&self, vp: &str, h: &str) -> String {
        let n = self.lang.name();
        format!("if ({h} == null) {{ @panic(\"{vp} is empty: {n} never made it, or it was given to {n} already\"); }}")
    }

    /// Volt code that stops the program when handle `x` is lent (a move would free what the other
    /// side owns)
    fn not_lent(&self, vp: &str, x: &str) -> String {
        format!("if ({x}.lent) {{ @panic(\"{vp} is lent by {}: it can't be given away\"); }}", self.lang.name())
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
            Ty::Array(x, n) => Ty::Array(Box::new(self.resolve(*x, self_ty)), n),
            Ty::Tuple(es) => Ty::Tuple(es.into_iter().map(|(n, t)| (n, self.resolve(t, self_ty))).collect()),
            t => t,
        }
    }

    /// a slice element that's one of the import's types (or a reference to one): its info
    pub fn elem_info(&self, e: &Ty) -> Option<&TypeInfo> {
        match e {
            Ty::Ref(x, _) => self.info(x),
            x => self.info(x),
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
            Ty::Fn(ps, r, pass, _) => {
                // a Volt fn value: a trampoline that calls it, and the value as its data: lent for
                // the call (&dyn Fn), or moved to the heap for the other side to keep (impl Fn,
                // Box<dyn Fn>), which drops it with drop_tramp_K
                // (a closure taking the other side's closures: their handle types, made first)
                for p in ps {
                    if let Ty::Fn(fps, fr, _, once) = p {
                        self.fn_handle(fps, fr, *once)?;
                    }
                }
                let k = self.tramp(ps, r)?;
                let ns = self.shim_ns();
                p.param = format!("{vn}: {}", self.fn_volt_ty(ps, r)?);
                p.ext.extend([format!("{a}: void*"), format!("{a}_env: void*")]);
                p.args.push(format!("@cast<void*>({ns}::tramp_{k})"));
                if matches!(pass, FnPass::Value | FnPass::Boxed) {
                    p.pre.push(format!("val {a}_env = {ns}::give_tramp_{k}(move {vn});"));
                    p.ext.push(format!("{a}_drop: void*"));
                    p.args.extend([format!("{a}_env"), format!("@cast<void*>({ns}::drop_tramp_{k})")]);
                } else {
                    p.args.push(format!("@cast<void*>(&{vn})"));
                }
            }
            // a Volt value of a type attaching the trait (T{i}): the value and the table of its
            // methods; lent for the call, or moved to the heap for the other side to keep (the
            // table's drop frees it)
            Ty::Dyn(tr, pass) => {
                if !self.made_traits.contains(tr) {
                    return None;
                }
                let td = &self.traits[tr];
                let (vt, mg) = (self.trait_path(td), Self::trait_mangle(td));
                let tp = format!("T{i}");
                p.generic = Some(format!("{tp}: {vt}"));
                if matches!(pass, FnPass::Ref | FnPass::MutRef) {
                    p.param = format!("{vn}: {tp}&");
                    p.pre.push(format!("var {a}_t = {ns}::table_{mg}<{tp}>(false);"));
                    p.args.push(format!("@cast<void*>(&*{vn})"));
                } else if self.lang.cb_types() {
                    // the other side's own value of it (dyn_T): passed as it is (a null table)
                    p.param = format!("{vn}: {tp}");
                    p.pre.extend([
                        format!("var {a}_t = {ns}::table_{mg}<{tp}>(true);"),
                        format!("var {a}_tp: {ns}::vt_{mg}* = &{a}_t;"),
                        format!("var {a}: void* = null;"),
                        format!("comptime if (@has_method({tp}, \"foreign_value\")) {{\n        {a} = {vn}.foreign_value();\n        {a}_tp = null;\n    }} else {{\n        {a} = {ns}::give_{mg}<{tp}>(move {vn});\n    }}"),
                    ]);
                    p.args.extend([a.clone(), format!("{a}_tp")]);
                } else {
                    p.param = format!("{vn}: {tp}");
                    p.pre.extend([format!("var {a}_t = {ns}::table_{mg}<{tp}>(true);"), format!("val {a} = {ns}::give_{mg}<{tp}>(move {vn});")]);
                    p.args.push(a.clone());
                }
                if p.args.len() == 1 {
                    p.args.push(format!("&{a}_t"));
                }
                p.ext.extend([format!("{a}: void*"), format!("{a}_t: {ns}::vt_{mg}*")]);
            }
            // &T of a number in a generic's instance: lent in Volt, its value to the shim
            Ty::Ref(x, false) if matches!(**x, Ty::Prim(_)) => {
                let Ty::Prim(x) = **x else { return None };
                p.param = format!("{vn}: {x}&");
                p.ext.push(format!("{a}: {x}"));
                p.args.push(format!("*{vn}"));
            }
            // &mut of a number: Volt's, which the call may change
            Ty::Ref(x, true) if matches!(**x, Ty::Prim(_)) => {
                let Ty::Prim(x) = **x else { return None };
                p.param = format!("{vn}: {x}&");
                p.ext.push(format!("{a}: {x}*"));
                p.args.push(vn);
            }
            // the import's types, in Volt's memory: plain structs' mirrors, handles, enums
            Ty::Slice(e, _) | Ty::Vec(e) | Ty::Array(e, _) if self.elem_info(e).is_some() => {
                let vp = self.volt_path(&self.elem_info(e)?.def);
                p.param = format!("{vn}: {vp}[..]");
                p.ext.extend([format!("{a}: void*"), format!("{a}_n: usize")]);
                p.args.extend([format!("@cast<void*>({vn}.ptr)"), format!("{vn}.len")]);
            }
            Ty::Str | Ty::String => {
                p.param = format!("{vn}: str");
                p.ext.extend([format!("{a}: u8*"), format!("{a}_n: usize")]);
                p.args.extend([format!("@cast<u8*>({vn}.ptr)"), format!("{vn}.len")]);
            }
            Ty::Slice(e, _) | Ty::Vec(e) | Ty::Array(e, _) => match **e {
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
                // lists of numbers (a generic's T = std::vec<isize>): each as a str, its pointer and
                // length, which the other side reads as a slice of Volt's list
                Ty::Vec(ref x) if self.lang.cb_types() && matches!(**x, Ty::Prim(_)) => {
                    let Ty::Prim(x) = **x else { return None };
                    p.param = format!("{vn}: std::vec<{x}>[..]");
                    p.pre.push(format!("var {a}_l: std::vec<str> = {{}};"));
                    p.pre.push(format!("for (x&) in {vn} {{\n        {a}_l.push(@cast<str>(@slice(@cast<u8*>(x.items().ptr), x.len))) catch @panic(\"out of memory\");\n    }}"));
                    p.ext.extend([format!("{a}: void*"), format!("{a}_n: usize")]);
                    p.args.extend([format!("@cast<void*>({a}_l.items().ptr)"), format!("{a}_l.len")]);
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
                            // moved: the value goes into the call, the handle is left empty (a lent
                            // one isn't Volt's to give)
                            p.param = format!("var {vn}: {vp}");
                            p.pre.push(self.not_lent(&vp, &vn));
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
            // a Rust closure: a handle (the value is returned, so its type gives the literal's)
            Ty::Fn(ps, r, _, once) => {
                let k = self.fn_handle(ps, r, *once)?;
                VoltOut { ext: vec![format!("{o}: void**")], locals: vec![format!("var {o}: void* = null;")], args: vec![format!("&{o}")], value: format!("{{ h: {o} }}"), ty: format!("{ns}::fn_{k}") }
            }
            // the other side's object of a trait: its handle
            Ty::Dyn(tr, FnPass::Value | FnPass::Boxed) => return self.volt_out(&Ty::Named(format!("dyn_{tr}")), o),
            Ty::StrRef => VoltOut {
                ext: vec![format!("{o}: u8**"), format!("{o}_n: usize*")],
                locals: vec![format!("var {o}: u8* = null;"), format!("var {o}_n: usize = 0;")],
                args: vec![format!("&{o}"), format!("&{o}_n")],
                value: format!("@cast<str>(@slice({o}, {o}_n))"),
                ty: "str".into(),
            },
            Ty::Str | Ty::String => VoltOut {
                ext: vec![format!("{o}: u8**"), format!("{o}_n: usize*")],
                locals: vec![format!("var {o}: u8* = null;"), format!("var {o}_n: usize = 0;")],
                args: vec![format!("&{o}"), format!("&{o}_n")],
                value: format!("{ns}::take({o}, {o}_n)"),
                ty: "std::string".into(),
            },
            Ty::Slice(e, _) | Ty::Vec(e) | Ty::Array(e, _) => match **e {
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
                // the other side's values: handles (lent from a slice, owned from a Vec), plain
                // structs and enums copied
                Ty::Named(_) | Ty::Ref(..) => {
                    let ti = self.elem_info(e)?;
                    let (vp, mg, kind, name) = (self.volt_path(&ti.def), Self::mangle(&ti.def), ti.kind, ti.def.name.clone());
                    self.elem_types.insert(name);
                    let (pt, extra) = match kind {
                        Kind::Handle => ("void*".to_string(), format!(", {}", matches!(t, Ty::Slice(..)))),
                        Kind::Plain => (vp.clone(), String::new()),
                        Kind::Enum => {
                            self.vec_elems.insert("i64");
                            ("i64".to_string(), String::new())
                        }
                    };
                    VoltOut {
                        ext: vec![format!("{o}: {pt}**"), format!("{o}_n: usize*")],
                        locals: vec![format!("var {o}: {pt}* = null;"), format!("var {o}_n: usize = 0;")],
                        args: vec![format!("&{o}"), format!("&{o}_n")],
                        value: format!("{ns}::take_{mg}s({o}, {o}_n{extra})"),
                        ty: format!("std::vec<{vp}>"),
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
                let (named, lent) = match t {
                    Ty::Ref(x, m) => (&**x, *m || self.info(x).is_some_and(|ti| !ti.def.clone)),
                    x => (x, false),
                };
                let ti = self.info(named)?;
                let (vp, mg) = (self.volt_path(&ti.def), Self::mangle(&ti.def));
                match ti.kind {
                    Kind::Plain => VoltOut { ext: vec![format!("{o}: {vp}*")], locals: vec![format!("var {o}: {vp} = {{}};")], args: vec![format!("&{o}")], value: o.to_string(), ty: vp },
                    // a reference into the other side's value (a &mut, or a & of what can't be
                    // cloned): a lent handle, never freed by Volt
                    Kind::Handle if lent => VoltOut { ext: vec![format!("{o}: void**")], locals: vec![format!("var {o}: void* = null;")], args: vec![format!("&{o}")], value: format!("{ns}::lend_{mg}({o})"), ty: vp },
                    Kind::Handle => VoltOut { ext: vec![format!("{o}: void**")], locals: vec![format!("var {o}: void* = null;")], args: vec![format!("&{o}")], value: format!("{ns}::own_{mg}({o})"), ty: vp },
                    Kind::Enum => VoltOut { ext: vec![format!("{o}: i64*")], locals: vec![format!("var {o}: i64 = 0;")], args: vec![format!("&{o}")], value: format!("{ns}::of_{mg}({o})"), ty: vp },
                }
            }
            // several results: each element's outs (o0..., o1...), the value a tuple of them
            Ty::Tuple(es) => {
                let mut t = VoltOut { ext: Vec::new(), locals: Vec::new(), args: Vec::new(), value: String::new(), ty: String::new() };
                let (mut vals, mut tys) = (Vec::new(), Vec::new());
                for (i, (n, et)) in es.iter().enumerate() {
                    let x = self.volt_out(et, &format!("{o}{i}"))?;
                    // (an optional's value needs its has check: not an expression)
                    if x.ty.ends_with('?') {
                        return None;
                    }
                    t.ext.extend(x.ext);
                    t.locals.extend(x.locals);
                    t.args.extend(x.args);
                    vals.push(x.value);
                    tys.push(if n.is_empty() || n == "_" { x.ty } else { format!("{}: {}", volt_name(n), x.ty) });
                }
                t.value = format!("({})", vals.join(", "));
                t.ty = format!("({})", tys.join(", "));
                t
            }
            Ty::Opt(inner) => {
                if matches!(**inner, Ty::Opt(_) | Ty::Res(_) | Ty::Unit | Ty::Tuple(_)) {
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
        let block = self.block.clone();
        let what = match (self_ty, &block) {
            (Some(t), Some(tr)) => format!("{t}'s {tr}::{}", s.name),
            (Some(t), None) => format!("{t}::{}", s.name),
            (None, _) => s.name.clone(),
        };
        if let Some(why) = s.skip {
            return Err(format!("{what} ({why})"));
        }
        if !s.generics.is_empty() {
            if block.is_some() {
                return Err(format!("{what} (it's generic)"));
            }
            return self.generic(module, s, self_ty, &what);
        }
        if block.is_some() && !matches!(s.recv, Recv::Ref | Recv::Mut) {
            return Err(format!("{what} (it takes no &self or &mut self)"));
        }
        let lang = self.lang;
        if self_ty.is_some_and(|t| !self.types.contains_key(t)) {
            return Err(format!("{what} (its type isn't one Volt can name)"));
        }
        let mut path: Vec<&str> = module.iter().map(String::as_str).collect();
        if let Some(t) = self_ty {
            path.push(t);
        }
        if let Some(tr) = &block {
            path.push(tr);
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
                    if s.recv.moves() && lang.by_value_moves(ti) {
                        v.param = format!("var this: {vp}");
                        v.pre.push(self.not_lent(&vp, "this"));
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
            if matches!(t, Ty::Alloc | Ty::Comptime(_)) {
                owned |= t == Ty::Alloc;
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
        let mut ret = s.ret.clone().map(|t| self.resolve(t, self_ty)).ok_or(format!("{what} (its return type)"))?;
        // an async fn: a Volt async fn polling its future
        let asynk = matches!(ret, Ty::Future(_));
        if let Ty::Future(x) = ret {
            if block.is_some() || !lang.catches() {
                return Err(format!("{what} (it's async)"));
            }
            ret = *x;
        }
        // a trait's method lends its text, as Volt's trait says (str)
        if block.is_some() && ret == Ty::Str {
            ret = Ty::StrRef;
        }
        let (res, val_ty, fails) = match ret {
            Ty::Res(x) => (true, *x, None),
            Ty::Fails(x, e) if self.err_sets.contains_key(&e) => (true, *x, Some(e)),
            Ty::Fails(x, _) => (true, *x, None),
            x => (false, x, None),
        };
        // an enum error: its variant and fields come back in outs of their own
        let fail_outs = match &fails {
            Some(e) => Some((lang.err_out(self, e).ok_or(format!("{what} (its error type)"))?, self.err_volt(e).ok_or(format!("{what} (its error type)"))?)),
            None => None,
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
        let sp_in = sp.clone();
        if let Some(o) = &shim_out {
            sp.extend(o.params.clone());
        }
        let pre: Vec<String> = shims.iter().flat_map(|p| p.pre.clone()).collect();
        let post: Vec<String> = shims.iter().flat_map(|p| p.post.clone()).collect();
        let args: Vec<String> = params.iter().map(|p| p.0.arg.clone()).collect();
        let call = lang.call(self, module, s, self_ty.map(|t| &self.types[t]), recv.as_ref().map(|r| r.0.arg.as_str()), &args);
        let text = match &fail_outs {
            _ if asynk => {
                let mut outs: Vec<String> = shim_out.iter().flat_map(|o| o.params.clone()).collect();
                if let Some((so, _)) = &fail_outs {
                    outs.extend(so.params.clone());
                }
                lang.async_function(&sym, &sp_in, &pre, &call, &post, &outs, shim_out.as_ref().map(|o| o.store.as_str()), res, fail_outs.as_ref().map(|(so, _)| so.store.as_str())).ok_or(format!("{what} (it's async)"))?
            }
            Some((so, _)) => {
                sp.extend(so.params.clone());
                lang.function_err(&sym, &sp, &pre, &call, &post, shim_out.as_ref().map(|o| o.store.as_str()), &so.store).ok_or(format!("{what} (its error type)"))?
            }
            None => lang.function(&sym, &sp, &pre, &call, &post, shim_out.as_ref().map(|o| o.store.as_str()), res),
        };
        self.shim.push_str(&text);

        // the Volt extern declaration
        let volts: Vec<&VoltParam> = recv.iter().map(|r| &r.1).chain(params.iter().filter_map(|p| p.1.as_ref())).collect();
        let mut ve: Vec<String> = volts.iter().flat_map(|p| p.ext.clone()).collect();
        if let Some(o) = &volt_out {
            ve.extend(o.ext.clone());
        }
        if let Some((_, eo)) = &fail_outs {
            ve.extend(eo.ext.clone());
        }
        let catches = lang.catches();
        if asynk {
            // its start: the inputs, and where its future goes
            ve = volts.iter().flat_map(|p| p.ext.clone()).collect();
            ve.push("h: void**".into());
        } else if res || catches {
            ve.extend(["e: u8**".to_string(), "e_n: usize*".to_string()]);
        }
        let decl = self.ext_fn(&sym, &ve, if asynk { "void" } else if catches { "u8" } else if res { "bool" } else { "void" });
        self.ext.push_str(&decl);

        // the Volt function
        let vt = volt_out.as_ref().map_or("void".to_string(), |o| o.ty.clone());
        let err = format!("{}::{}_error", self.alias, lang.short());
        // the error set its errors are from (an enum error's own)
        let set = fails.as_ref().map_or(err.clone(), |e| self.err_set_path(e));
        let ret_ty = if res { format!("{set}!{}", if vt.ends_with('?') { format!("({vt})") } else { vt.clone() }) } else { vt.clone() };
        let vps: Vec<String> = volts.iter().map(|p| p.param.clone()).collect();
        let mut vargs: Vec<String> = volts.iter().flat_map(|p| p.args.clone()).collect();
        let vargs_in = vargs.clone();
        let mut lines: Vec<String> = volts.iter().flat_map(|p| p.pre.clone()).collect();
        if let Some(o) = &volt_out {
            lines.extend(o.locals.clone());
            vargs.extend(o.args.clone());
        }
        if let Some((_, eo)) = &fail_outs {
            lines.extend(eo.locals.clone());
            vargs.extend(eo.args.clone());
        }
        if res || catches {
            lines.extend(["var e: u8* = null;".to_string(), "var e_n: usize = 0;".to_string()]);
            vargs.extend(["&e".to_string(), "&e_n".to_string()]);
        }
        let ext_call = format!("{ns}::{sym}({})", vargs.join(", "));
        // the try_ form's lines, until they part
        let mut try_lines = lines.clone();
        let give = |o: &VoltOut| -> Vec<String> {
            if o.ty.ends_with('?') {
                vec![format!("if (o_has) {{ return {}; }}", o.value), "return null;".into()]
            } else {
                vec![format!("return {};", o.value)]
            }
        };
        if catches {
            // the plain form stops at a panic; the try_ form gives it back as PANIC (and the
            // shim's panic hook keeps quiet about it)
            self.errors = true;
            let quiet = self.sym(&["quiet"]);
            if asynk {
                // the future made, freed when the frame goes, polled until it's done (suspending
                // while it isn't), its value stored through the outs' addresses
                let mut out_args: Vec<String> = volt_out.iter().flat_map(|o| o.args.clone()).collect();
                if let Some((_, eo)) = &fail_outs {
                    out_args.extend(eo.args.clone());
                }
                let outs = if out_args.is_empty() { "null".to_string() } else { "&outs[0]".to_string() };
                let mut start_args = vargs_in.clone();
                start_args.push("&h".to_string());
                let mut start = vec!["var h: void* = null;".to_string(), format!("{ns}::{sym}({});", start_args.join(", ")), format!("defer {ns}::{}(h);", self.sym(&["future_drop"]))];
                if !out_args.is_empty() {
                    let casts: Vec<String> = out_args.iter().map(|a| format!("@cast<void*>({a})")).collect();
                    start.push(format!("val outs: void*[{}] = {{ {} }};", out_args.len(), casts.join(", ")));
                }
                start.push("var st: u8 = 3;".into());
                let poll = format!("{ns}::{}(h, {outs}, &e, &e_n)", self.sym(&["poll"]));
                lines.extend(start.clone());
                lines.push(format!("while (st == 3) {{\n        st = {poll};\n        if (st == 3) {{\n            suspend;\n        }}\n    }}"));
                try_lines.extend(start);
                try_lines.push(format!("while (st == 3) {{\n        val quiet = {ns}::{quiet}(true);\n        st = {poll};\n        {ns}::{quiet}(quiet);\n        if (st == 3) {{\n            suspend;\n        }}\n    }}"));
            } else {
                lines.push(format!("val st = {ext_call};"));
                try_lines.push(format!("val quiet = {ns}::{quiet}(true);"));
                try_lines.push(format!("val st = {ext_call};"));
                try_lines.push(format!("{ns}::{quiet}(quiet);"));
            }
            lines.push(format!("if (st == 2) {{\n        {ns}::panicked(e, e_n);\n    }}"));
            try_lines.push(format!("if (st == 2) {{\n        return {err}::PANIC({ns}::take(e, e_n));\n    }}"));
            for ls in [&mut lines, &mut try_lines] {
                match &fail_outs {
                    Some((_, eo)) => ls.push(format!("if (st == 1) {{\n{}    }}", eo.value)),
                    None if res => ls.push(format!("if (st == 1) {{\n        return {err}::ERROR({ns}::take(e, e_n));\n    }}")),
                    None => {}
                }
                match &volt_out {
                    Some(o) => ls.extend(give(o)),
                    None if res => ls.push("return;".into()),
                    None => {}
                }
            }
        } else if res {
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
            // a method in an attach block: this has the block's type
            (Some(_), _) if block.is_some() => {
                let mut ps = vec!["this".to_string()];
                ps.extend(vps.into_iter().skip(1));
                format!("fn {}({}) -> {ret_ty}", volt_name(&s.name), ps.join(", "))
            }
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
        let tps: Vec<String> = volts.iter().filter_map(|p| p.generic.clone()).collect();
        let mut write_fn = |head: &str, lines: &[String], note: &str| {
            if !f.is_empty() {
                f.push('\n');
            }
            if !s.src.is_empty() {
                f.push_str(&format!("// {}: {}{note}\n", self.lang.name(), s.src));
            }
            if !tps.is_empty() {
                f.push_str(&format!("<{}>\n", tps.join(", ")));
            }
            f.push_str(&format!("{head} {{\n"));
            for l in lines {
                f.push_str(&format!("    {l}\n"));
            }
            f.push_str("}\n");
        };
        let head = if asynk { format!("async {head}") } else { head };
        write_fn(&head, &lines, "");
        // try_NAME: a panic as an error (not in an attach block: a trait says its fns)
        if catches && block.is_none() {
            let vt_err = if vt.ends_with('?') { format!("({vt})") } else { vt.clone() };
            let named = head.replacen(&format!("fn {}(", volt_name(&s.name)), &format!("fn try_{}(", s.name), 1);
            // an enum error's try_ form gives its variants or PANIC: whichever comes (!T)
            let try_set = if fails.is_some() { String::new() } else { err.clone() };
            let try_head = format!("{}-> {try_set}!{vt_err}", named.strip_suffix(&format!("-> {ret_ty}")).unwrap_or(&named));
            write_fn(&try_head, &try_lines, &format!(" (try_{}: a panic is {err}::PANIC)", s.name));
        }
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
                let _ = write!(v, "// a {n} {} (owned: deleting it frees it; lent: a reference into {n}'s value, never freed here)\nstruct {} {{\n    h: void* = null;\n    lent: bool = false;\n}}\n\nattach fn delete(this: {vp}&) -> void {{\n    if (this.h != null && !this.lent) {{\n        {ns}::{drop}(this.h);\n    }}\n    this.h = null;\n}}\n", def.name, def.name);
                let decl = self.ext_fn(&drop, &["h: void*".to_string()], "void");
                self.ext.push_str(&decl);
                if def.clone {
                    let cl = self.sym(&[&mg, "clone"]);
                    let _ = write!(v, "\nattach fn copy(this: {vp}&) -> {vp} {{\n    if (this.h == null) {{\n        return {{}};\n    }}\n    return {{ h: {ns}::{cl}(this.h) }};\n}}\n");
                    let decl = self.ext_fn(&cl, &["h: void*".to_string()], "void*");
                    self.ext.push_str(&decl);
                }
                let _ = write!(self.helpers, "    fn own_{mg}(h: void*) -> {vp} {{\n        return {{ h: h }};\n    }}\n\n    fn lend_{mg}(h: void*) -> {vp} {{\n        return {{ h: h, lent: true }};\n    }}\n");
                // the other side's values of one of its traits: passed where it takes one as they are
                if self.lang.cb_types() && def.name.starts_with("dyn_") {
                    let _ = write!(v, "\n// {n}'s own value, where {n} takes a {}\nattach fn foreign_value(this: {vp}&) -> void* {{\n    return this.h;\n}}\n", &def.name["dyn_".len()..]);
                }
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

    /// the shim function Volt gives a String result through (put(o, p, n): o points at the
    /// String), made the first time one is wanted
    fn put_sym(&mut self) -> Option<String> {
        let put = self.sym(&["put_string"]);
        if !self.put_string {
            let glue = self.lang.put_glue(&put)?;
            self.shim.push_str(&glue);
            let decl = self.ext_fn(&put, &["o: void*".to_string(), "p: u8*".to_string(), "n: usize".to_string()], "void");
            self.ext.push_str(&decl);
            self.put_string = true;
        }
        Some(put)
    }

    /// an enum error's Volt error set, from anywhere in the import
    fn err_set_path(&self, e: &str) -> String {
        let module = self.m.types.iter().find(|t| t.name == e).map_or(Vec::new(), |t| t.module.clone());
        let mut p = vec![self.alias.clone()];
        p.extend(module.iter().map(|m| volt_name(m)));
        p.push(self.err_sets[e].clone());
        p.join("::")
    }

    /// a variant field's Volt type in an error set (None: the variant carries the error's text)
    fn err_field(t: &Option<Ty>) -> Option<String> {
        Some(match t.as_ref()? {
            Ty::Prim(x) => x.to_string(),
            Ty::Char => "u32".into(),
            Ty::Str | Ty::String => "std::string".into(),
            _ => return None,
        })
    }

    /// an enum error's Volt side: the outs (k, then each variant's fields: x{v}_{f}, or x{v} and
    /// x{v}_n for a variant carried as text), and in `value`, the lines returning its variant
    fn err_volt(&self, e: &str) -> Option<VoltOut> {
        let (vs, open) = self.m.enums.get(e)?;
        let ns = self.shim_ns();
        let set = self.err_set_path(e);
        let mut o = VoltOut { ext: vec!["k: u32*".into()], locals: vec!["var k: u32 = 0;".into()], args: vec!["&k".into()], value: String::new(), ty: set.clone() };
        for (vi, v) in vs.iter().enumerate() {
            let mut payload = Vec::new();
            if v.fields.iter().all(|(_, t)| Self::err_field(t).is_some()) {
                for (fi, (_, t)) in v.fields.iter().enumerate() {
                    let x = format!("x{vi}_{fi}");
                    match t.as_ref()? {
                        Ty::Str | Ty::String => {
                            o.ext.extend([format!("{x}: u8**"), format!("{x}_n: usize*")]);
                            o.locals.extend([format!("var {x}: u8* = null;"), format!("var {x}_n: usize = 0;")]);
                            o.args.extend([format!("&{x}"), format!("&{x}_n")]);
                            payload.push(format!("{ns}::take({x}, {x}_n)"));
                        }
                        t => {
                            let vt = Self::err_field(&Some(t.clone()))?;
                            let init = if let Ty::Prim(p) = t { zero(p) } else { "0" };
                            o.ext.push(format!("{x}: {vt}*"));
                            o.locals.push(format!("var {x}: {vt} = {init};"));
                            o.args.push(format!("&{x}"));
                            payload.push(x);
                        }
                    }
                }
            } else {
                let x = format!("x{vi}");
                o.ext.extend([format!("{x}: u8**"), format!("{x}_n: usize*")]);
                o.locals.extend([format!("var {x}: u8* = null;"), format!("var {x}_n: usize = 0;")]);
                o.args.extend([format!("&{x}"), format!("&{x}_n")]);
                payload.push(format!("{ns}::take({x}, {x}_n)"));
            }
            let val = match payload.len() {
                0 => format!("{set}::{}", volt_name(&v.name)),
                1 => format!("{set}::{}({})", volt_name(&v.name), payload[0]),
                _ => format!("{set}::{}(({}))", volt_name(&v.name), payload.join(", ")),
            };
            let _ = writeln!(o.value, "        if (k == {vi}) {{\n            return {val};\n        }}");
        }
        // a variant this build of the crate doesn't show: its text
        if *open {
            let _ = writeln!(o.value, "        return {set}::Other({ns}::take(e, e_n));");
        } else {
            let _ = writeln!(o.value, "        @panic(\"{e}: a variant Volt doesn't know\");");
        }
        Some(o)
    }

    /// an enum error's Volt error set: its variants, with their fields
    fn err_decl(&self, e: &str) -> Option<String> {
        let (vs, open) = self.m.enums.get(e)?;
        let mut d = format!("// {}'s {e}, as an error\nerror {} {{\n", self.lang.name(), self.err_sets[e]);
        for v in vs {
            let fs: Option<Vec<String>> = v.fields.iter().map(|(_, t)| Self::err_field(t)).collect();
            let payload = match fs {
                Some(fs) if fs.is_empty() => String::new(),
                Some(fs) if fs.len() == 1 => format!(": {}", fs[0]),
                Some(fs) => format!(": ({})", fs.join(", ")),
                None => ": std::string".into(),
            };
            let _ = writeln!(d, "    {}{payload},", volt_name(&v.name));
        }
        if *open {
            d.push_str("    // a variant this build of the crate doesn't show, as its text\n    Other: std::string,\n");
        }
        d.push_str("}\n");
        Some(d)
    }

    /// a trait's Volt path, from anywhere in the import
    pub fn trait_path(&self, t: &TraitDef) -> String {
        let mut p = vec![self.alias.clone()];
        p.extend(t.module.iter().map(|m| volt_name(m)));
        p.push(t.name.clone());
        p.join("::")
    }

    /// a name for the glue's helpers of a trait
    pub fn trait_mangle(t: &TraitDef) -> String {
        let mut p = t.module.clone();
        p.push(t.name.clone());
        p.join("__")
    }

    /// a trait method's result, as Volt's trait spells it: numbers, bool, char as u32, text as
    /// std::string, or as str when it's lent (and the import's types, for cb_types)
    fn trait_ret(&self, t: &Ty) -> Option<String> {
        match t {
            Ty::Str => Some("str".into()),
            t => self.cb_out_ty(t),
        }
    }

    /// the methods of a trait Volt types can implement (the language calls them through a table
    /// of Volt functions): one taking &self or &mut self, not generic, its types cb_in's and
    /// trait_ret's
    pub fn bridged(&self, s: &Sig) -> bool {
        // a lifetime ties a lent result to something the glue can't name
        s.skip.is_none() && s.generics.is_empty() && matches!(s.recv, Recv::Ref | Recv::Mut) && !s.src.contains('\'') && s.params.iter().enumerate().all(|(i, (_, t))| t.as_ref().is_some_and(|t| self.cb_in(t, i).is_some())) && s.ret.as_ref().is_some_and(|t| self.trait_ret(t).is_some())
    }

    /// a value the shim hands a Volt function it calls (a closure's or a trait method's i-th
    /// parameter): its Volt type, the function's extern parameters, the lines before the call and
    /// the argument
    fn cb_in(&self, t: &Ty, i: usize) -> Option<(String, Vec<String>, Vec<String>, String)> {
        let a = format!("a{i}");
        Some(match t {
            Ty::Str | Ty::String => ("str".into(), vec![format!("{a}: u8*"), format!("{a}_n: usize")], Vec::new(), format!("@cast<str>(@slice({a}, {a}_n))")),
            Ty::Prim(x) => (x.to_string(), vec![format!("{a}: {x}")], Vec::new(), a),
            Ty::Char => ("u32".into(), vec![format!("{a}: u32")], Vec::new(), a),
            _ if !self.lang.cb_types() => return None,
            // the other side's closure: a Volt fn calling it (its handle, made already by
            // fn_handle, freed with the fn)
            Ty::Fn(ps, r, _, _) => {
                let (k, (_, _, vts, rt)) = self.fn_tys.iter().enumerate().find(|(_, (a, b, _, _))| a == ps && b == &**r)?;
                let ns = self.shim_ns();
                let xs: Vec<String> = (0..vts.len()).map(|j| format!("x{j}")).collect();
                let params: Vec<String> = xs.iter().zip(vts).map(|(x, t)| format!("{x}: {t}")).collect();
                let call = format!("{a}_f.call({})", xs.join(", "));
                let body = if rt == "void" { format!("{call};") } else { format!("return {call};") };
                (format!("fn({}) -> {rt}", vts.join(", ")), vec![format!("{a}: void*")], vec![format!("var {a}_f: {ns}::fn_{k} = {{ h: {a} }};"), format!("val {a}_c = |move {a}_f| ({}) -> {rt} {{ {body} }};", params.join(", "))], format!("{a}_c"))
            }
            // the shim's elements, lent for the call: numbers, text, the import's types (plain
            // structs' mirrors, handles Volt doesn't free, enums); an array is a copy, as a slice
            Ty::Slice(e, _) | Ty::Vec(e) | Ty::Array(e, _) => match &**e {
                Ty::Prim(x) => (format!("{x}[..]"), vec![format!("{a}: {x}*"), format!("{a}_n: usize")], Vec::new(), format!("@slice({a}, {a}_n)")),
                Ty::Str | Ty::String => ("str[..]".into(), vec![format!("{a}: void*"), format!("{a}_n: usize")], Vec::new(), format!("@slice(@cast<str*>({a}), {a}_n)")),
                Ty::Named(_) | Ty::Ref(..) => {
                    let vp = self.volt_path(&self.elem_info(e)?.def);
                    (format!("{vp}[..]"), vec![format!("{a}: void*"), format!("{a}_n: usize")], Vec::new(), format!("@slice(@cast<{vp}*>({a}), {a}_n)"))
                }
                _ => return None,
            },
            // the shim's number, which the function may change
            Ty::Ref(x, _) if matches!(**x, Ty::Prim(_)) => {
                let Ty::Prim(x) = **x else { return None };
                (format!("{x}&"), vec![format!("{a}: {x}*")], Vec::new(), format!("&*{a}"))
            }
            Ty::Named(_) | Ty::Ref(..) => {
                let (named, by_ref) = match t {
                    Ty::Ref(x, _) => (&**x, true),
                    x => (x, false),
                };
                let ti = self.info(named)?;
                let (vp, mg, ns) = (self.volt_path(&ti.def), Self::mangle(&ti.def), self.shim_ns());
                match ti.kind {
                    Kind::Plain if !by_ref => (vp.clone(), vec![format!("{a}: {vp}*")], Vec::new(), format!("*{a}")),
                    // the shim's copy, which it copies back
                    Kind::Plain => (format!("{vp}&"), vec![format!("{a}: {vp}*")], Vec::new(), format!("&*{a}")),
                    // a handle of its own, freed when the call is done
                    Kind::Handle => (format!("{vp}&"), vec![format!("{a}: void*")], vec![format!("var {a}_h = {ns}::own_{mg}({a});")], format!("&{a}_h")),
                    Kind::Enum if !by_ref => (vp, vec![format!("{a}: i64")], Vec::new(), format!("{ns}::of_{mg}({a})")),
                    _ => return None,
                }
            }
            _ => return None,
        })
    }

    /// a Volt function's result the shim takes back (a closure's or a trait method's): its Volt
    /// type (text out as std::string; an error, for cb_types: the import's error set)
    fn cb_out_ty(&self, r: &Ty) -> Option<String> {
        Some(match r {
            Ty::Unit => "void".into(),
            Ty::Prim(x) => x.to_string(),
            Ty::Char => "u32".into(),
            Ty::String => "std::string".into(),
            _ if !self.lang.cb_types() => return None,
            Ty::Res(x) => {
                let t = self.cb_out_ty(x)?;
                format!("{}::{}_error!{t}", self.alias, self.lang.short())
            }
            Ty::Vec(e) | Ty::Slice(e, _) | Ty::Array(e, _) => match &**e {
                Ty::Prim(x) => format!("std::vec<{x}>"),
                Ty::Str | Ty::String => "std::vec<std::string>".into(),
                Ty::Named(_) | Ty::Ref(..) => format!("std::vec<{}>", self.volt_path(&self.elem_info(e)?.def)),
                _ => return None,
            },
            Ty::Opt(x) => format!("{}?", self.cb_out_ty(x)?),
            Ty::Fn(ps, r, _, _) => self.fn_volt_ty(ps, r)?,
            Ty::Tuple(es) => {
                let mut a = Vec::new();
                for (n, t) in es {
                    let x = self.cb_out_ty(t)?;
                    a.push(if n.is_empty() || n == "_" { x } else { format!("{}: {x}", volt_name(n)) });
                }
                format!("({})", a.join(", "))
            }
            Ty::Named(_) | Ty::Ref(_, false) => {
                let (named, by_ref) = match r {
                    Ty::Ref(x, _) => (&**x, true),
                    x => (x, false),
                };
                let ti = self.info(named)?;
                match ti.kind {
                    // (a *T of a plain struct is its value: the shim returns a pointer to a copy)
                    Kind::Enum if by_ref => return None,
                    _ => self.volt_path(&ti.def),
                }
            }
            _ => return None,
        })
    }

    /// that result's code: the function's extern parameters (where it goes), its return type, and
    /// the lines giving it ($c: the call). stored: a number goes through o too (a trait's table
    /// functions return nothing but an error's status). An error: status 1, its text put where e
    /// says (the shim's)
    fn cb_out(&mut self, r: &Ty, stored: bool, o: &str) -> Option<(Vec<String>, String, String)> {
        let ns = self.shim_ns();
        let t = self.cb_out_ty(r)?;
        Some(match r {
            Ty::Unit => (Vec::new(), "void".into(), "$c;".into()),
            Ty::Prim(_) | Ty::Char if stored => (vec![format!("{o}: {t}*")], "void".into(), format!("*{o} = $c;")),
            Ty::Prim(_) | Ty::Char => (Vec::new(), t, "return $c;".into()),
            // text: put (a copy) where o says, while Volt's lives
            Ty::String => {
                let put = self.put_sym()?;
                (vec![format!("{o}: void*")], "void".into(), format!("val {o}_r = $c;\n        {ns}::{put}({o}, @cast<u8*>({o}_r.as_str().ptr), {o}_r.len());"))
            }
            Ty::Res(x) => {
                let put = self.put_sym()?;
                self.errors = true;
                let (mut ext, _, inner) = self.cb_out(x, true, o)?;
                ext.push("e: void*".into());
                let text = format!("{ns}::{put}(e, @cast<u8*>(m.as_str().ptr), m.len());");
                let fail = format!("catch |err| {{\n            match (err) {{\n                .ERROR(m) => {{ {text} }},\n                .PANIC(m) => {{ {text} }},\n            }}\n            return 1;\n        }}");
                let body = if **x == Ty::Unit { format!("$c {fail};\n        return 0;") } else { format!("val v = $c {fail};\n        {}\n        return 0;", inner.replace("$c", "v")) };
                (ext, "u8".into(), body)
            }
            // a slice: each element pushed onto the shim's (o); an array comes the same way
            Ty::Vec(e) | Ty::Slice(e, _) | Ty::Array(e, _) => {
                let push = self.push_sym(e)?;
                let args = match &**e {
                    Ty::Prim(_) => "*x".to_string(),
                    Ty::Str | Ty::String => "@cast<u8*>(x.as_str().ptr), x.len()".to_string(),
                    _ => {
                        let ti = self.elem_info(e)?;
                        match ti.kind {
                            Kind::Plain => "x".to_string(),
                            Kind::Handle => "x.h".to_string(),
                            Kind::Enum => format!("{ns}::tag_{}(*x)", Self::mangle(&ti.def)),
                        }
                    }
                };
                // (a handle: its value, which must be there)
                let check = match self.elem_info(e) {
                    Some(ti) if ti.kind == Kind::Handle => format!("{}\n            ", self.not_empty(&self.volt_path(&ti.def), "x.h")),
                    _ => String::new(),
                };
                // (a catching shim's push gives a panic's status 2 and text: Volt's panic)
                let (decl, call) = if self.lang.catches() {
                    (format!("var {o}_e: u8* = null;\n        var {o}_en: usize = 0;\n        "), format!("if ({ns}::{push}({o}, {args}, &{o}_e, &{o}_en) == 2) {{\n                {ns}::panicked({o}_e, {o}_en);\n            }}"))
                } else {
                    (String::new(), format!("{ns}::{push}({o}, {args});"))
                };
                (vec![format!("{o}: void*")], "void".into(), format!("val {o}_r = $c;\n        {decl}for (x&) in {o}_r.items() {{\n            {check}{call}\n        }}"))
            }
            // a Volt closure, moved to the heap for the shim to keep: its trampoline, its data and
            // the function freeing it
            Ty::Fn(ps, r, _, _) => {
                let k = self.tramp(ps, r)?;
                (vec![format!("{o}: void**"), format!("{o}_env: void**"), format!("{o}_drop: void**")], "void".into(), format!("val {o}_f = $c;\n        *{o} = @cast<void*>({ns}::tramp_{k});\n        *{o}_env = {ns}::give_tramp_{k}(move {o}_f);\n        *{o}_drop = @cast<void*>({ns}::drop_tramp_{k});"))
            }
            // a value or none: its outs (ov), and whether there's one (o)
            Ty::Opt(x) => {
                let (mut ext, _, inner) = self.cb_out(x, true, &format!("{o}v"))?;
                ext.push(format!("{o}: bool*"));
                let body = format!("val {o}_o = $c;\n        *{o} = {o}_o != null;\n        if ({o}_o != null) {{\n            val {o}_x = {o}_o ?? @panic(\"unreachable\");\n            {}\n        }}", inner.replace("$c", &format!("{o}_x")).replace("\n        ", "\n            "));
                (ext, "void".into(), body)
            }
            // several values: each through its own outs (o0, o1...)
            Ty::Tuple(es) => {
                let mut ext = Vec::new();
                let names: Vec<String> = (0..es.len()).map(|i| format!("{o}{i}_v")).collect();
                let mut body = format!("val ({}) = $c;", names.join(", "));
                for (i, (_, et)) in es.iter().enumerate() {
                    let (x, _, b) = self.cb_out(et, true, &format!("{o}{i}"))?;
                    ext.extend(x);
                    let _ = write!(body, "\n        {}", b.replace("$c", &names[i]));
                }
                (ext, "void".into(), body)
            }
            Ty::Named(_) | Ty::Ref(..) => {
                let named = match r {
                    Ty::Ref(x, _) => &**x,
                    x => x,
                };
                let ti = self.info(named)?;
                let (vp, mg) = (self.volt_path(&ti.def), Self::mangle(&ti.def));
                match ti.kind {
                    Kind::Plain => (vec![format!("{o}: {vp}*")], "void".into(), format!("*{o} = $c;")),
                    // the handle given to the shim (which frees it)
                    Kind::Handle => (vec![format!("{o}: void**")], "void".into(), format!("var {o}_r = $c;\n        {}\n        *{o} = {o}_r.h;\n        {o}_r.h = null;", self.not_lent(&vp, &format!("{o}_r")))),
                    Kind::Enum => (vec![format!("{o}: i64*")], "void".into(), format!("*{o} = {ns}::tag_{mg}($c);")),
                }
            }
            _ => return None,
        })
    }

    /// the shim's function pushing an element of type e onto a slice of its (a Volt closure's
    /// slice result), made the first time one is wanted
    fn push_sym(&mut self, e: &Ty) -> Option<String> {
        let key = format!("{e:?}");
        if let Some(s) = self.pushes.get(&key) {
            return Some(s.clone());
        }
        let sym = self.sym(&[&format!("push{}", self.pushes.len())]);
        let mut ext = vec!["o: void*".to_string()];
        match e {
            Ty::Prim(x) => ext.push(format!("a: {x}")),
            Ty::Str | Ty::String => ext.extend(["a: u8*".to_string(), "a_n: usize".to_string()]),
            _ => {
                let ti = self.elem_info(e)?;
                let vp = self.volt_path(&ti.def);
                ext.push(match ti.kind {
                    Kind::Plain => format!("a: {vp}*"),
                    Kind::Handle => "a: void*".into(),
                    Kind::Enum => "a: i64".into(),
                });
            }
        }
        let catches = self.lang.catches();
        if catches {
            ext.extend(["e: u8**".to_string(), "e_n: usize*".to_string()]);
        }
        let glue = self.lang.push_glue(self, &sym, e)?;
        self.shim.push_str(&glue);
        let decl = self.ext_fn(&sym, &ext, if catches { "u8" } else { "void" });
        self.ext.push_str(&decl);
        self.pushes.insert(key, sym.clone());
        Some(sym)
    }

    /// a trait's Volt declaration (its methods with a body there are optional), and its glue: the
    /// table of a Volt type's methods (vt_T, made by table_T<T>), a function per method calling
    /// it on a T, give_T<T> moving a value to the heap and drop_T<T> freeing it
    fn trait_decl(&mut self, name: &str) -> Result<String, String> {
        let td = self.traits[name].clone();
        if let Some(why) = &td.skip {
            return Err(format!("trait {name} ({why})"));
        }
        // (the other side's closures its methods take: their handle types, made first)
        if self.lang.cb_types() {
            for (s, _) in &td.methods {
                for (_, t) in &s.params {
                    if let Some(Ty::Fn(fps, fr, _, once)) = t {
                        self.fn_handle(fps, fr, *once);
                    }
                }
            }
        }
        let ms: Vec<(Sig, bool)> = td.methods.iter().filter(|(s, _)| self.bridged(s)).cloned().collect();
        if let Some((s, _)) = td.methods.iter().find(|(s, provided)| !provided && !self.bridged(s)) {
            return Err(format!("trait {name} (method {}'s types)", s.name));
        }
        let (vt, mg) = (self.trait_path(&td), Self::trait_mangle(&td));
        let glue = self.lang.trait_glue(self, &td, &ms).ok_or_else(|| format!("trait {name}"))?;
        self.shim.push_str(&glue);
        let mut decl = format!("// {} trait {}: Volt's types attaching it pass where {} takes one\ntrait {name} {{\n", self.lang.name(), td.name, self.lang.name());
        let mut fields = "        drop: void* = null;\n".to_string();
        let mut fill = String::new();
        let mut h = String::new();
        for (s, provided) in &ms {
            let vn = volt_name(&s.name);
            let mut ps = vec!["this".to_string()];
            let mut tps = vec!["env: void*".to_string()];
            let (mut pre, mut args) = (Vec::new(), Vec::new());
            for (i, (n, t)) in s.params.iter().enumerate() {
                let (vt, ext, before, arg) = self.cb_in(t.as_ref().unwrap(), i).unwrap();
                ps.push(format!("{}: {vt}", Self::param_name(n)));
                tps.extend(ext);
                pre.extend(before);
                args.push(arg);
            }
            let r = s.ret.as_ref().unwrap();
            if *provided {
                decl.push_str("    @attributes([@optional])\n");
            }
            let _ = writeln!(decl, "    fn {vn}({}) -> {};", ps.join(", "), self.trait_ret(r).unwrap());
            let call = format!("@cast<T*>(env)->{vn}({})", args.join(", "));
            let (rt, body) = match r {
                Ty::Str => {
                    tps.extend(["o: u8**".to_string(), "o_n: usize*".to_string()]);
                    ("void".to_string(), format!("val r = {call};\n        *o = @cast<u8*>(r.ptr);\n        *o_n = r.len;"))
                }
                // (a number through o: the table's functions return nothing but an error's status)
                x => {
                    let (ext, rt, body) = self.cb_out(x, true, "o").ok_or_else(|| format!("trait {name}"))?;
                    tps.extend(ext);
                    (rt, body.replace("$c", &call))
                }
            };
            let body: String = pre.iter().map(|l| format!("{l}\n        ")).collect::<String>() + &body;
            let _ = write!(h, "\n    <T: {vt}>\n    extern \"C\" fn t_{mg}_{}({}) -> {rt} {{\n        {body}\n    }}\n", s.name, tps.join(", "));
            let _ = writeln!(fields, "        m_{}: void* = null;", s.name);
            let set = format!("t.m_{} = @cast<void*>(t_{mg}_{}<T>);", s.name, s.name);
            if *provided {
                let _ = writeln!(fill, "        comptime if (@has_method(T, \"{vn}\")) {{\n            {set}\n        }}");
            } else {
                let _ = writeln!(fill, "        {set}");
            }
        }
        decl.push_str("}\n");
        let _ = write!(self.helpers, "\n    // trait {vt}'s methods on a Volt value, for {}: the table its glue calls (drop: null when the value is lent)\n    struct vt_{mg} {{\n{fields}    }}\n{h}", self.lang.name());
        let _ = write!(self.helpers, "\n    <T: {vt}>\n    extern \"C\" fn drop_{mg}(env: void*) -> void {{\n        val p = @cast<T*>(env);\n        val v = @read(p);\n        val a: std::mem::default_allocator = {{}};\n        a.free<T>(p);\n    }}\n");
        let _ = write!(self.helpers, "\n    <T: {vt}>\n    fn table_{mg}(owned: bool) -> vt_{mg} {{\n        var t: vt_{mg} = {{}};\n        if (owned) {{\n            t.drop = @cast<void*>(drop_{mg}<T>);\n        }}\n{fill}        return t;\n    }}\n");
        let _ = write!(self.helpers, "\n    // v moved to the heap, for {} to keep (drop_{mg} frees it)\n    <T: {vt}>\n    fn give_{mg}(v: T) -> void* {{\n        val a: std::mem::default_allocator = {{}};\n        val p: T* = a.malloc<T>() catch @panic(\"out of memory\");\n        @write(p, move v);\n        return @cast<void*>(p);\n    }}\n", self.lang.name());
        self.made_traits.insert(name.to_string());
        Ok(decl)
    }

    /// type ty's attach block of trait tr: each method calls the other side's (a method with a
    /// body there that Volt's trait doesn't have is a helper of the block)
    fn attach_block(&mut self, ty: &str, tr: &str) -> Result<String, String> {
        let td = self.traits[tr].clone();
        let ti = self.types.get(ty).ok_or_else(|| format!("{ty}'s {tr} (Volt can't name the type)"))?;
        let (module, tvp, vt) = (ti.def.module.clone(), self.volt_path(&ti.def), self.trait_path(&td));
        self.block = Some(tr.to_string());
        let mut body = String::new();
        let mut failed = None;
        for (s, provided) in &td.methods {
            match self.function(&module, s, Some(ty)) {
                Ok(f) => {
                    for l in f.lines() {
                        let _ = writeln!(body, "    {l}");
                    }
                }
                Err(why) if *provided => self.left_out.push(why),
                Err(why) => {
                    failed = Some(why);
                    break;
                }
            }
        }
        self.block = None;
        if let Some(why) = failed {
            return Err(why);
        }
        Ok(format!("attach {vt} -> {tvp} {{\n{body}}}\n"))
    }

    /// a closure's Volt type: fn(A, B) -> R (its parameters as the shim hands them, its result
    /// as the shim takes it; text out as std::string)
    fn fn_volt_ty(&self, ps: &[Ty], r: &Ty) -> Option<String> {
        let mut a = Vec::new();
        for (i, p) in ps.iter().enumerate() {
            a.push(self.cb_in(p, i)?.0);
        }
        let r = self.cb_out_ty(r)?;
        Some(format!("fn({}) -> {r}", a.join(", ")))
    }

    /// the trampoline for Volt closures of this signature, which the shim calls with the closure as
    /// its data: tramp_K (made once per signature)
    fn tramp(&mut self, ps: &[Ty], r: &Ty) -> Option<usize> {
        let ft = self.fn_volt_ty(ps, r)?;
        if let Some(k) = self.tramps.iter().position(|x| *x == ft) {
            return Some(k);
        }
        let k = self.tramps.len();
        let mut params = vec!["env: void*".to_string()];
        let (mut pre, mut args) = (Vec::new(), Vec::new());
        for (i, p) in ps.iter().enumerate() {
            let (_, ext, before, arg) = self.cb_in(p, i)?;
            params.extend(ext);
            pre.extend(before);
            args.push(arg);
        }
        if matches!(r, Ty::Str) {
            return None;
        }
        let call = format!("(*f)({})", args.join(", "));
        // a String result: put where o points, while the Volt one lives
        let (ext, rt, body) = self.cb_out(r, false, "o")?;
        params.extend(ext);
        let body = body.replace("$c", &call);
        let body: String = pre.iter().map(|l| format!("{l}\n        ")).collect::<String>() + &body;
        let _ = write!(self.helpers, "\n    // calls a Volt {ft} for the shim (the closure is its data)\n    extern \"C\" fn tramp_{k}({}) -> {rt} {{\n        val f = @cast<({ft})*>(env);\n        {body}\n    }}\n", params.join(", "));
        let _ = write!(self.helpers, "\n    // a {ft} moved to the heap, for the shim to keep (drop_tramp_{k} frees it)\n    fn give_tramp_{k}(f: {ft}) -> void* {{\n        val a: std::mem::default_allocator = {{}};\n        val p: ({ft})* = a.malloc<({ft})>() catch @panic(\"out of memory\");\n        @write(p, move f);\n        return @cast<void*>(p);\n    }}\n\n    extern \"C\" fn drop_tramp_{k}(env: void*) -> void {{\n        val p = @cast<({ft})*>(env);\n        val f = @read(p);\n        val a: std::mem::default_allocator = {{}};\n        a.free<({ft})>(p);\n    }}\n");
        self.tramps.push(ft);
        Some(k)
    }

    /// the handle type of closures of this signature the shim gives Volt: fn_K, called with
    /// call(...), freed when it goes (made once per signature)
    fn fn_handle(&mut self, ps: &[Ty], r: &Ty, once: bool) -> Option<usize> {
        // its parameters and result as a function's (x0...: its parameters' Volt names)
        let mut vps = Vec::new();
        let mut ext = vec!["h: void*".to_string()];
        let mut args = vec!["this.h".to_string()];
        let mut locals = Vec::new();
        for (i, p) in ps.iter().enumerate() {
            let v = self.volt_param(&format!("x{i}"), p, i)?;
            if v.generic.is_some() {
                return None;
            }
            vps.push(v.param);
            ext.extend(v.ext);
            locals.extend(v.pre);
            args.extend(v.args);
        }
        if matches!(r, Ty::Str) {
            return None;
        }
        let ns = self.shim_ns();
        let catches = self.lang.catches();
        let err = format!("{}::{}_error", self.alias, self.lang.short());
        // an error it returns (status 1, with a catching shim): an error of the set
        let (res, val) = match r {
            Ty::Res(x) if catches => (true, &**x),
            x => (false, x),
        };
        let mut give = Vec::new();
        let vt = if *val == Ty::Unit {
            if res {
                give.push("return;".into());
            }
            "void".to_string()
        } else {
            let o = self.volt_out(val, "o")?;
            if o.ty.ends_with('?') {
                // (a value or none: the shim says which)
                if !self.lang.cb_types() || res {
                    return None;
                }
                give.push("if (!o_has) {\n            return null;\n        }".into());
            }
            ext.extend(o.ext);
            args.extend(o.args);
            locals.extend(o.locals);
            give.push(format!("return {};", o.value));
            o.ty
        };
        let rt = if res { format!("{err}!{vt}") } else { vt };
        let failed = format!("if (st == 1) {{\n            return {err}::ERROR({ns}::take(e, e_n));\n        }}");
        let ft = format!("{}fn({}) -> {rt}", if once { "once " } else { "" }, vps.iter().map(|p: &String| p.split_once(": ").map_or(p.as_str(), |x| x.1)).collect::<Vec<_>>().join(", "));
        if let Some(k) = self.fn_handles.iter().position(|x| *x == ft) {
            return Some(k);
        }
        let k = self.fn_handles.len();
        let sym = format!("volt_{}_{}_fn{k}", self.lang.short(), self.alias);
        let glue = self.lang.fn_glue(self, &sym, ps, r, once)?;
        // a panic in the closure: the program stops (call), or it's an error (try_call)
        let mut body = locals.clone();
        let mut try_body = Vec::new();
        if catches {
            ext.extend(["e: u8**".to_string(), "e_n: usize*".to_string()]);
            args.extend(["&e".to_string(), "&e_n".to_string()]);
            body.extend(["var e: u8* = null;".to_string(), "var e_n: usize = 0;".to_string()]);
            try_body = body.clone();
            let quiet = self.sym(&["quiet"]);
            body.push(format!("val st = {ns}::{sym}_call({});", args.join(", ")));
            body.push(format!("if (st == 2) {{\n            {ns}::panicked(e, e_n);\n        }}"));
            try_body.extend([format!("val quiet = {ns}::{quiet}(true);"), format!("val st = {ns}::{sym}_call({});", args.join(", ")), format!("{ns}::{quiet}(quiet);"), format!("if (st == 2) {{\n            return {err}::PANIC({ns}::take(e, e_n));\n        }}")]);
            if res {
                body.push(failed.clone());
                try_body.push(failed);
            }
            try_body.extend(give.clone());
            self.errors = true;
        } else {
            body.push(format!("{ns}::{sym}_call({});", args.join(", ")));
        }
        body.extend(give);
        let decl = self.ext_fn(&format!("{sym}_call"), &ext, if catches { "u8" } else { "void" });
        self.ext.push_str(&decl);
        let decl = self.ext_fn(&format!("{sym}_drop"), &["h: void*".to_string()], "void");
        self.ext.push_str(&decl);
        let lines: String = body.iter().map(|l| format!("        {l}\n")).collect();
        let empty = format!("        if (this.h == null) {{\n            @panic(\"a {} closure called after it was given away\");\n        }}\n", self.lang.name());
        let _ = write!(self.helpers, "\n    // a {} closure, {ft}: call(...) calls it; it's freed when it goes\n    struct fn_{k} {{\n        h: void* = null;\n    }}\n\n    attach fn call(this: fn_{k}&, {}) -> {rt} {{\n{empty}{lines}    }}\n\n    attach fn delete(this: fn_{k}&) -> void {{\n        if (this.h != null) {{\n            {ns}::{sym}_drop(this.h);\n            this.h = null;\n        }}\n    }}\n", self.lang.name(), vps.join(", "));
        if catches {
            let try_lines: String = try_body.iter().map(|l| format!("        {l}\n")).collect();
            let try_rt = if res { rt.clone() } else { format!("{err}!{rt}") };
            let _ = write!(self.helpers, "\n    // call, with a panic as {err}::PANIC\n    attach fn try_call(this: fn_{k}&, {}) -> {try_rt} {{\n{empty}{try_lines}    }}\n", vps.join(", "));
        }
        self.shim.push_str(&glue);
        self.fn_handles.push(ft);
        self.fn_tys.push((ps.to_vec(), r.clone(), vps.iter().map(|p| p.split_once(": ").map_or(p.clone(), |x| x.1.to_string())).collect(), rt.clone()));
        Some(k)
    }

    /// a generic function's Volt declaration: generic over its type parameters, marked
    /// @rust_generic (voltc calls the instance made for a call's types, NAME__T, and asks for the
    /// ones not made yet); its body only stands in until then
    fn generic(&mut self, module: &[String], s: &Sig, self_ty: Option<&str>, what: &str) -> Result<String, String> {
        let unnamed = || format!("{what} (it's generic, and Volt can't spell its signature)");
        let mut ps = Vec::new();
        if let Some(t) = self_ty {
            let vp = self.volt_path(&self.types.get(t).ok_or_else(unnamed)?.def);
            match s.recv {
                Recv::None => ps.push(format!("static this: {vp}")),
                Recv::Value | Recv::Own(_) => ps.push(format!("this: {vp}")),
                _ => ps.push(format!("this: {vp}&")),
            }
        }
        for (n, t) in &s.params {
            let t = t.clone().map(|t| self.resolve(t, self_ty)).ok_or_else(unnamed)?;
            if matches!(t, Ty::Alloc | Ty::Comptime(_)) {
                continue;
            }
            ps.push(format!("{}: {}", Self::param_name(n), self.generic_ty(&t, false).ok_or_else(unnamed)?));
        }
        let ret = s.ret.clone().map(|t| self.resolve(t, self_ty)).ok_or_else(unnamed)?;
        let rt = self.generic_ty(&ret, true).ok_or_else(unnamed)?;
        let mut path: Vec<String> = module.to_vec();
        if let Some(t) = self_ty {
            path.push(t.to_string());
        }
        path.push(s.name.clone());
        let path = path.join("::");
        let tps: Vec<String> = s.generics.iter().map(|g| generic_param(g)).collect();
        let kw = if self_ty.is_some() { "attach fn" } else { "fn" };
        let mut f = String::new();
        if !s.src.is_empty() {
            f.push_str(&format!("// {}: {}\n", self.lang.name(), s.src));
        }
        f.push_str(&format!("<{}>\n@attributes([@rust_generic(\"{path}\")])\n{kw} {}({}) -> {rt} {{\n", tps.join(", "), volt_name(&s.name), ps.join(", ")));
        f.push_str(&format!("    @panic(\"{}'s instance for these types isn't built\");\n}}\n", path));
        if self.lang.catches() {
            // its try_ form (each instance has one)
            self.errors = true;
            let err = format!("{}::{}_error", self.alias, self.lang.short());
            let rt_err = if rt.starts_with(&err) { rt.clone() } else { format!("{err}!{}", if rt.ends_with('?') { format!("({rt})") } else { rt.clone() }) };
            f.push_str(&format!("\n<{}>\n@attributes([@rust_generic(\"{path}\")])\n{kw} try_{}({}) -> {rt_err} {{\n", tps.join(", "), s.name, ps.join(", ")));
            f.push_str(&format!("    @panic(\"{}'s instance for these types isn't built\");\n}}\n", path));
        }
        Ok(f)
    }

    /// a type in a generic declaration's signature, as Volt spells it (out: a result)
    fn generic_ty(&mut self, t: &Ty, out: bool) -> Option<String> {
        Some(match t {
            Ty::Generic(g) => g.clone(),
            Ty::Unit => "void".into(),
            Ty::Prim(x) => x.to_string(),
            Ty::Char => "u32".into(),
            Ty::Str | Ty::String => (if out { "std::string" } else { "str" }).into(),
            Ty::Slice(e, _) | Ty::Vec(e) | Ty::Array(e, _) => {
                let e = self.generic_ty(e, out)?;
                if out { format!("std::vec<{e}>") } else { format!("{e}[..]") }
            }
            // a closure: its types as a closure's (text in as str, out as std::string)
            Ty::Fn(ps, r, _, _) => {
                let mut a = Vec::new();
                for p in ps {
                    a.push(match p {
                        Ty::Str | Ty::String => "str".to_string(),
                        p => self.generic_ty(p, false)?,
                    });
                }
                format!("fn({}) -> {}", a.join(", "), self.generic_ty(r, true)?)
            }
            Ty::Inst(n, args) => {
                let d = self.m.types.iter().find(|t| t.name == *n && t.generic)?;
                // (type arguments: text is std::string)
                let mut a = Vec::new();
                for x in args {
                    a.push(self.generic_ty(x, true)?);
                }
                format!("{}<{}>", self.volt_path(d), a.join(", "))
            }
            Ty::Tuple(es) if out => {
                let mut a = Vec::new();
                for (n, t) in es {
                    let x = self.generic_ty(t, true)?;
                    a.push(if n.is_empty() || n == "_" { x } else { format!("{}: {x}", volt_name(n)) });
                }
                format!("({})", a.join(", "))
            }
            Ty::Opt(e) => format!("{}?", self.generic_ty(e, out)?),
            Ty::Named(n) => self.volt_path(&self.types.get(n)?.def),
            Ty::Ref(x, _) => format!("{}&", self.generic_ty(x, out)?),
            Ty::Res(x) => {
                self.errors = true;
                let x = self.generic_ty(x, out)?;
                format!("{}::{}_error!{x}", self.alias, self.lang.short())
            }
            _ => return None,
        })
    }

    /// the shim's source and the Volt source
    pub fn write(mut self, what: &str) -> (String, String) {
        let names: Vec<String> = self.types.keys().cloned().collect();
        for n in &names {
            let module = self.types[n].def.module.clone();
            let d = self.type_decl(n);
            self.modules.entry(module).or_default().push_str(&format!("\n{d}"));
        }
        // the traits (before any function: a function taking one names its glue), then the types
        // attaching them
        let tnames: Vec<String> = self.traits.keys().cloned().collect();
        for n in &tnames {
            let module = self.traits[n].module.clone();
            match self.trait_decl(n) {
                Ok(d) => self.modules.entry(module).or_default().push_str(&format!("\n{d}")),
                Err(why) => self.left_out.push(why),
            }
        }
        for (ty, tr) in self.m.impls.clone() {
            if !self.made_traits.contains(&tr) {
                continue;
            }
            match self.attach_block(&ty, &tr) {
                Ok(b) => {
                    let module = self.types[&ty].def.module.clone();
                    self.modules.entry(module).or_default().push_str(&format!("\n{b}"));
                }
                Err(why) => self.left_out.push(format!("{ty} attaching {tr}: {why}")),
            }
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
        for e in self.err_sets.keys().cloned().collect::<Vec<_>>() {
            let module = self.m.types.iter().find(|t| t.name == e).map_or(Vec::new(), |t| t.module.clone());
            if let Some(d) = self.err_decl(&e) {
                self.modules.entry(module).or_default().push_str(&format!("\n{d}"));
            }
        }
        for (module, name, ty, lit) in self.m.consts.clone() {
            self.modules.entry(module).or_default().push_str(&format!("\nval {}: {ty} = {lit};\n", volt_name(&name)));
        }
        for (module, name, t) in self.m.aliases.clone() {
            match self.generic_ty(&t, false) {
                Some(v) => self.modules.entry(module).or_default().push_str(&format!("\n// {}: an alias\ntype {} = {v};\n", self.lang.name(), volt_name(&name))),
                None => self.left_out.push(format!("{name} (an alias of a type Volt can't name)")),
            }
        }
        for t in &self.m.types {
            if t.generic && t.params.is_empty() {
                self.left_out.push(format!("{} (it's generic over more than types)", t.name));
            } else if t.generic {
                // a type per instance a program names (TYPE__ARGS, made as voltc asks for it)
                let mut path = t.module.clone();
                path.push(t.name.clone());
                let tps: Vec<String> = t.params.iter().map(|g| generic_param(g)).collect();
                let d = format!("// {}: {} (generic: a type per instance a program names)\n<{}>\n@attributes([@rust_generic(\"{}\")])\nstruct {} {{\n}}\n", self.lang.name(), t.name, tps.join(", "), path.join("::"), volt_name(&t.name));
                self.modules.entry(t.module.clone()).or_default().push_str(&format!("\n{d}"));
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
        for n in self.elem_types.clone() {
            let Some(ti) = self.types.get(&n) else { continue };
            let (vp, mg) = (self.volt_path(&ti.def), Self::mangle(&ti.def));
            match ti.kind {
                Kind::Handle => {
                    let f = free("ptrs");
                    if !ext.contains(&format!(" {f}(")) {
                        ext.push_str(&self.ext_fn(&f, &["p: void**".to_string(), "n: usize".to_string()], "void"));
                    }
                    let _ = write!(helpers, "    fn take_{mg}s(p: void**, n: usize, lent: bool) -> std::vec<{vp}> {{\n        var out: std::vec<{vp}> = {{}};\n        if (n == 0) {{\n            return out;\n        }}\n        for (x) in @slice(p, n) {{\n            out.push({{ h: x, lent: lent }}) catch @panic(\"out of memory\");\n        }}\n        {f}(p, n);\n        return out;\n    }}\n");
                }
                Kind::Plain => {
                    let f = free(&format!("{mg}s"));
                    ext.push_str(&self.ext_fn(&f, &[format!("p: {vp}*"), "n: usize".to_string()], "void"));
                    let _ = write!(helpers, "    fn take_{mg}s(p: {vp}*, n: usize) -> std::vec<{vp}> {{\n        var out: std::vec<{vp}> = {{}};\n        if (n == 0) {{\n            return out;\n        }}\n        for (x) in @slice(p, n) {{\n            out.push(x) catch @panic(\"out of memory\");\n        }}\n        {f}(p, n);\n        return out;\n    }}\n");
                }
                Kind::Enum => {
                    let _ = write!(helpers, "    fn take_{mg}s(p: i64*, n: usize) -> std::vec<{vp}> {{\n        var out: std::vec<{vp}> = {{}};\n        if (n == 0) {{\n            return out;\n        }}\n        for (x) in @slice(p, n) {{\n            out.push(of_{mg}(x)) catch @panic(\"out of memory\");\n        }}\n        {}(p, n);\n        return out;\n    }}\n", free("i64s"));
                }
            }
        }
        if self.strs {
            let f = free("strs");
            ext.push_str(&self.ext_fn(&f, &["p: owned_str*".to_string(), "n: usize".to_string()], "void"));
            let _ = write!(helpers, "    struct owned_str {{\n        p: u8*;\n        n: usize;\n    }}\n\n    fn take_strs(p: owned_str*, n: usize) -> std::vec<std::string> {{\n        var out: std::vec<std::string> = {{}};\n        if (n == 0) {{\n            return out;\n        }}\n        for (x) in @slice(p, n) {{\n            out.push(std::string::from(@cast<str>(@slice(x.p, x.n)))) catch @panic(\"out of memory\");\n        }}\n        {f}(p, n);\n        return out;\n    }}\n");
        }
        if self.lang.catches() {
            let quiet = self.sym(&["quiet"]);
            ext.push_str(&self.ext_fn(&quiet, &["on: bool".to_string()], "bool"));
            ext.push_str(&self.ext_fn(&self.sym(&["poll"]), &["h: void*".to_string(), "outs: void**".to_string(), "e: u8**".to_string(), "e_n: usize*".to_string()], "u8"));
            ext.push_str(&self.ext_fn(&self.sym(&["future_drop"]), &["h: void*".to_string()], "void"));
            let _ = write!(helpers, "    // stops the program at a {} panic, with its message\n    fn panicked(p: u8*, n: usize) -> void {{\n        val m = take(p, n);\n        @panic(m.as_str());\n    }}\n", self.lang.name());
        }
        helpers.push_str(&self.helpers);
        helpers.push_str(&self.lang.volt_glue(&self));
        if let Some(l) = self.lang.loader(&self) {
            helpers.push_str(&l);
        }
        let short = self.lang.short();
        let mut volt = format!("// use {short} {{ ... }} as {}: {what}'s public API, called through its shim (written by bolt import)\n\nnamespace {short}_shim {{\n{ext}{}\n{helpers}}}\n", self.alias, self.ext);
        if self.errors {
            let panic = if self.lang.catches() { format!("\n    // a panic, as its message (a try_ form's)\n    PANIC: std::string,") } else { String::new() };
            let _ = write!(volt, "\n// a {} error, as its message\nerror {short}_error {{\n    ERROR: std::string,{panic}\n}}\n", self.lang.name());
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

/// a generic's parameter as Volt declares it: a type (T), or a value of a type (N: usize)
fn generic_param(g: &str) -> String {
    if g.contains(':') { g.to_string() } else { format!("{g}: type") }
}

/// a Volt type name as an identifier: std::vec<i32> is std_vec_i32 (voltc's ident_of)
pub fn ident(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        if c.is_ascii_alphanumeric() || c == '_' {
            out.push(c);
        } else if !out.is_empty() && !out.ends_with('_') {
            out.push('_');
        }
    }
    out.trim_end_matches('_').to_string()
}

/// the type a Volt type name stands for in the crate (alias:: names one of its types)
pub fn volt_ty(v: &str, alias: &str, types: &BTreeMap<String, Vec<String>>) -> Option<Ty> {
    let v = v.trim();
    if let Some(inner) = v.strip_suffix('?') {
        return Some(Ty::Opt(Box::new(volt_ty(inner, alias, types)?)));
    }
    if let Some(p) = prim(v) {
        return Some(Ty::Prim(p));
    }
    if let Some(e) = v.strip_suffix("[..]") {
        return Some(Ty::Slice(Box::new(volt_ty(e, alias, types)?), false));
    }
    if v == "str" {
        return Some(Ty::Str);
    }
    if v == "std::string" || v.starts_with("std::string<") {
        return Some(Ty::String);
    }
    if let Some(inner) = v.strip_prefix("std::vec<").and_then(|x| x.strip_suffix('>')) {
        // std::vec<T, A>: its allocator isn't Rust's business
        let mut depth = 0;
        let end = inner.char_indices().find(|&(_, c)| {
            match c {
                '<' => depth += 1,
                '>' => depth -= 1,
                _ => {}
            }
            c == ',' && depth == 0
        });
        let elem = &inner[..end.map_or(inner.len(), |(i, _)| i)];
        return Some(Ty::Vec(Box::new(volt_ty(elem, alias, types)?)));
    }
    let local = v.strip_prefix(alias)?.strip_prefix("::")?;
    let segs: Vec<&str> = local.split("::").collect();
    let (name, module) = segs.split_last()?;
    let tm = types.get(*name)?;
    (tm.iter().map(|m| volt_name(m)).collect::<Vec<_>>() == module.iter().map(|m| m.to_string()).collect::<Vec<_>>()).then(|| Ty::Named(name.to_string()))
}

/// t with its type parameters replaced (and a generic type, "type NAME", by its instance)
pub fn substitute(t: &Ty, s: &BTreeMap<String, Ty>) -> Ty {
    match t {
        Ty::Generic(g) => s.get(g).cloned().unwrap_or_else(|| t.clone()),
        Ty::Named(n) => s.get(&format!("type {n}")).cloned().unwrap_or_else(|| t.clone()),
        // a Zig comptime parameter: the instance's argument, as Zig spells it ("comptime NAME")
        Ty::Comptime(g) => s.get(&format!("comptime {g}")).cloned().unwrap_or_else(|| t.clone()),
        Ty::Slice(e, m) => Ty::Slice(Box::new(substitute(e, s)), *m),
        Ty::Vec(e) => Ty::Vec(Box::new(substitute(e, s))),
        Ty::Opt(e) => Ty::Opt(Box::new(substitute(e, s))),
        Ty::Res(e) => Ty::Res(Box::new(substitute(e, s))),
        Ty::Fails(e, x) => Ty::Fails(Box::new(substitute(e, s)), x.clone()),
        Ty::Future(e) => Ty::Future(Box::new(substitute(e, s))),
        Ty::Array(e, n) => Ty::Array(Box::new(substitute(e, s)), *n),
        Ty::Inst(n, args) => Ty::Inst(n.clone(), args.iter().map(|x| substitute(x, s)).collect()),
        Ty::Tuple(es) => Ty::Tuple(es.iter().map(|(n, t)| (n.clone(), substitute(t, s))).collect()),
        // a closure parameter's type stands for the closure itself
        Ty::Fn(ps, r, p, once) => Ty::Fn(ps.iter().map(|x| substitute(x, s)).collect(), Box::new(substitute(r, s)), *p, *once),
        // &T of text is str and of a Vec a slice, as the reader maps them; of a number it stays a
        // reference (the generic's Volt side takes T&)
        Ty::Ref(e, m) => match (substitute(e, s), *m) {
            (Ty::String | Ty::Str, false) => Ty::Str,
            // &F of a closure type: the closure, lent (and &S of a trait's type, its value)
            (Ty::Fn(ps, r, _, o), m) => Ty::Fn(ps, r, if m { FnPass::MutRef } else { FnPass::Ref }, o),
            (Ty::Dyn(tr, _), m) => Ty::Dyn(tr, if m { FnPass::MutRef } else { FnPass::Ref }),
            (Ty::Vec(x), m) => Ty::Slice(x, m),
            (x, m) => Ty::Ref(Box::new(x), m),
        },
        _ => t.clone(),
    }
}

/// the enums a function's Result has as its error
fn fails_of(m: &Model) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let sigs = m.fns.iter().map(|(_, s)| s).chain(m.methods.values().flatten());
    for s in sigs {
        match &s.ret {
            Some(Ty::Fails(_, e)) => {
                out.insert(e.clone());
            }
            Some(Ty::Future(x)) => {
                if let Ty::Fails(_, e) = &**x {
                    out.insert(e.clone());
                }
            }
            _ => {}
        }
    }
    out
}

/// whether a type is used as a value (a parameter, a result, a field, its own methods), not
/// only as an error
fn value_use(m: &Model, name: &str) -> bool {
    fn names(t: &Ty, n: &str) -> bool {
        match t {
            Ty::Named(x) => x == n,
            Ty::Opt(x) | Ty::Res(x) | Ty::Vec(x) | Ty::Slice(x, _) | Ty::Ref(x, _) | Ty::Array(x, _) => names(x, n),
            Ty::Tuple(es) => es.iter().any(|(_, t)| names(t, n)),
            Ty::Fails(x, _) | Ty::Future(x) => names(x, n),
            Ty::Fn(ps, r, _, _) => ps.iter().any(|p| names(p, n)) || names(r, n),
            _ => false,
        }
    }
    if m.methods.get(name).is_some_and(|ms| !ms.is_empty()) {
        return true;
    }
    let sigs = m.fns.iter().map(|(_, s)| s).chain(m.methods.values().flatten()).chain(m.traits.iter().flat_map(|t| t.methods.iter().map(|(s, _)| s)));
    for s in sigs {
        if s.params.iter().any(|(_, t)| t.as_ref().is_some_and(|t| names(t, name))) || s.ret.as_ref().is_some_and(|t| names(t, name)) {
            return true;
        }
    }
    m.types.iter().any(|t| t.fields.iter().flatten().any(|(_, _, ft)| ft.as_ref().is_some_and(|ft| names(ft, name))))
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
