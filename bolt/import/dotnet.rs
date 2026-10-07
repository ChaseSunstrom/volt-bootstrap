// use { "Geom.cs" } as NAME; (or "Lib.dll") — .NET called from Volt. bolt builds the C# sources into
// a library with dotnet build, asks .NET itself what it exports (DESCRIBE: reflection, run with
// dotnet), and writes a C# shim of [UnmanagedCallersOnly] methods (objects as GCHandles) and the
// Volt side (glue.rs). The program has no link-time symbols for it: the shim's methods are found
// through hostfxr the first time each is called, which starts .NET (or uses the runtime the process
// has). Nothing in the .NET code changes.
//
//   bool, sbyte..ulong, float, double -> the same; char -> u32; string -> str in, std::string out;
//   T[] -> T[..] in (what .NET changes in it comes back), std::vec<T> out; int? -> i32?
//   a struct whose fields are all public (not readonly) numbers, bools, enums or such structs -> a
//   Volt struct, by value; a class, interface or any other struct -> a handle (a GCHandle: .NET's
//   collector keeps the object while Volt holds it; a copy refers to the same object)
//   constructors -> T::new(...); properties and public fields -> X() and set_X(v); as_B() for each
//   imported base class or interface B; an enum -> a Volt enum with the same values
//   an exception -> the program stops with its text (.NET declares none to make an error of)
use super::glue::{Gen, Kind, Lang, Model, Recv, ShimOut, ShimParam, Sig, Ty, TypeDef, TypeInfo};
use super::{arg_path, fresh, save, stamp, Made, Req};
use std::collections::BTreeMap;
use std::fmt::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn import(r: &Req) -> Result<(), String> {
    let (mut sources, mut dll) = (Vec::new(), None);
    for a in &r.args {
        let p = arg_path(r, a);
        let ext = p.extension().map(|e| e.to_string_lossy().to_ascii_lowercase()).unwrap_or_default();
        match (p.is_file(), ext.as_str()) {
            (true, "cs") => sources.push(p),
            (true, "dll") if dll.is_none() => dll = Some(p),
            (true, "dll") => return Err(format!("use dotnet {{ ... }} as {}: one assembly an import", r.alias)),
            _ => return Err(format!("use dotnet: there's no {} (name .cs sources or one .dll)", p.display())),
        }
    }
    if sources.is_empty() == dll.is_none() {
        return Err(format!("use dotnet {{ ... }} as {}: name C# sources, or one .dll", r.alias));
    }
    let dotnet = dotnet()?;
    let mut files = sources.clone();
    files.extend(dll.clone());
    let st = stamp(&files, &format!("dotnet {} {} release={}", r.alias, dotnet.display(), r.release));
    if fresh(r, &st) {
        return Ok(());
    }
    let out = {
        std::fs::create_dir_all(&r.out).map_err(|e| format!("can't make {}: {e}", r.out.display()))?;
        std::fs::canonicalize(&r.out).unwrap_or_else(|_| r.out.clone())
    };
    let id: String = out.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect();
    let (version, root) = runtime(&dotnet)?;
    let tfm = format!("net{}.0", version.split('.').next().unwrap_or("10"));

    // the sources, as a library
    let user = match dll {
        Some(d) => d,
        None => {
            let name = format!("volt_user_{id}");
            let dir = out.join("user");
            let compile: String = sources.iter().map(|s| format!("    <Compile Include=\"{}\" />\n", xml(&s.display().to_string()))).collect();
            let proj = format!("<Project Sdk=\"Microsoft.NET.Sdk\">\n  <PropertyGroup>\n    <TargetFramework>{tfm}</TargetFramework>\n    <AssemblyName>{name}</AssemblyName>\n    <ImplicitUsings>enable</ImplicitUsings>\n    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>\n  </PropertyGroup>\n  <ItemGroup>\n{compile}  </ItemGroup>\n</Project>\n");
            build(&dotnet, &dir, "User.csproj", &proj, "the sources")?;
            dir.join("bin").join(format!("{name}.dll"))
        }
    };

    // what it exports
    let d = out.join("describe");
    let proj = format!("<Project Sdk=\"Microsoft.NET.Sdk\">\n  <PropertyGroup>\n    <OutputType>Exe</OutputType>\n    <TargetFramework>{tfm}</TargetFramework>\n    <Nullable>disable</Nullable>\n  </PropertyGroup>\n</Project>\n");
    crate::build::write_if_changed(&d.join("Describe.cs"), DESCRIBE)?;
    build(&dotnet, &d, "Describe.csproj", &proj, "bolt's assembly reader")?;
    let o = dotnet_cmd(&dotnet).arg(d.join("bin").join("Describe.dll")).arg(&user).output().map_err(|e| format!("use dotnet: can't run {}: {e}", dotnet.display()))?;
    if !o.status.success() {
        return Err(format!("use dotnet: can't read {}:\n{}", user.display(), String::from_utf8_lossy(&o.stderr)));
    }
    let (model, lang) = read(&String::from_utf8_lossy(&o.stdout));

    // the shim, beside the library it calls
    let shim_name = format!("volt_shim_{id}");
    let dir = out.join("shim");
    let lang = Dotnet { asm: dir.join("bin").join(format!("{shim_name}.dll")), asm_name: shim_name.clone(), ..lang };
    let (shim, volt) = Gen::new(&model, &r.alias, &lang).write("the assembly");
    crate::build::write_if_changed(&dir.join("Shim.cs"), &(shim + "}\n"))?;
    let user_name = user.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let proj = format!("<Project Sdk=\"Microsoft.NET.Sdk\">\n  <PropertyGroup>\n    <TargetFramework>{tfm}</TargetFramework>\n    <AssemblyName>{shim_name}</AssemblyName>\n    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>\n    <EnableDynamicLoading>true</EnableDynamicLoading>\n    <Nullable>disable</Nullable>\n  </PropertyGroup>\n  <ItemGroup>\n    <Reference Include=\"{}\">\n      <HintPath>{}</HintPath>\n    </Reference>\n  </ItemGroup>\n</Project>\n", xml(&user_name), xml(&user.display().to_string()));
    build(&dotnet, &dir, "Shim.csproj", &proj, "the glue")?;

    let fxr = fxr_dir(&root, &version)?;
    let flags = vec![format!("-L{}", fxr.display()), format!("-Wl,-rpath,{}", fxr.display()), "-lhostfxr".to_string()];
    save(r, &Made { volt, flags, deps: files }, &st)
}

