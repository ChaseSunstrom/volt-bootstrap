// use { "geom.py" } as NAME; (or a package's directory) — a Python module called from Volt. bolt
// asks Python itself what the module exports (DESCRIBE: inspect and the type hints), and writes
// Volt that calls it through Python's C API: its Python.h, imported like any C header, and py_rt, a
// small runtime in the import's namespace. No shim and no C: Python starts the first time it's
// called (or the interpreter the process has is used), and each call holds the GIL.
//
//   int, float, bool -> i64, f64, bool; str -> str in, std::string out; bytes -> u8[..] in,
//   std::vec<u8> out; list[int|float|bool|str] -> T[..] in (what Python changes in the list comes
//   back), std::vec<T> out; X | None -> X? (a class: an empty handle is None); None -> void
//   a class of the module -> a handle (a reference: a copy refers to the same object); its
//   __init__ is T::new(...); methods, static and class methods; properties and annotated
//   attributes as x() and set_x(v); as_B() for each base class of the module
//   an Enum of the module -> a Volt enum (int values kept)
//   UPPER_CASE constants of numbers, bools and strings -> vals; simple defaults stay defaults
//   an exception -> the program stops with its type and message
use super::{arg_path, fresh, save, stamp, volt_name, Made, Req};
use std::collections::BTreeSet;
use std::fmt::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn import(r: &Req) -> Result<(), String> {
    let [arg] = r.args.as_slice() else {
        return Err(format!("use python {{ \"geom.py\" }} as {}: name one module (a .py file, or a package's directory)", r.alias));
    };
    let p = arg_path(r, arg);
    let module = if p.is_file() && p.extension().is_some_and(|e| e == "py") {
        p.file_stem().map(|s| s.to_string_lossy().into_owned())
    } else if p.is_dir() && p.join("__init__.py").is_file() {
        p.file_name().map(|s| s.to_string_lossy().into_owned())
    } else {
        None
    }
    .ok_or(format!("use python: {} isn't a .py file or a package (a directory with an __init__.py)", p.display()))?;
    let dir = p.parent().map_or_else(|| PathBuf::from("."), Path::to_path_buf);
    let mut files = Vec::new();
    py_files(&p, &mut files);
    let python = std::env::var("PYTHON").unwrap_or_else(|_| "python3".into());
    let st = stamp(&files, &format!("python {} {} {python}", r.alias, p.display()));
    if fresh(r, &st) {
        return Ok(());
    }
    std::fs::create_dir_all(&r.out).map_err(|e| format!("can't make {}: {e}", r.out.display()))?;
    let out = std::fs::canonicalize(&r.out).unwrap_or_else(|_| r.out.clone());

    // Python.h and libpython, as python3-config says ($PYTHON_CONFIG for another)
    let config = std::env::var("PYTHON_CONFIG").unwrap_or_else(|_| format!("{python}-config"));
    let ask = |args: &[&str]| -> Option<String> {
        let o = Command::new(&config).args(args).output().ok()?;
        o.status.success().then(|| String::from_utf8_lossy(&o.stdout).trim().to_string())
    };
    let includes = ask(&["--includes"]).ok_or(format!("use python: can't run {config} --includes: install Python's development files, or set $PYTHON_CONFIG"))?;
    let header = includes.split_whitespace().filter_map(|w| w.strip_prefix("-I")).map(|d| Path::new(d).join("Python.h")).find(|h| h.is_file()).ok_or(format!("use python: no Python.h in {includes}"))?;
    let ld = ask(&["--ldflags", "--embed"]).or_else(|| ask(&["--ldflags"])).unwrap_or_default();

    // what the module exports
    crate::build::write_if_changed(&out.join("describe.py"), DESCRIBE)?;
    let o = Command::new(&python).arg(out.join("describe.py")).arg(&dir).arg(&module).output().map_err(|e| format!("use python: can't run {python}: {e} (set $PYTHON to the python to use)"))?;
    if !o.status.success() {
        return Err(format!("use python: can't read module {module}:\n{}", String::from_utf8_lossy(&o.stderr)));
    }
    let (items, left) = read(&String::from_utf8_lossy(&o.stdout));
    let volt = generate(&r.alias, &items, left, &dir, &module, &header);
    save(r, &Made { volt, flags: ld.split_whitespace().map(str::to_string).collect(), deps: files }, &st)
}

/// a module's .py files: the file, or a package's (and its subpackages')
fn py_files(p: &Path, out: &mut Vec<PathBuf>) {
    if p.is_file() {
        out.push(p.to_path_buf());
        return;
    }
    let Ok(rd) = std::fs::read_dir(p) else { return };
    let mut ps: Vec<PathBuf> = rd.flatten().map(|e| e.path()).collect();
    ps.sort();
    for x in ps {
        if x.is_dir() && x.join("__init__.py").is_file() {
            py_files(&x, out);
        } else if x.extension().is_some_and(|e| e == "py") {
            out.push(x);
        }
    }
}