/// the dotnet command: $DOTNET, else $DOTNET_ROOT/dotnet, else dotnet on PATH
fn dotnet() -> Result<PathBuf, String> {
    if let Some(d) = std::env::var_os("DOTNET") {
        return Ok(PathBuf::from(d));
    }
    if let Some(r) = std::env::var_os("DOTNET_ROOT") {
        return Ok(Path::new(&r).join("dotnet"));
    }
    let path = std::env::var_os("PATH").unwrap_or_default();
    std::env::split_paths(&path).map(|d| d.join("dotnet")).find(|p| p.is_file()).ok_or_else(|| "use dotnet: there's no dotnet: install .NET, or set $DOTNET to it".to_string())
}

fn dotnet_cmd(dotnet: &Path) -> Command {
    let mut c = Command::new(dotnet);
    c.env("DOTNET_CLI_TELEMETRY_OPTOUT", "1").env("DOTNET_NOLOGO", "1").env("DOTNET_SKIP_FIRST_TIME_EXPERIENCE", "1");
    c
}

/// the newest Microsoft.NETCore.App runtime: its version and the install's root
fn runtime(dotnet: &Path) -> Result<(String, PathBuf), String> {
    let o = dotnet_cmd(dotnet).arg("--list-runtimes").output().map_err(|e| format!("use dotnet: can't run {}: {e}", dotnet.display()))?;
    // Microsoft.NETCore.App 10.0.12 [/opt/dotnet/shared/Microsoft.NETCore.App]
    String::from_utf8_lossy(&o.stdout)
        .lines()
        .filter_map(|l| {
            let rest = l.trim().strip_prefix("Microsoft.NETCore.App ")?;
            let (v, p) = rest.split_once(" [")?;
            let root = p.strip_suffix(']')?.strip_suffix("/shared/Microsoft.NETCore.App")?;
            Some((v.to_string(), PathBuf::from(root)))
        })
        .last()
        .ok_or_else(|| format!("use dotnet: {} --list-runtimes lists no Microsoft.NETCore.App", dotnet.display()))
}

/// hostfxr's directory: host/fxr/VERSION, else the one there is
fn fxr_dir(root: &Path, version: &str) -> Result<PathBuf, String> {
    let d = root.join("host").join("fxr").join(version);
    if d.is_dir() {
        return Ok(d);
    }
    let mut all: Vec<PathBuf> = std::fs::read_dir(root.join("host").join("fxr")).map(|rd| rd.flatten().map(|e| e.path()).collect()).unwrap_or_default();
    all.sort();
    all.pop().ok_or_else(|| format!("use dotnet: there's no hostfxr under {}", root.join("host/fxr").display()))
}

/// writes project proj into dir and builds it into dir/bin
fn build(dotnet: &Path, dir: &Path, proj_file: &str, proj: &str, what: &str) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("can't make {}: {e}", dir.display()))?;
    crate::build::write_if_changed(&dir.join(proj_file), proj)?;
    let o = dotnet_cmd(dotnet).args(["build", proj_file, "-c", "Release", "--nologo", "-v", "q", "-o", "bin"]).current_dir(dir).output().map_err(|e| format!("use dotnet: can't run {}: {e}", dotnet.display()))?;
    if !o.status.success() {
        return Err(format!("use dotnet: dotnet couldn't build {what}:\n{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr)));
    }
    Ok(())
}

fn xml(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// a C# program printing what an assembly's public types have, a declaration a line (tab-separated):
///   type FULLNAME class|abstract|static|interface|struct|enum, then super FULLNAME (an imported
///   base or interface), value NAME N (an enum's), field NAME settable TYPE (a struct's instance
///   fields, in order), func NAME KIND (KIND: ctor, inst, static, get, sget, set, sset, cast) with
///   param NAME TYPE and result TYPE lines and end; end
///   other NAME WHY
/// TYPE: void, bool, char, string, i8...f64, an imported type's full name, T[], T?, or other
const DESCRIBE: &str = r#"using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;

static class Describe {
    static HashSet<Type> mine = new HashSet<Type>();

    static string T(Type t) {
        if (t == typeof(void)) return "void";
        if (t.IsByRef || t.IsPointer || t.IsGenericParameter) return "other";
        var u = Nullable.GetUnderlyingType(t);
        if (u != null) return T(u) + "?";
        if (t.IsArray) return t.GetArrayRank() == 1 ? T(t.GetElementType()) + "[]" : "other";
        if (mine.Contains(t)) return t.FullName;
        if (t == typeof(string)) return "string";
        if (t == typeof(bool)) return "bool";
        if (t == typeof(char)) return "char";
        if (t == typeof(sbyte)) return "i8";
        if (t == typeof(byte)) return "u8";
        if (t == typeof(short)) return "i16";
        if (t == typeof(ushort)) return "u16";
        if (t == typeof(int)) return "i32";
        if (t == typeof(uint)) return "u32";
        if (t == typeof(long)) return "i64";
        if (t == typeof(ulong)) return "u64";
        if (t == typeof(float)) return "f32";
        if (t == typeof(double)) return "f64";
        return "other";
    }

    static void Func(string name, string kind, IEnumerable<(string, Type)> ps, Type ret) {
        Console.WriteLine($"func\t{name}\t{kind}");
        foreach (var (n, t) in ps) Console.WriteLine($"param\t{n}\t{T(t)}");
        Console.WriteLine($"result\t{T(ret)}");
        Console.WriteLine("end");
    }

    static IEnumerable<(string, Type)> Params(MethodBase m) =>
        m.GetParameters().Select(p => (p.Name ?? "", p.IsOut || p.ParameterType.IsByRef ? typeof(void*) : p.ParameterType));

    static void Main(string[] a) {
        var asm = Assembly.LoadFrom(a[0]);
        Type[] all;
        try {
            all = asm.GetExportedTypes();
        } catch (ReflectionTypeLoadException e) {
            all = e.Types.Where(t => t != null && t.IsVisible).ToArray();
        }
        foreach (var t in all.OrderBy(t => t.FullName)) {
            if (t.ContainsGenericParameters) Console.WriteLine($"other\t{t.FullName}\tit's generic");
            else if (typeof(Delegate).IsAssignableFrom(t)) Console.WriteLine($"other\t{t.FullName}\ta delegate");
            else mine.Add(t);
        }
        foreach (var t in mine.OrderBy(t => t.FullName)) {
            string kind = t.IsEnum ? "enum" : t.IsInterface ? "interface" : t.IsValueType ? "struct" : t.IsAbstract && t.IsSealed ? "static" : t.IsAbstract ? "abstract" : "class";
            Console.WriteLine($"type\t{t.FullName}\t{kind}");
            var supers = new List<Type>();
            for (var b = t.BaseType; b != null; b = b.BaseType) if (mine.Contains(b)) supers.Add(b);
            supers.AddRange(t.GetInterfaces().Where(mine.Contains));
            foreach (var s in supers) Console.WriteLine($"super\t{s.FullName}");
            if (t.IsEnum) {
                foreach (var n in Enum.GetNames(t)) Console.WriteLine($"value\t{n}\t{Convert.ToInt64(Enum.Parse(t, n))}");
                Console.WriteLine("end");
                continue;
            }
            var inst = BindingFlags.Public | BindingFlags.Instance;
            var stat = BindingFlags.Public | BindingFlags.Static | BindingFlags.DeclaredOnly;
            if (t.IsValueType) {
                foreach (var f in t.GetFields(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)) Console.WriteLine($"field\t{f.Name}\t{(f.IsPublic && !f.IsInitOnly ? "true" : "false")}\t{T(f.FieldType)}");
            }
            if (kind == "class" || kind == "struct") {
                foreach (var c in t.GetConstructors().OrderBy(c => c.ToString())) Func("new", "ctor", Params(c), t);
            }
            foreach (var m in t.GetMethods(inst).Concat(t.GetMethods(stat)).OrderBy(m => m.Name).ThenBy(m => m.ToString())) {
                if (m.IsSpecialName || m.DeclaringType == typeof(object) || m.DeclaringType == typeof(ValueType)) continue;
                if (m.IsGenericMethodDefinition) {
                    Console.WriteLine($"other\t{t.Name}.{m.Name}\tit's generic");
                    continue;
                }
                Func(m.Name, m.IsStatic ? "static" : "inst", Params(m), m.ReturnType);
            }
            foreach (var p in t.GetProperties(inst).Concat(t.GetProperties(stat)).OrderBy(p => p.Name)) {
                if (p.GetIndexParameters().Length > 0) continue;
                var g = p.GetGetMethod();
                var s = p.GetSetMethod();
                var st = (g ?? s).IsStatic;
                if (g != null) Func(p.Name, st ? "sget" : "get", new (string, Type)[0], p.PropertyType);
                if (s != null) Func(p.Name, st ? "sset" : "set", new[] { ("value", p.PropertyType) }, typeof(void));
            }
            foreach (var f in t.GetFields(inst).Concat(t.GetFields(stat)).OrderBy(f => f.Name)) {
                Func(f.Name, f.IsStatic ? "sget" : "get", new (string, Type)[0], f.FieldType);
                if (!f.IsInitOnly && !f.IsLiteral) Func(f.Name, f.IsStatic ? "sset" : "set", new[] { ("value", f.FieldType) }, typeof(void));
            }
            foreach (var s in supers) Func(s.FullName, "cast", new (string, Type)[0], s);
            Console.WriteLine("end");
        }
    }
}
"#;

/// a type's Volt name: Geo.Point is Point, Geo.Outer+Inner Outer_Inner
fn volt_type(full: &str) -> String {
    full.rsplit('.').next().unwrap_or(full).replace('+', "_")
}

fn ty(s: &str, names: &BTreeMap<String, String>) -> Option<Ty> {
    if let Some(e) = s.strip_suffix("[]") {
        return Some(Ty::Slice(Box::new(ty(e, names)?), true));
    }
    if let Some(e) = s.strip_suffix('?') {
        return Some(Ty::Opt(Box::new(ty(e, names)?)));
    }
    Some(match s {
        "void" => Ty::Unit,
        "string" => Ty::Str,
        "char" => Ty::Char,
        _ => match super::glue::prim(s) {
            Some(p) => Ty::Prim(p),
            None => Ty::Named(names.get(s)?.clone()),
        },
    })
}

/// DESCRIBE's output as the glue's model, and what the shim needs to know of it
fn read(desc: &str) -> (Model, Dotnet) {
    let rows: Vec<Vec<&str>> = desc.lines().map(|l| l.split('\t').collect()).collect();
    let mut m = Model::default();
    let mut lang = Dotnet::default();
    // the types, by full name; two with one Volt name: neither
    let fulls: Vec<&str> = rows.iter().filter(|f| f.len() == 3 && f[0] == "type").map(|f| f[1]).collect();
    let mut count: BTreeMap<String, usize> = BTreeMap::new();
    for f in &fulls {
        *count.entry(volt_type(f)).or_default() += 1;
    }
    let mut names = BTreeMap::new();
    for f in &fulls {
        let v = volt_type(f);
        if count[&v] > 1 || v == "dotnet_shim" {
            m.left_out.push(format!("{f} (another type is called {v})"));
        } else {
            lang.full.insert(v.clone(), f.to_string());
            names.insert(f.to_string(), v);
        }
    }
    let mut i = 0;
    let mut cur: Option<(String, String)> = None; // the type's Volt name and kind
    let mut def: Option<TypeDef> = None;
    while i < rows.len() {
        let f = &rows[i];
        i += 1;
        match f[0] {
            "type" if f.len() == 3 => {
                cur = names.get(f[1]).map(|v| (v.clone(), f[2].to_string()));
                def = cur.as_ref().map(|(v, k)| TypeDef {
                    module: vec![],
                    name: v.clone(),
                    generic: false,
                    fields: (k == "struct").then(Vec::new),
                    variants: (k == "enum").then(Vec::new),
                    is_enum: k == "enum",
                    clone: k != "enum",
                    opaque: k != "struct" && k != "enum",
                    params: Vec::new(),
                    rust_name: None,
                });
            }
            "value" if f.len() == 3 => {
                if let (Some(d), Ok(n)) = (def.as_mut(), f[2].parse::<i128>()) {
                    d.variants.get_or_insert_with(Vec::new).push((f[1].to_string(), n));
                }
            }
            "field" if f.len() == 4 => {
                if let Some(d) = def.as_mut() {
                    d.fields.get_or_insert_with(Vec::new).push((f[1].to_string(), f[2] == "true", ty(f[3], &names)));
                }
            }
            "func" if f.len() == 3 => {
                let (mut params, mut ret) = (Vec::new(), None);
                while i < rows.len() && rows[i][0] != "end" {
                    let r = &rows[i];
                    match (r[0], r.len()) {
                        ("param", 3) => params.push((if r[1].is_empty() { format!("p{}", params.len()) } else { r[1].to_string() }, ty(r[2], &names))),
                        ("result", 2) => ret = ty(r[1], &names),
                        _ => {}
                    }
                    i += 1;
                }
                i += 1;
                let Some((tv, _)) = cur.clone() else { continue };
                let (name, recv) = match f[2] {
                    "ctor" => ("new".to_string(), Recv::None),
                    "static" | "sget" => (f[1].to_string(), Recv::None),
                    "get" | "inst" => (f[1].to_string(), Recv::Mut),
                    "set" => (format!("set_{}", f[1]), Recv::Mut),
                    "sset" => (format!("set_{}", f[1]), Recv::None),
                    "cast" => match names.get(f[1]) {
                        Some(b) => (format!("as_{b}"), Recv::Mut),
                        None => continue,
                    },
                    _ => continue,
                };
                match f[2] {
                    "get" | "sget" | "set" | "sset" => {
                        lang.props.insert((tv.clone(), name.clone()), f[1].to_string());
                    }
                    "cast" => {
                        lang.casts.insert((tv.clone(), name.clone()), f[1].to_string());
                    }
                    _ => {}
                }
                m.methods.entry(tv).or_default().push(Sig { name, recv, params, ret, skip: None, src: String::new(), generics: Vec::new(), call: None });
            }
            "end" => {
                m.types.extend(def.take());
                cur = None;
            }
            "other" if f.len() >= 3 => m.left_out.push(format!("{} ({})", f[1], f[2])),
            _ => {}
        }
    }
    (m, lang)
}

#[derive(Default)]
struct Dotnet {
    /// a type's full C# name, by its Volt name
    full: BTreeMap<String, String>,
    /// properties and fields: (type, Volt function name) -> the member's name
    props: BTreeMap<(String, String), String>,
    /// as_B: (type, Volt function name) -> B's full name
    casts: BTreeMap<(String, String), String>,
    /// the shim's assembly, and its name
    asm: PathBuf,
    asm_name: String,
}

impl Dotnet {
    fn path(&self, def: &TypeDef) -> String {
        format!("global::{}", self.full.get(&def.name).map_or(def.name.as_str(), String::as_str).replace('+', "."))
    }
}

/// a Volt number's C# type, and what a parameter of it is in the shim (a bool comes as a byte)
fn cs(x: &str) -> &'static str {
    match x {
        "i8" => "sbyte",
        "i16" => "short",
        "i32" => "int",
        "i64" => "long",
        "u8" => "byte",
        "u16" => "ushort",
        "u32" => "uint",
        "u64" => "ulong",
        "isize" => "nint",
        "usize" => "nuint",
        "f32" => "float",
        "f64" => "double",
        _ => "bool",
    }
}

impl Lang for Dotnet {
    fn short(&self) -> &'static str {
        "dotnet"
    }

    fn name(&self) -> &'static str {
        ".NET"
    }

    fn by_value_moves(&self, _ti: &TypeInfo) -> bool {
        false
    }

    fn param(&self, g: &Gen, t: &Ty, a: &str) -> Option<ShimParam> {
        let mut p = ShimParam::default();
        match t {
            Ty::Prim("bool") => {
                p.params.push(format!("byte {a}"));
                p.arg = format!("({a} != 0)");
            }
            Ty::Prim(x) => {
                p.params.push(format!("{} {a}", cs(x)));
                p.arg = a.to_string();
            }
            Ty::Char => {
                p.params.push(format!("uint {a}"));
                p.arg = format!("(char){a}");
            }
            Ty::Str => {
                p.params.extend([format!("byte* {a}"), format!("nuint {a}_n")]);
                p.arg = format!("S({a}, {a}_n)");
            }
            Ty::Slice(e, _) => match &**e {
                Ty::Prim(x) => {
                    let c = cs(x);
                    p.params.extend([format!("{c}* {a}"), format!("nuint {a}_n")]);
                    // a copy for .NET, and its changes back in Volt's
                    p.pre.push(format!("var {a}_v = new Span<{c}>({a}, checked((int){a}_n)).ToArray();"));
                    p.arg = format!("{a}_v");
                    p.post.push(format!("{a}_v.CopyTo(new Span<{c}>({a}, checked((int){a}_n)));"));
                }
                Ty::Str => {
                    p.params.extend([format!("VoltStr* {a}"), format!("nuint {a}_n")]);
                    p.arg = format!("Strs({a}, {a}_n)");
                }
                _ => return None,
            },
            Ty::Opt(inner) => match &**inner {
                Ty::Prim(x) => {
                    let (c, v) = if *x == "bool" { ("byte", format!("({a} != 0)")) } else { (cs(x), a.to_string()) };
                    p.params.extend([format!("byte {a}_has"), format!("{c} {a}")]);
                    p.arg = format!("({a}_has != 0 ? ({}?){v} : null)", cs(x));
                }
                _ => return None,
            },
            Ty::Named(_) => {
                let ti = g.info(t)?;
                let (path, mg) = (self.path(&ti.def), Gen::mangle(&ti.def));
                match ti.kind {
                    Kind::Plain => {
                        p.params.push(format!("V_{mg}* {a}"));
                        p.arg = format!("From_{mg}(*{a})");
                    }
                    Kind::Handle => {
                        p.params.push(format!("IntPtr {a}"));
                        p.arg = format!("H<{path}>({a})");
                    }
                    Kind::Enum => {
                        p.params.push(format!("long {a}"));
                        p.arg = format!("({path}){a}");
                    }
                }
            }
            _ => return None,
        }
        Some(p)
    }

    fn receiver(&self, _g: &Gen, ti: &TypeInfo, recv: Recv) -> Option<ShimParam> {
        let (path, mg) = (self.path(&ti.def), Gen::mangle(&ti.def));
        let mut p = ShimParam::default();
        match ti.kind {
            Kind::Plain => {
                p.params.push(format!("V_{mg}* self"));
                p.pre.push(format!("var self_v = From_{mg}(*self);"));
                if recv == Recv::Mut {
                    p.post.push(format!("*self = To_{mg}(self_v);"));
                }
                p.arg = "self_v".into();
            }
            Kind::Handle => {
                p.params.push("IntPtr self".into());
                p.arg = format!("H<{path}>(self)");
            }
            Kind::Enum => return None,
        }
        Some(p)
    }

    fn out(&self, g: &Gen, t: &Ty, o: &str, _owned: bool) -> Option<ShimOut> {
        Some(match t {
            Ty::Prim("bool") => ShimOut { params: vec![format!("byte* {o}")], store: format!("*{o} = (byte)($v ? 1 : 0);") },
            Ty::Prim(x) => ShimOut { params: vec![format!("{}* {o}", cs(x))], store: format!("*{o} = $v;") },
            Ty::Char => ShimOut { params: vec![format!("uint* {o}")], store: format!("*{o} = (uint)$v;") },
            Ty::Str => ShimOut { params: vec![format!("byte** {o}"), format!("nuint* {o}_n")], store: format!("PutStr($v, {o}, {o}_n);") },
            Ty::Slice(e, _) => match &**e {
                Ty::Prim(x) => ShimOut { params: vec![format!("{}** {o}", cs(x)), format!("nuint* {o}_n")], store: format!("PutArr<{}>($v, {o}, {o}_n);", cs(x)) },
                Ty::Str => ShimOut { params: vec![format!("VoltStr** {o}"), format!("nuint* {o}_n")], store: format!("PutStrs($v, {o}, {o}_n);") },
                _ => return None,
            },
            Ty::Opt(inner) => {
                let x = self.out(g, inner, o, false)?;
                let mut params = vec![format!("byte* {o}_has")];
                params.extend(x.params);
                let inner = x.store.replace("$v", &format!("{o}_w.Value"));
                ShimOut { params, store: format!("var {o}_w = $v;\n                if ({o}_w.HasValue) {{\n                    *{o}_has = 1;\n                    {inner}\n                }}") }
            }
            Ty::Named(_) => {
                let ti = g.info(t)?;
                let mg = Gen::mangle(&ti.def);
                match ti.kind {
                    Kind::Plain => ShimOut { params: vec![format!("V_{mg}* {o}")], store: format!("*{o} = To_{mg}($v);") },
                    Kind::Handle => ShimOut { params: vec![format!("IntPtr* {o}")], store: format!("*{o} = NewH($v);") },
                    Kind::Enum => ShimOut { params: vec![format!("long* {o}")], store: format!("*{o} = (long)$v;") },
                }
            }
            _ => return None,
        })
    }

    fn call(&self, _g: &Gen, _module: &[String], s: &Sig, self_ty: Option<&TypeInfo>, recv: Option<&str>, args: &[String]) -> String {
        let ty = self_ty.map(|t| t.def.name.clone()).unwrap_or_default();
        let target = recv.map_or_else(|| self_ty.map_or(String::new(), |t| self.path(&t.def)), str::to_string);
        if let Some(b) = self.casts.get(&(ty.clone(), s.name.clone())) {
            return format!("(global::{}){target}", b.replace('+', "."));
        }
        if let Some(p) = self.props.get(&(ty.clone(), s.name.clone())) {
            return match args {
                [v] if s.name.starts_with("set_") => format!("{target}.{p} = {v}"),
                _ => format!("{target}.{p}"),
            };
        }
        if s.name == "new" && recv.is_none() {
            return format!("new {target}({})", args.join(", "));
        }
        format!("{target}.{}({})", s.name, args.join(", "))
    }

    fn function(&self, sym: &str, params: &[String], pre: &[String], call: &str, post: &[String], store: Option<&str>, _res: bool) -> String {
        let mut body = String::new();
        for l in pre {
            let _ = writeln!(body, "            {l}");
        }
        match store {
            Some(st) => {
                let _ = writeln!(body, "            var v = {call};");
                for l in post {
                    let _ = writeln!(body, "            {l}");
                }
                let _ = writeln!(body, "            {}", st.replace("$v", "v"));
            }
            None => {
                let _ = writeln!(body, "            {call};");
                for l in post {
                    let _ = writeln!(body, "            {l}");
                }
            }
        }
        format!("    [UnmanagedCallersOnly]\n    public static void {sym}({}) {{\n        try {{\n{body}        }} catch (Exception e) {{\n            Fail(e);\n        }}\n    }}\n\n", params.join(", "))
    }

    fn type_glue(&self, g: &Gen, ti: &TypeInfo) -> String {
        let (path, mg) = (self.path(&ti.def), Gen::mangle(&ti.def));
        let mut out = String::new();
        match ti.kind {
            Kind::Plain => {
                let (mut fields, mut from, mut to) = (String::new(), String::new(), String::new());
                for (f, _, t) in ti.def.fields.clone().unwrap_or_default() {
                    match t {
                        Some(Ty::Prim(x)) => {
                            let _ = writeln!(fields, "        public {} {f};", cs(x));
                            let _ = write!(from, "{f} = v.{f}, ");
                            let _ = write!(to, "{f} = v.{f}, ");
                        }
                        Some(Ty::Char) => {
                            let _ = writeln!(fields, "        public uint {f};");
                            let _ = write!(from, "{f} = (char)v.{f}, ");
                            let _ = write!(to, "{f} = (uint)v.{f}, ");
                        }
                        Some(Ty::Named(n)) => {
                            let o = &g.types[&n];
                            let (op, omg) = (self.path(&o.def), Gen::mangle(&o.def));
                            if o.kind == Kind::Enum {
                                let _ = writeln!(fields, "        public long {f};");
                                let _ = write!(from, "{f} = ({op})v.{f}, ");
                                let _ = write!(to, "{f} = (long)v.{f}, ");
                            } else {
                                let _ = writeln!(fields, "        public V_{omg} {f};");
                                let _ = write!(from, "{f} = From_{omg}(v.{f}), ");
                                let _ = write!(to, "{f} = To_{omg}(v.{f}), ");
                            }
                        }
                        _ => {}
                    }
                }
                // the Volt struct's layout, field for field
                let _ = write!(out, "    public struct V_{mg} {{\n{fields}    }}\n\n    static {path} From_{mg}(V_{mg} v) => new {path} {{ {from}}};\n\n    static V_{mg} To_{mg}({path} v) => new V_{mg} {{ {to}}};\n\n");
            }
            Kind::Handle => {
                let drop = g.sym(&[&mg, "drop"]);
                let _ = write!(out, "    [UnmanagedCallersOnly]\n    public static void {drop}(IntPtr h) => GCHandle.FromIntPtr(h).Free();\n\n");
                if ti.def.clone {
                    let cl = g.sym(&[&mg, "clone"]);
                    let _ = write!(out, "    [UnmanagedCallersOnly]\n    public static IntPtr {cl}(IntPtr h) => GCHandle.ToIntPtr(GCHandle.Alloc(GCHandle.FromIntPtr(h).Target));\n\n");
                }
            }
            Kind::Enum => {}
        }
        out
    }

    fn prelude(&self, g: &Gen) -> String {
        let free = |what: &str| format!("volt_dotnet_{}_free_{what}", g.alias);
        let mut s = String::from(PRELUDE);
        let _ = write!(s, "    [UnmanagedCallersOnly]\n    public static void {}(byte* p, nuint n) => NativeMemory.Free(p);\n\n", free("bytes"));
        for x in &g.vec_elems {
            let _ = write!(s, "    [UnmanagedCallersOnly]\n    public static void {}({}* p, nuint n) => NativeMemory.Free(p);\n\n", free(&format!("{x}s")), cs(x));
        }
        if g.strs {
            let _ = write!(s, "    [UnmanagedCallersOnly]\n    public static void {}(VoltStr* p, nuint n) {{\n        for (nuint i = 0; i < n; i++) NativeMemory.Free(p[i].p);\n        NativeMemory.Free(p);\n    }}\n\n", free("strs"));
        }
        s
    }

    fn loader(&self, _g: &Gen) -> Option<String> {
        let q = |p: &Path| p.display().to_string().replace('\\', "\\\\").replace('"', "\\\"");
        Some(LOADER.replace("{CONFIG}", &q(&self.asm.with_extension("runtimeconfig.json"))).replace("{ASM}", &q(&self.asm)).replace("{NAME}", &self.asm_name))
    }
}