/// a Python program printing what a module exports, a declaration a line (tab-separated); its
/// arguments: the module's directory and name.
///   func NAME fn|ctor|inst|static, then param NAME TYPE pos|kw DEFAULT, result TYPE; end
///   class NAME class|enum, then super NAME, value NAME N, its funcs, attr NAME TYPE ro|rw; end
///   const NAME TYPE LITERAL; other NAME WHY
/// TYPE: int, float, bool, str, bytes, void, cls:NAME, T[] (of the first four), T? or other; none
/// when a parameter has no annotation. DEFAULT: a Volt literal, or - (none, or one Volt can't write)
const DESCRIBE: &str = r#"import enum, importlib, inspect, sys, types, typing

sys.path.insert(0, sys.argv[1])
M = importlib.import_module(sys.argv[2])
public = getattr(M, "__all__", None)


def exported(n):
    return (n in public) if public is not None else not n.startswith("_")


classes = {n: c for n, c in vars(M).items() if inspect.isclass(c) and c.__module__ == M.__name__ and exported(n)}
prims = {int: "int", float: "float", bool: "bool", str: "str", bytes: "bytes"}
empty = inspect.Parameter.empty


def T(t):
    if t is empty:
        return "none"
    if t is None or t is type(None):
        return "void"
    o, a = typing.get_origin(t), typing.get_args(t)
    if o in (typing.Union, types.UnionType):
        rest = [x for x in a if x is not type(None)]
        if len(rest) == 1 and len(a) == 2:
            x = T(rest[0])
            return x + "?" if x not in ("other", "none", "void") and not x.endswith("?") else "other"
        return "other"
    if o is list and len(a) == 1:
        x = T(a[0])
        return x + "[]" if x in ("int", "float", "bool", "str") else "other"
    if t in prims:
        return prims[t]
    if isinstance(t, type) and classes.get(t.__name__) is t:
        return "cls:" + t.__name__
    return "other"


def lit(v):
    if v is empty:
        return "-"
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        r = repr(v)
        return r if "." in r and "e" not in r and "n" not in r else "-"
    if isinstance(v, str) and all(32 <= ord(c) < 127 and c not in '"\\{}' for c in v):
        return '"' + v + '"'
    return "-"


def func(name, kind, f, skip_first):
    try:
        sig = inspect.signature(f)
        hints = typing.get_type_hints(f)
    except Exception as e:
        print(f"other\t{name}\tits signature can't be read: {e}")
        return
    print(f"func\t{name}\t{kind}")
    for p in list(sig.parameters.values())[1 if skip_first else 0:]:
        if p.kind in (p.VAR_POSITIONAL, p.VAR_KEYWORD):
            print(f"param\t{p.name}\tother\tpos\t-")
            continue
        k = "kw" if p.kind == p.KEYWORD_ONLY else "pos"
        print(f"param\t{p.name}\t{T(hints.get(p.name, empty))}\t{k}\t{lit(p.default)}")
    print(f"result\t{T(hints['return']) if 'return' in hints else 'void'}")
    print("end")


for n, c in sorted(classes.items()):
    if issubclass(c, enum.Enum):
        members = list(c)
        ints = all(isinstance(m.value, int) and not isinstance(m.value, bool) for m in members)
        print(f"class\t{n}\tenum")
        for i, m in enumerate(members):
            print(f"value\t{m.name}\t{m.value if ints else i}")
        print("end")
        continue
    print(f"class\t{n}\tclass")
    for b in c.__mro__[1:]:
        if classes.get(b.__name__) is b:
            print(f"super\t{b.__name__}")
    if c.__init__ is object.__init__:
        print("func\tnew\tctor\nresult\tvoid\nend")
    else:
        func("new", "ctor", c.__init__, True)
    seen = set()
    for mn in sorted(dir(c)):
        if mn.startswith("_"):
            continue
        a = inspect.getattr_static(c, mn)
        if isinstance(a, staticmethod):
            func(mn, "static", a.__func__, False)
        elif isinstance(a, classmethod):
            func(mn, "static", a.__func__, True)
        elif inspect.isfunction(a):
            func(mn, "inst", a, True)
        elif isinstance(a, property):
            try:
                t = T(typing.get_type_hints(a.fget).get("return", empty))
            except Exception:
                t = "other"
            print(f"attr\t{mn}\t{t}\t{'rw' if a.fset else 'ro'}")
        else:
            continue
        seen.add(mn)
    try:
        hints = typing.get_type_hints(c)
    except Exception:
        hints = {}
    for an, at in sorted(hints.items()):
        if not an.startswith("_") and an not in seen and typing.get_origin(at) is not typing.ClassVar:
            print(f"attr\t{an}\t{T(at)}\trw")
    print("end")