/// the shim's start: its helpers (Volt's memory as .NET values, .NET's copied to native memory for
/// Volt, handles, exceptions)
const PRELUDE: &str = r#"// the glue between a Volt program and an assembly, written by bolt import (use dotnet)
using System;
using System.Runtime.InteropServices;
using System.Text;

public static unsafe class VoltShim {
    public struct VoltStr {
        public byte* p;
        public nuint n;
    }

    static string S(byte* p, nuint n) => n == 0 ? "" : Encoding.UTF8.GetString(p, checked((int)n));

    static string[] Strs(VoltStr* p, nuint n) {
        var o = new string[checked((int)n)];
        for (int i = 0; i < o.Length; i++) o[i] = S(p[i].p, p[i].n);
        return o;
    }

    static T H<T>(IntPtr h) => (T)GCHandle.FromIntPtr(h).Target;

    static IntPtr NewH(object v) => v == null ? IntPtr.Zero : GCHandle.ToIntPtr(GCHandle.Alloc(v));

    static void PutStr(string v, byte** o, nuint* o_n) {
        if (string.IsNullOrEmpty(v)) {
            *o = null;
            *o_n = 0;
            return;
        }
        var n = Encoding.UTF8.GetByteCount(v);
        var p = (byte*)NativeMemory.Alloc((nuint)n);
        fixed (char* c = v) {
            Encoding.UTF8.GetBytes(c, v.Length, p, n);
        }
        *o = p;
        *o_n = (nuint)n;
    }

    static void PutArr<T>(T[] v, T** o, nuint* o_n) where T : unmanaged {
        if (v == null || v.Length == 0) {
            *o = null;
            *o_n = 0;
            return;
        }
        var p = (T*)NativeMemory.Alloc((nuint)v.Length, (nuint)sizeof(T));
        new Span<T>(v).CopyTo(new Span<T>(p, v.Length));
        *o = p;
        *o_n = (nuint)v.Length;
    }

    static void PutStrs(string[] v, VoltStr** o, nuint* o_n) {
        if (v == null || v.Length == 0) {
            *o = null;
            *o_n = 0;
            return;
        }
        var p = (VoltStr*)NativeMemory.Alloc((nuint)v.Length, (nuint)sizeof(VoltStr));
        for (int i = 0; i < v.Length; i++) {
            byte* b;
            nuint n;
            PutStr(v[i], &b, &n);
            p[i].p = b;
            p[i].n = n;
        }
        *o = p;
        *o_n = (nuint)v.Length;
    }

    // an exception: the program stops with its text, as a Volt panic does
    static void Fail(Exception e) {
        Console.Out.Flush();
        Console.Error.WriteLine($"panic: {e.GetType().FullName}: {e.Message}");
        Environment.Exit(101);
    }

"#;

/// the Volt side's loader: hostfxr starts .NET (or finds the runtime the process has) the first
/// time, and gives each shim method's address
const LOADER: &str = r#"    extern "C" fn hostfxr_initialize_for_runtime_config(config: cstr, params: void*, handle: void**) -> i32;
    extern "C" fn hostfxr_get_runtime_delegate(handle: void*, kind: i32, out: void**) -> i32;
    extern "C" fn hostfxr_close(handle: void*) -> i32;
    var load_fp: void* = null;