for n, f in sorted(vars(M).items()):
    if not exported(n):
        continue
    if inspect.isfunction(f) and f.__module__ == M.__name__:
        func(n, "fn", f, False)
    elif n.isupper() and type(f) in (int, float, bool, str) and lit(f) != "-":
        print(f"const\t{n}\t{prims[type(f)]}\t{lit(f)}")
"#;

struct Param {
    name: String,
    ty: String,
    kw: bool,
    default: Option<String>,
}

struct Func {
    name: String,
    kind: String,
    params: Vec<Param>,
    ret: String,
}

#[derive(Default)]
struct Class {
    name: String,
    is_enum: bool,
    supers: Vec<String>,
    values: Vec<(String, i128)>,
    funcs: Vec<Func>,
    attrs: Vec<(String, String, bool)>,
}

#[derive(Default)]
struct Items {
    classes: Vec<Class>,
    funcs: Vec<Func>,
    consts: Vec<(String, String, String)>,
}

/// DESCRIBE's output, and what can't be used at all
fn read(desc: &str) -> (Items, Vec<String>) {
    let rows: Vec<Vec<&str>> = desc.lines().map(|l| l.split('\t').collect()).collect();
    let (mut items, mut left) = (Items::default(), Vec::new());
    let mut cur: Option<Class> = None;
    let mut i = 0;
    while i < rows.len() {
        let f = &rows[i];
        i += 1;
        match (f[0], f.len()) {
            ("class", 3) => cur = Some(Class { name: f[1].to_string(), is_enum: f[2] == "enum", ..Class::default() }),
            ("super", 2) => cur.iter_mut().for_each(|c| c.supers.push(f[1].to_string())),
            ("value", 3) => {
                if let (Some(c), Ok(n)) = (cur.as_mut(), f[2].parse()) {
                    c.values.push((f[1].to_string(), n));
                }
            }
            ("attr", 4) => cur.iter_mut().for_each(|c| c.attrs.push((f[1].to_string(), f[2].to_string(), f[3] == "rw"))),
            ("func", 3) => {
                let mut func = Func { name: f[1].to_string(), kind: f[2].to_string(), params: vec![], ret: "void".into() };
                while i < rows.len() && rows[i][0] != "end" {
                    let r = &rows[i];
                    match (r[0], r.len()) {
                        ("param", 5) => func.params.push(Param { name: r[1].to_string(), ty: r[2].to_string(), kw: r[3] == "kw", default: (r[4] != "-").then(|| r[4].to_string()) }),
                        ("result", 2) => func.ret = r[1].to_string(),
                        _ => {}
                    }
                    i += 1;
                }
                i += 1;
                match cur.as_mut() {
                    Some(c) => c.funcs.push(func),
                    None => items.funcs.push(func),
                }
            }
            ("end", _) => items.classes.extend(cur.take()),
            ("const", 4) => items.consts.push((f[1].to_string(), f[2].to_string(), f[3].to_string())),
            ("other", n) if n >= 3 => left.push(format!("{} ({})", f[1], f[2..].join(" "))),
            _ => {}
        }
    }
    (items, left)
}

/// a Python type as Volt sees it
#[derive(Clone, PartialEq, Debug)]
enum PT {
    Void,
    /// int, float, bool, str, bytes
    Prim(&'static str),
    /// a list of int, float, bool or str
    List(&'static str),
    Opt(&'static str),
    Obj(String),
    Enum(String),
}

fn prim(s: &str) -> Option<&'static str> {
    ["int", "float", "bool", "str", "bytes"].into_iter().find(|x| *x == s)
}

/// the Volt type of a Python int, float, bool, str (in), bytes (in)
fn volt_prim(p: &str) -> &'static str {
    match p {
        "int" => "i64",
        "float" => "f64",
        "bool" => "bool",
        "str" => "str",
        _ => "u8[..]",
    }
}

struct Gen<'a> {
    alias: &'a str,
    enums: BTreeSet<String>,
    objs: BTreeSet<String>,
}