    // the address of the glue's method name; .NET starts the first time
    fn load(slot: void**, name: str) -> void* {
        if (*slot != null) {
            return *slot;
        }
        if (load_fp == null) {
            var config = std::string::from("{CONFIG}");
            var h: void* = null;
            val rc = hostfxr_initialize_for_runtime_config(config.c_str(), null, &h);
            if (rc < 0 || rc > 2) {
                @panic(std::fmt::format(".NET didn't start (hostfxr: 0x{:x})", @cast<u32>(rc)).as_str());
            }
            // hdt_load_assembly_and_get_function_pointer
            val rd = hostfxr_get_runtime_delegate(h, 5, &load_fp);
            hostfxr_close(h);
            if (rd != 0) {
                @panic(std::fmt::format(".NET didn't start (hostfxr: 0x{:x})", @cast<u32>(rd)).as_str());
            }
        }
        val f = @cast<extern "C" fn(cstr, cstr, cstr, void*, void*, void**) -> i32>(load_fp);
        var a = std::string::from("{ASM}");
        var t = std::string::from("VoltShim, {NAME}");
        var m = std::string::from(name);
        // UNMANAGEDCALLERSONLY_METHOD: (const char_t*)-1
        val rc = f(a.c_str(), t.c_str(), m.c_str(), @cast<void*>(~@cast<usize>(0)), null, slot);
        if (rc != 0) {
            @panic(std::fmt::format("{} isn't in the .NET glue (0x{:x})", name, @cast<u32>(rc)).as_str());
        }
        return *slot;
    }
"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn import_dotnet_read() {
        let desc = "type\tGeo.Point\tstruct\nfield\tX\ttrue\tf64\nfield\tY\ttrue\tf64\nfunc\tnew\tctor\nparam\tx\tf64\nparam\ty\tf64\nresult\tGeo.Point\nend\nfunc\tDist\tinst\nparam\to\tGeo.Point\nresult\tf64\nend\nend\ntype\tGeo.Shape\tclass\nsuper\tGeo.IArea\nfunc\tName\tget\nresult\tstring\nend\nfunc\tName\tset\nparam\tvalue\tstring\nresult\tvoid\nend\nfunc\tGeo.IArea\tcast\nresult\tGeo.IArea\nend\nfunc\tFind\tstatic\nparam\txs\ti32[]\nparam\tx\ti32?\nresult\ti32?\nend\nend\ntype\tGeo.IArea\tinterface\nend\nother\tGeo.Box`1\tit's generic\n";
        let (m, lang) = read(desc);
        assert_eq!(m.types.iter().map(|t| (t.name.as_str(), t.opaque)).collect::<Vec<_>>(), [("Point", false), ("Shape", true), ("IArea", true)]);
        assert_eq!(m.types[0].fields.as_ref().unwrap().len(), 2);
        let shape: Vec<(&str, Recv)> = m.methods["Shape"].iter().map(|s| (s.name.as_str(), s.recv)).collect();
        assert_eq!(shape, [("Name", Recv::Mut), ("set_Name", Recv::Mut), ("as_IArea", Recv::Mut), ("Find", Recv::None)]);
        assert_eq!(m.methods["Shape"][3].params[0].1, Some(Ty::Slice(Box::new(Ty::Prim("i32")), true)));
        assert_eq!(m.methods["Shape"][3].ret, Some(Ty::Opt(Box::new(Ty::Prim("i32")))));
        assert_eq!(m.methods["Point"][0].name, "new");
        assert_eq!(lang.props[&("Shape".to_string(), "set_Name".to_string())], "Name");
        assert_eq!(lang.casts[&("Shape".to_string(), "as_IArea".to_string())], "Geo.IArea");
        assert_eq!(m.left_out, ["Geo.Box`1 (it's generic)"]);
    }
}