impl Gen<'_> {
    fn pt(&self, s: &str) -> Option<PT> {
        if s == "void" {
            return Some(PT::Void);
        }
        if let Some(e) = s.strip_suffix("[]") {
            return Some(PT::List(prim(e).filter(|p| *p != "bytes")?));
        }
        if let Some(e) = s.strip_suffix('?') {
            if let Some(c) = e.strip_prefix("cls:") {
                return self.objs.contains(c).then(|| PT::Obj(c.to_string()));
            }
            return Some(PT::Opt(prim(e).filter(|p| *p != "bytes")?));
        }
        if let Some(c) = s.strip_prefix("cls:") {
            if self.enums.contains(c) {
                return Some(PT::Enum(c.to_string()));
            }
            return self.objs.contains(c).then(|| PT::Obj(c.to_string()));
        }
        Some(PT::Prim(prim(s)?))
    }

    fn ty_in(t: &PT) -> String {
        match t {
            PT::Prim(p) => volt_prim(p).into(),
            PT::List(p) => format!("{}[..]", volt_prim(p)),
            PT::Opt(p) => format!("{}?", if *p == "bytes" { "std::vec<u8>" } else { volt_prim(p) }),
            PT::Obj(n) => format!("{n}&"),
            PT::Enum(n) => n.clone(),
            PT::Void => "void".into(),
        }
    }

    fn ty_out(t: &PT) -> String {
        let one = |p: &str| match p {
            "str" => "std::string".to_string(),
            "bytes" => "std::vec<u8>".to_string(),
            p => volt_prim(p).to_string(),
        };
        match t {
            PT::Prim(p) => one(p),
            PT::List(p) => format!("std::vec<{}>", one(p)),
            PT::Opt(p) => format!("{}?", one(p)),
            PT::Obj(n) => n.clone(),
            t => Self::ty_in(t),
        }
    }

    /// Volt value v as a new Python reference (statements before, the expression, statements after
    /// the call that read Python's changes back)
    fn to_py(t: &PT, v: &str) -> (Vec<String>, String, Vec<String>) {
        match t {
            PT::Prim(p) => (vec![], format!("py_rt::of_{p}({v})"), vec![]),
            // the list stays ours until the call is over: its items come back
            PT::List(p) => (vec![format!("val {v}_l = py_rt::tmp_of(py_rt::of_{p}s({v}));")], format!("py_rt::incref({v}_l.p)"), vec![format!("py_rt::back_{p}s({v}_l.p, {v});")]),
            PT::Opt(p) => (vec![], format!("py_rt::of_opt_{p}({v})"), vec![]),
            PT::Obj(_) => (vec![], format!("py_rt::of_obj({v}.o.p)"), vec![]),
            PT::Enum(n) => (vec![], format!("py_rt::to_{n}({v})"), vec![]),
            PT::Void => (vec![], "py_rt::of_obj(null)".into(), vec![]),
        }
    }

    /// the statements returning Python result p_r (a py_rt::tmp) as Volt's
    fn result(t: &PT) -> Vec<String> {
        match t {
            PT::Void => vec![],
            PT::Prim(p) => vec![format!("return py_rt::to_{p}(p_r.p);")],
            PT::List(p) => vec![format!("return py_rt::to_{p}s(p_r.p);")],
            PT::Opt(p) => vec![format!("if (p_r.p == py_rt::none()) {{"), "    return null;".into(), "}".into(), format!("return py_rt::to_{p}(p_r.p);")],
            PT::Obj(n) => vec![format!("val p_v: {n} = {{ o: py_rt::keep(&p_r) }};"), "return p_v;".into()],
            PT::Enum(n) => vec![format!("return py_rt::of_{n}(p_r.p);")],
        }
    }

    /// a parameter's Volt name, apart from the glue's locals (p_g, p_r...)
    fn param_name(n: &str) -> String {
        let n = volt_name(n);
        if n.starts_with("p_") || n == "this" {
            format!("{n}_")
        } else {
            n
        }
    }

    /// a function, constructor or method as Volt, or why it's left out. target: the Python
    /// expression of what's called (a new reference)
    fn func(&self, cls: Option<&str>, f: &Func, seen: &mut BTreeSet<String>) -> Result<String, String> {
        let what = match cls {
            Some(c) => format!("{c}.{}", f.name),
            None => f.name.clone(),
        };
        let ret = if f.kind == "ctor" { PT::Obj(cls.unwrap_or_default().to_string()) } else { self.pt(&f.ret).ok_or(format!("{what} (its return type)"))? };
        let (mut params, mut pre, mut pos, mut kw, mut post) = (Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new());
        for p in &f.params {
            if p.ty == "none" {
                return Err(format!("{what} (parameter {} has no type annotation)", p.name));
            }
            let t = self.pt(&p.ty).ok_or(format!("{what} (parameter {}'s type)", p.name))?;
            let vn = Self::param_name(&p.name);
            let default = match (&p.default, &t) {
                (Some(d), PT::Prim(pr)) if *pr != "bytes" && (d != "null") => format!(" = {d}"),
                (Some(d), PT::Opt(pr)) if *pr != "bytes" => format!(" = {d}"),
                _ => String::new(),
            };
            params.push(format!("{vn}: {}{default}", Self::ty_in(&t)));
            let (p0, e, p1) = Self::to_py(&t, &vn);
            pre.extend(p0);
            post.extend(p1);
            if p.kw {
                kw.push((p.name.clone(), e));
            } else {
                pos.push(e);
            }
        }
        let vn = if f.kind == "ctor" { "new".to_string() } else { volt_name(&f.name) };
        let is_static = f.kind != "inst";
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
        let mut l = vec!["val p_g = py_rt::enter();".to_string()];
        let target = match (cls, f.kind.as_str()) {
            (None, _) => format!("py_rt::attr(py_rt::module(), \"{}\")", f.name),
            (Some(c), "ctor") => format!("py_rt::attr(py_rt::module(), \"{c}\")"),
            (Some(c), "static") => {
                l.push(format!("val p_c = py_rt::tmp_of(py_rt::attr(py_rt::module(), \"{c}\"));"));
                format!("py_rt::attr(p_c.p, \"{}\")", f.name)
            }
            (Some(c), _) => {
                l.push(format!("py_rt::live(this.o.p, \"{}::{c}\");", self.alias));
                format!("py_rt::attr(this.o.p, \"{}\")", f.name)
            }
        };
        l.push(format!("val p_f = py_rt::tmp_of({target});"));
        l.extend(pre);
        l.push(format!("val p_a = py_rt::tmp_of(py_rt::tuple({}));", pos.len()));
        for (i, e) in pos.iter().enumerate() {
            l.push(format!("py_rt::put(p_a.p, {i}, {e});"));
        }
        let kws = if kw.is_empty() {
            "null".to_string()
        } else {
            l.push("val p_k = py_rt::tmp_of(py_rt::dict());".into());
            for (k, e) in &kw {
                l.push(format!("py_rt::kw(p_k.p, \"{k}\", {e});"));
            }
            "p_k.p".to_string()
        };
        l.push(format!("var p_r = py_rt::call(p_f.p, p_a.p, {kws});"));
        l.extend(post);
        l.extend(Self::result(&ret));
        Ok(func(&head, &l))
    }

    /// an attribute's getter and (unless read-only) setter
    fn attr(&self, c: &str, (name, ty, rw): &(String, String, bool), taken: &BTreeSet<String>) -> Result<String, String> {
        let what = format!("{c}.{name}");
        let t = self.pt(ty).filter(|t| *t != PT::Void).ok_or(format!("{what} (its type)"))?;
        let vn = volt_name(name);
        if taken.contains(&vn) {
            return Err(format!("{what} (a method has its name)"));
        }
        let start = vec!["val p_g = py_rt::enter();".to_string(), format!("py_rt::live(this.o.p, \"{}::{c}\");", self.alias)];
        let mut get = start.clone();
        get.push(format!("var p_r = py_rt::tmp_of(py_rt::attr(this.o.p, \"{name}\"));"));
        get.extend(Self::result(&t));
        let mut out = func(&format!("attach fn {vn}(this: {c}&) -> {}", Self::ty_out(&t)), &get);
        if *rw && !taken.contains(&format!("set_{vn}")) {
            let (pre, e, _) = Self::to_py(&t, "v");
            let mut set = start;
            set.extend(pre);
            set.push(format!("py_rt::set_attr(this.o.p, \"{name}\", {e});"));
            let _ = write!(out, "\n{}", func(&format!("attach fn set_{vn}(this: {c}&, v: {}) -> void", Self::ty_in(&t)), &set));
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

/// the Volt side: py_rt, then the module's classes, enums, functions and constants
fn generate(alias: &str, items: &Items, mut left: Vec<String>, dir: &Path, module: &str, header: &Path) -> String {
    let g = Gen {
        alias,
        enums: items.classes.iter().filter(|c| c.is_enum).map(|c| c.name.clone()).collect(),
        objs: items.classes.iter().filter(|c| !c.is_enum && c.name != "py_rt").map(|c| c.name.clone()).collect(),
    };
    let mut decls = String::new();
    let mut helpers = String::new();
    for c in &items.classes {
        if c.is_enum {
            let mut body = String::new();
            let mut to = format!("    fn to_{}(x: {alias}::{}) -> py::PyObject* {{\n        val c = tmp_of(attr(module(), \"{}\"));\n        match (x) {{\n", c.name, c.name, c.name);
            let mut of = format!("    fn of_{}(o: py::PyObject*) -> {alias}::{} {{\n        val n = tmp_of(attr(o, \"name\"));\n        val s = to_str(n.p);\n", c.name, c.name);
            for (v, n) in &c.values {
                let vv = volt_name(v);
                let _ = writeln!(body, "    {vv} = {n},");
                let _ = writeln!(to, "            .{vv} => {{ return attr(c.p, \"{v}\"); }},");
                let _ = writeln!(of, "        if (s.as_str() == \"{v}\") {{\n            return {alias}::{}::{vv};\n        }}", c.name);
            }
            to.push_str("        }\n    }\n");
            let _ = write!(of, "        @panic(std::fmt::format(\"Python gave back a {} that isn't one: {{}}\", s.as_str()).as_str());\n    }}\n", c.name);
            helpers.push_str(&to);
            helpers.push_str(&of);
            let _ = write!(decls, "\n// the Python enum {module}.{}\nenum {}: i64 {{\n{body}}}\n", c.name, c.name);
            continue;
        }
        if c.name == "py_rt" {
            left.push("py_rt (the glue's own name)".into());
            continue;
        }
        let n = &c.name;
        let _ = write!(decls, "\n// the Python class {module}.{n}: a reference to an object (a copy refers to the same one)\nstruct {n} {{\n    o: py_rt::ref = {{}};\n}}\n\nattach fn is_null(this: {n}&) -> bool {{\n    return this.o.p == null;\n}}\n");
        for s in &c.supers {
            if g.objs.contains(s) {
                let _ = write!(decls, "\n// as a {s}: the same object\nattach fn as_{s}(this: {n}&) -> {s} {{\n    return {{ o: copy this.o }};\n}}\n");
            }
        }
        let mut seen = BTreeSet::new();
        let taken: BTreeSet<String> = c.funcs.iter().map(|f| volt_name(&f.name)).collect();
        for f in &c.funcs {
            match g.func(Some(n), f, &mut seen) {
                Ok(t) => {
                    let _ = write!(decls, "\n{t}");
                }
                Err(why) => left.push(why),
            }
        }
        for a in &c.attrs {
            match g.attr(n, a, &taken) {
                Ok(t) => {
                    let _ = write!(decls, "\n{t}");
                }
                Err(why) => left.push(why),
            }
        }
    }
    let mut seen = BTreeSet::new();
    for f in &items.funcs {
        match g.func(None, f, &mut seen) {
            Ok(t) => {
                let _ = write!(decls, "\n{t}");
            }
            Err(why) => left.push(why),
        }
    }
    for (n, t, v) in &items.consts {
        let vt = match t.as_str() {
            "int" => "i64",
            "float" => "f64",
            "bool" => "bool",
            _ => "str",
        };
        let _ = write!(decls, "\nval {}: {vt} = {v};\n", volt_name(n));
    }
    let q = |s: &str| s.replace('\\', "\\\\").replace('"', "\\\"");
    let mut rt = RUNTIME.replace("{PYH}", &q(&header.display().to_string())).replace("{DIR}", &q(&dir.display().to_string())).replace("{MODULE}", &q(module));
    rt.push_str(&lists());
    let mut volt = format!("// use python {{ ... }} as {alias}: module {module}'s public API, called through Python's C API (written by bolt import)\n\nnamespace py_rt {{\n{rt}\n{helpers}}}\n");
    volt.push_str(&decls);
    if !left.is_empty() {
        volt.push_str("\n// left out (Volt can't call these):\n");
        for l in &left {
            let _ = writeln!(volt, "//   {l}");
        }
    }
    volt
}

/// py_rt: the interpreter, the GIL, references, exceptions, calls, conversions
const RUNTIME: &str = r#"    use { "{PYH}" } as py;

    // the GIL for a call; Python starts the first time (or the interpreter running is used), and
    // lets go of the GIL between calls so other threads can call too
    struct gil {
        s: py::PyGILState_STATE = py::PyGILState_LOCKED;
    }

    fn enter() -> gil {
        if (py::Py_IsInitialized() == 0) {
            py::Py_InitializeEx(0); // 0: the program's signal handlers stay
            py::PyEval_SaveThread();
        }
        return { s: py::PyGILState_Ensure() };
    }

    attach fn delete(this: gil&) -> void {
        py::PyGILState_Release(this.s);
    }

    // the module, imported once (its directory goes on sys.path)
    var module_ref: py::PyObject* = null;

    fn module() -> py::PyObject* {
        if (module_ref == null) {
            val path = py::PySys_GetObject("path");
            val d = tmp_of(of_str("{DIR}"));
            if (path != null) {
                py::PyList_Insert(path, 0, d.p);
            }
            var name = std::string::from("{MODULE}");
            module_ref = py::PyImport_ImportModule(name.c_str());
            thrown();
        }
        return module_ref;
    }

    // a reference to a Python object a Volt value holds: a copy refers to the same object
    struct ref {
        p: py::PyObject* = null;
    }

    attach fn delete(this: ref&) -> void {
        if (this.p != null) {
            val g = enter();
            py::Py_DecRef(this.p);
            this.p = null;
        }
    }

    attach fn copy(this: ref&) -> ref {
        if (this.p == null) {
            return {};
        }
        val g = enter();
        py::Py_IncRef(this.p);
        return { p: this.p };
    }

    // a new reference for one call (the GIL held), dropped at the end of it
    struct tmp {
        p: py::PyObject* = null;
    }

    attach fn delete(this: tmp&) -> void {
        if (this.p != null) {
            py::Py_DecRef(this.p);
        }
    }

    fn tmp_of(p: py::PyObject*) -> tmp {
        thrown();
        return { p: p };
    }

    // the result's reference, for a Volt value to hold; None is an empty one
    fn keep(t: tmp&) -> ref {
        val p = t.p;
        t.p = null;
        if (p == none()) {
            py::Py_DecRef(p);
            return {};
        }
        return { p: p };
    }

    fn incref(p: py::PyObject*) -> py::PyObject* {
        py::Py_IncRef(p);
        return p;
    }

    fn live(p: py::PyObject*, what: str) -> void {
        if (p == null) {
            @panic(std::fmt::format("{} is empty: Python never made it, or gave back None", what).as_str());
        }
    }

    // a Python exception: the program stops with its type and message
    fn thrown() -> void {
        if (py::PyErr_Occurred() == null) {
            return;
        }
        val e = tmp_of_raw(py::PyErr_GetRaisedException());
        var msg = std::string::from("a Python exception");
        val cls = tmp_of_raw(py::PyObject_Type(e.p));
        val ty = tmp_of_raw(py::PyObject_GetAttrString(cls.p, "__name__"));
        val text = tmp_of_raw(py::PyObject_Str(e.p));
        if (ty.p != null && text.p != null) {
            msg = std::fmt::format("{}: {}", raw_str(ty.p).as_str(), raw_str(text.p).as_str());
        }
        py::PyErr_Clear();
        @panic(msg.as_str());
    }

    fn tmp_of_raw(p: py::PyObject*) -> tmp {
        return { p: p };
    }

    fn raw_str(o: py::PyObject*) -> std::string {
        var n: isize = 0;
        val p = py::PyUnicode_AsUTF8AndSize(o, &n) ?? return std::string::from("");
        return std::string::from(@cast<str>(@slice(@cast<u8*>(p), @cast<usize>(n))));
    }

    fn none() -> py::PyObject* {
        return py::Py_GetConstantBorrowed(@cast<u32>(py::Py_CONSTANT_NONE));
    }

    fn attr(o: py::PyObject*, name: str) -> py::PyObject* {
        var n = std::string::from(name);
        val r = py::PyObject_GetAttrString(o, n.c_str());
        thrown();
        return r;
    }

    fn set_attr(o: py::PyObject*, name: str, v: py::PyObject*) -> void {
        var n = std::string::from(name);
        val x = tmp_of(v);
        py::PyObject_SetAttrString(o, n.c_str(), x.p);
        thrown();
    }

    fn tuple(n: usize) -> py::PyObject* {
        return py::PyTuple_New(@cast<isize>(n));
    }

    // a new reference into a tuple (it takes it)
    fn put(t: py::PyObject*, i: usize, v: py::PyObject*) -> void {
        thrown();
        py::PyTuple_SetItem(t, @cast<isize>(i), v);
    }

    fn dict() -> py::PyObject* {
        return py::PyDict_New();
    }

    fn kw(d: py::PyObject*, name: str, v: py::PyObject*) -> void {
        var n = std::string::from(name);
        val x = tmp_of(v);
        py::PyDict_SetItemString(d, n.c_str(), x.p);
    }

    fn call(f: py::PyObject*, args: py::PyObject*, kws: py::PyObject*) -> tmp {
        val r = py::PyObject_Call(f, args, kws);
        thrown();
        return { p: r };
    }

    fn of_obj(p: py::PyObject*) -> py::PyObject* {
        if (p == null) {
            return incref(none());
        }
        return incref(p);
    }

    fn of_int(x: i64) -> py::PyObject* {
        return py::PyLong_FromLongLong(x);
    }

    fn of_float(x: f64) -> py::PyObject* {
        return py::PyFloat_FromDouble(x);
    }

    fn of_bool(x: bool) -> py::PyObject* {
        if (x) {
            return py::PyBool_FromLong(1);
        }
        return py::PyBool_FromLong(0);
    }

    fn of_str(s: str) -> py::PyObject* {
        return py::PyUnicode_FromStringAndSize(@cast<cstr>(s.ptr), @cast<isize>(s.len));
    }

    fn of_bytes(xs: u8[..]) -> py::PyObject* {
        return py::PyBytes_FromStringAndSize(@cast<cstr>(xs.ptr), @cast<isize>(xs.len));
    }

    fn to_int(o: py::PyObject*) -> i64 {
        val r = py::PyLong_AsLongLong(o);
        thrown();
        return r;
    }

    fn to_float(o: py::PyObject*) -> f64 {
        val r = py::PyFloat_AsDouble(o);
        thrown();
        return r;
    }

    fn to_bool(o: py::PyObject*) -> bool {
        val r = py::PyObject_IsTrue(o);
        thrown();
        return r != 0;
    }

    fn to_str(o: py::PyObject*) -> std::string {
        var n: isize = 0;
        val p = py::PyUnicode_AsUTF8AndSize(o, &n);
        thrown();
        val q = p ?? return std::string::from("");
        return std::string::from(@cast<str>(@slice(@cast<u8*>(q), @cast<usize>(n))));
    }

    fn to_bytes(o: py::PyObject*) -> std::vec<u8> {
        var p: cstr? = null;
        var n: isize = 0;
        py::PyBytes_AsStringAndSize(o, &p, &n);
        thrown();
        var out: std::vec<u8> = {};
        val q = p ?? return out;
        if (n > 0) {
            for (x) in @slice(@cast<u8*>(q), @cast<usize>(n)) {
                out.push(x) catch @panic("out of memory");
            }
        }
        return out;
    }
"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn import_python_read() {
        let desc = "class\tColor\tenum\nvalue\tRED\t1\nend\nclass\tShape\tclass\nsuper\tBase\nfunc\tnew\tctor\nparam\tname\tstr\tpos\t-\nresult\tvoid\nend\nattr\tcount\tint\tro\nend\nfunc\tfind\tfn\nparam\txs\tint[]\tpos\t-\nparam\tloud\tbool\tkw\tfalse\nresult\tint?\nend\nconst\tLIMIT\tint\t10\nother\tapply\tits signature can't be read\n";
        let (items, left) = read(desc);
        assert_eq!(items.classes.iter().map(|c| (c.name.as_str(), c.is_enum)).collect::<Vec<_>>(), [("Color", true), ("Shape", false)]);
        assert_eq!(items.classes[0].values, [("RED".to_string(), 1)]);
        assert_eq!(items.classes[1].supers, ["Base"]);
        assert_eq!(items.classes[1].attrs, [("count".to_string(), "int".to_string(), false)]);
        let f = &items.funcs[0];
        assert_eq!((f.name.as_str(), f.ret.as_str(), f.params[1].kw, f.params[1].default.as_deref()), ("find", "int?", true, Some("false")));
        assert_eq!(items.consts, [("LIMIT".to_string(), "int".to_string(), "10".to_string())]);
        assert_eq!(left, ["apply (its signature can't be read)"]);
        let g = Gen { alias: "geom", enums: ["Color".to_string()].into(), objs: ["Shape".to_string()].into() };
        assert_eq!(g.pt("int[]"), Some(PT::List("int")));
        assert_eq!(g.pt("str?"), Some(PT::Opt("str")));
        assert_eq!(g.pt("cls:Shape?"), Some(PT::Obj("Shape".into())));
        assert_eq!(g.pt("cls:Color"), Some(PT::Enum("Color".into())));
        assert_eq!(g.pt("bytes[]"), None);
        assert_eq!(g.pt("other"), None);
    }
}

/// py_rt's list conversions, for each element type: of_Ts (a new list), back_Ts (Python's changes
/// back in Volt's elements), to_Ts (a sequence as a vec), and the optionals
fn lists() -> String {
    let mut s = String::new();
    for (p, vt, ot) in [("int", "i64", "i64"), ("float", "f64", "f64"), ("bool", "bool", "bool"), ("str", "str", "std::string")] {
        let _ = write!(
            s,
            "    fn of_{p}s(xs: {vt}[..]) -> py::PyObject* {{\n        val l = py::PyList_New(@cast<isize>(xs.len));\n        for (i) in 0..xs.len {{\n            py::PyList_SetItem(l, @cast<isize>(i), of_{p}(xs[i]));\n        }}\n        return l;\n    }}\n    fn to_{p}s(o: py::PyObject*) -> std::vec<{ot}> {{\n        var out: std::vec<{ot}> = {{}};\n        val n = py::PySequence_Size(o);\n        thrown();\n        for (i) in 0..n {{\n            val x = tmp_of(py::PySequence_GetItem(o, i));\n            out.push(to_{p}(x.p)) catch @panic(\"out of memory\");\n        }}\n        return out;\n    }}\n    fn of_opt_{p}(x: {vt}?) -> py::PyObject* {{\n        if (x) {{\n            return of_{p}(x);\n        }}\n        return of_obj(null);\n    }}\n"
        );
        // a str list's items can't come back into Volt's str[..] (Python's strings are new ones).
        // The others do, element by element and only what changed: an argument Python leaves
        // alone may be a val
        if p == "str" {
            let _ = write!(s, "    fn back_strs(l: py::PyObject*, xs: str[..]) -> void {{}}\n");
        } else {
            let _ = write!(
                s,
                "    fn back_{p}s(l: py::PyObject*, xs: {vt}[..]) -> void {{\n        if (py::PyList_Size(l) != @cast<isize>(xs.len)) {{\n            return;\n        }}\n        val m = @slice(@cast<{vt}*>(xs.ptr), xs.len);\n        for (i) in 0..xs.len {{\n            val x = to_{p}(py::PyList_GetItem(l, @cast<isize>(i)));\n            if (m[i] != x) {{\n                m[i] = x;\n            }}\n        }}\n    }}\n"
            );
        }
    }
    s
}
