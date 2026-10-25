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
use super::glue::{FnPass, Gen, Kind, Lang, Model, Recv, ShimOut, ShimParam, Sig, Ty, TypeDef, TypeInfo};
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
    // the sources' own inputs (the instances the C# compiler rejected stay rejected until these
    // change)
    let own_st = stamp(&files, "dotnet sources");
    // the instances of its generics a program asked for (voltc writes them)
    if r.out.join("instances").is_file() {
        files.push(r.out.join("instances"));
    }
    let st = stamp(&files, &format!("dotnet {} {} release={}", r.alias, dotnet.display(), r.release));
    if fresh(r, &st) {
        return Ok(());
    }
    let out = {
        std::fs::create_dir_all(&r.out).map_err(|e| format!("can't make {}: {e}", r.out.display()))?;
        super::canonicalize(&r.out).unwrap_or_else(|_| r.out.clone())
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
    let desc = String::from_utf8_lossy(&o.stdout).into_owned();

    // the shim, beside the library it calls, with the instances of generics asked for (the C#
    // compiler checks each one's constraints)
    let shim_name = format!("volt_shim_{id}");
    let dir = out.join("shim");
    let user_name = user.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let proj = format!("<Project Sdk=\"Microsoft.NET.Sdk\">\n  <PropertyGroup>\n    <TargetFramework>{tfm}</TargetFramework>\n    <AssemblyName>{shim_name}</AssemblyName>\n    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>\n    <EnableDynamicLoading>true</EnableDynamicLoading>\n    <Nullable>disable</Nullable>\n  </PropertyGroup>\n  <ItemGroup>\n    <Reference Include=\"{}\">\n      <HintPath>{}</HintPath>\n    </Reference>\n  </ItemGroup>\n</Project>\n", xml(&user_name), xml(&user.display().to_string()));
    let model_with = |lines: &[String], skip: &BTreeMap<String, String>| {
        let (mut model, lang) = read(&desc);
        let mut lang = Dotnet { asm: dir.join("bin").join(format!("{shim_name}.dll")), asm_name: shim_name.clone(), root: root.clone(), ..lang };
        let made = instances(&mut model, &mut lang, lines, &r.alias, skip);
        (model, lang, made)
    };
    let build_with = |lines: &[String], skip: &BTreeMap<String, String>| -> Result<(String, String), String> {
        let (model, lang, _) = model_with(lines, skip);
        let (shim, volt) = Gen::new(&model, &r.alias, &lang).write("the assembly");
        crate::build::write_if_changed(&dir.join("Shim.cs"), &(shim + "}\n"))?;
        build(&dotnet, &dir, "Shim.csproj", &proj, "the glue").map_err(|e| cs_errors(&e))?;
        Ok((volt, String::new()))
    };
    let methods = |l: &str, skip: &BTreeMap<String, String>| -> Vec<String> {
        let (model, _, made) = model_with(std::slice::from_ref(&l.to_string()), skip);
        made.first().cloned().flatten().and_then(|t| model.methods.get(&t).cloned()).unwrap_or_default().into_iter().map(|s| s.name).collect()
    };
    let (volt, _) = super::with_instances(r, &own_st, build_with, methods, |e| e)?;

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
            let p = p.strip_suffix(']')?;
            let root = p.strip_suffix("/shared/Microsoft.NETCore.App").or_else(|| p.strip_suffix("\\shared\\Microsoft.NETCore.App"))?;
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

/// the C# compiler's errors (file(line,col): error CS0311: what [project]) marked the way
/// with_instances finds an instance's reason (file(line,col): error: CS0311: what)
fn cs_errors(e: &str) -> String {
    e.lines()
        .map(|l| match l.split_once(": error CS") {
            Some((at, what)) => format!("{at}: error: CS{}", what.rsplit_once(" [").map_or(what, |x| x.0)),
            None => l.to_string(),
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// The instances voltc asked for (OUT/instances: a line per instance, `Type` or `Type::Method`,
/// then each type argument as Volt names it, tab-separated): a generic class's instance is a type
/// of its own (Box__i32, global::Geo.Box<int> to C#) with its members, a generic method's a
/// method calling Max<int>; made of each line: the type instance's name, for a type's
fn instances(m: &mut Model, lang: &mut Dotnet, lines: &[String], alias: &str, skip: &BTreeMap<String, String>) -> Vec<Option<String>> {
    let types: BTreeMap<String, Vec<String>> = m.types.iter().map(|t| (t.name.clone(), t.module.clone())).collect();
    let mut made = Vec::new();
    for line in lines {
        made.push(None);
        let mut parts = line.split('\t');
        let Some(path) = parts.next().filter(|p| !p.is_empty()) else { continue };
        let args: Vec<&str> = parts.collect();
        let what = format!("{path}<{}>", args.join(", "));
        let inst_of = |name: &str| format!("{name}__{}", args.iter().map(|a| super::glue::ident(a)).collect::<Vec<_>>().join("_"));
        // each type argument as the import has it, and as C# spells it
        let mut subst = BTreeMap::new();
        let mut cs_args = Vec::new();
        let bind = |params: &[String], subst: &mut BTreeMap<String, Ty>, cs_args: &mut Vec<String>, m: &Model| -> bool {
            for (gp, a) in params.iter().zip(&args) {
                let Some(t) = super::glue::volt_ty(a, alias, &types) else { return false };
                let Some(c) = cs_arg(&t, m, lang) else { return false };
                subst.insert(gp.clone(), t);
                cs_args.push(c);
            }
            params.len() == args.len()
        };
        match path.split_once("::") {
            // a generic class's instance: the class with its arguments in place, and its members
            None => {
                let Some(gt) = m.types.iter().find(|t| t.name == path && t.generic).cloned() else { continue };
                let inst = inst_of(path);
                if types.contains_key(&inst) || m.types.iter().any(|t| t.name == inst) {
                    continue;
                }
                if !bind(&gt.params, &mut subst, &mut cs_args, m) {
                    m.left_out.push(format!("{what} (it takes {} types: numbers, std::string or the import's own non-generic types)", gt.params.len()));
                    continue;
                }
                let full = lang.full.get(path).cloned().unwrap_or_else(|| path.to_string());
                let mut d = gt.clone();
                d.name = inst.clone();
                d.generic = false;
                d.params.clear();
                d.rust_name = Some(format!("{}<{}>", full.split('`').next().unwrap_or(&full).replace('+', "."), cs_args.join(", ")));
                d.fields = d.fields.map(|fs| fs.into_iter().map(|(n, p, t)| (n, p, t.map(|t| super::glue::substitute(&t, &subst)))).collect());
                let mut ms = Vec::new();
                for mut s in m.methods.get(path).cloned().unwrap_or_default() {
                    if let Some(w) = skip.get(&format!("{line}::{}", s.name)) {
                        m.left_out.push(format!("{inst}::{} (the C# compiler: {w})", s.name));
                        continue;
                    }
                    s.params = s.params.iter().map(|(n, t)| (n.clone(), t.as_ref().map(|t| super::glue::substitute(t, &subst)))).collect();
                    s.ret = s.ret.as_ref().map(|t| super::glue::substitute(t, &subst));
                    ms.push(s);
                }
                // its properties, fields and casts are the class's
                for map in [&mut lang.props, &mut lang.casts] {
                    let own: Vec<((String, String), String)> = map.iter().filter(|((t, _), _)| t == path).map(|((_, f), v)| ((inst.clone(), f.clone()), v.clone())).collect();
                    map.extend(own);
                }
                m.methods.insert(inst.clone(), ms);
                m.types.push(d);
                *made.last_mut().unwrap() = Some(inst);
            }
            // a generic method's instance: a method of the type calling Name<args>
            Some((ty, method)) => {
                let Some(g) = m.methods.get(ty).and_then(|ms| ms.iter().find(|s| s.name == method && !s.generics.is_empty())).cloned() else { continue };
                let inst = inst_of(method);
                if m.methods.get(ty).is_some_and(|ms| ms.iter().any(|s| s.name == inst)) {
                    continue;
                }
                if !bind(&g.generics, &mut subst, &mut cs_args, m) {
                    m.left_out.push(format!("{what} (it takes {} types: numbers, std::string or the import's own non-generic types)", g.generics.len()));
                    continue;
                }
                let mut s = g.clone();
                s.params = s.params.iter().map(|(n, t)| (n.clone(), t.as_ref().map(|t| super::glue::substitute(t, &subst)))).collect();
                s.ret = s.ret.as_ref().map(|t| super::glue::substitute(t, &subst));
                s.generics.clear();
                s.call = Some(format!("{method}<{}>", cs_args.join(", ")));
                s.src = format!("{} [{}]", s.src, g.generics.iter().zip(&args).map(|(p, a)| format!("{p} = {a}")).collect::<Vec<_>>().join(", "));
                s.name = inst;
                m.methods.entry(ty.to_string()).or_default().push(s);
            }
        }
    }
    made
}

/// a type argument as C# spells it: a number, string, or one of the import's (non-generic) types; a
/// Volt type of the program's own, or another generic's instance, has none
fn cs_arg(t: &Ty, m: &Model, lang: &Dotnet) -> Option<String> {
    Some(match t {
        Ty::Prim(x) => cs(x).to_string(),
        Ty::Str | Ty::String => "string".into(),
        Ty::Named(n) => {
            let d = m.types.iter().find(|d| d.name == *n && !d.generic)?;
            format!("global::{}", d.rust_name.clone().unwrap_or_else(|| lang.full.get(n).cloned().unwrap_or_default()).replace('+', "."))
        }
        _ => return None,
    })
}

fn xml(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// a C# program printing what an assembly's public types have, a declaration a line (tab-separated):
///   type FULLNAME class|abstract|static|interface|struct|enum, then tparam NAME (a generic one's
///   type parameters), super FULLNAME (an imported base or interface), value NAME N (an enum's),
///   field NAME settable TYPE (a struct's instance fields, in order), func NAME KIND (KIND: ctor,
///   inst, static, get, sget, set, sset, cast; then the method's C# declaration, when it has one)
///   with tparam NAME (a generic method's), param NAME TYPE (ref:TYPE, out:TYPE for ref and out
///   parameters) and result TYPE lines and end; end
///   other NAME WHY
/// TYPE: void, bool, char, string, i8...f64, an imported type's full name, T[], T?, $T (a type
/// parameter), an imported generic type's instance (Geo.Box`1<$T>), fn(TYPE,...)TYPE (a delegate:
/// its Invoke's types), or other
const DESCRIBE: &str = r#"using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;

static class Describe {
    static HashSet<Type> mine = new HashSet<Type>();
    static HashSet<Type> inside = new HashSet<Type>();

    static string T(Type t) {
        if (t == typeof(void)) return "void";
        if (t.IsGenericParameter) return "$" + t.Name;
        if (t.IsByRef || t.IsPointer) return "other";
        if (t.IsGenericType && mine.Contains(t.GetGenericTypeDefinition())) return t.GetGenericTypeDefinition().FullName + "<" + string.Join(",", t.GetGenericArguments().Select(T)) + ">";
        if (typeof(Delegate).IsAssignableFrom(t) && t != typeof(Delegate) && t != typeof(MulticastDelegate)) {
            var inv = t.GetMethod("Invoke");
            if (inv == null || inv.ReturnType.IsByRef || inv.GetParameters().Any(p => p.ParameterType.IsByRef) || !inside.Add(t)) return "other";
            var fn = "fn(" + string.Join(",", inv.GetParameters().Select(p => T(p.ParameterType))) + ")" + T(inv.ReturnType);
            inside.Remove(t);
            return fn;
        }
        var u = Nullable.GetUnderlyingType(t);
        if (u != null) return T(u) + "?";
        if (t.IsArray) return t.GetArrayRank() == 1 && !T(t.GetElementType()).StartsWith("fn(") ? T(t.GetElementType()) + "[]" : "other";
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

    static readonly Dictionary<Type, string> Words = new Dictionary<Type, string> {
        { typeof(void), "void" }, { typeof(string), "string" }, { typeof(bool), "bool" }, { typeof(char), "char" },
        { typeof(sbyte), "sbyte" }, { typeof(byte), "byte" }, { typeof(short), "short" }, { typeof(ushort), "ushort" },
        { typeof(int), "int" }, { typeof(uint), "uint" }, { typeof(long), "long" }, { typeof(ulong), "ulong" },
        { typeof(float), "float" }, { typeof(double), "double" }, { typeof(object), "object" },
    };

    // a parameter's type, ref and out ones marked (an in one is its value)
    static string P(ParameterInfo p) {
        var t = p.ParameterType;
        if (!t.IsByRef) return T(t);
        if (p.IsOut && !p.IsIn) return "out:" + T(t.GetElementType());
        return In(p) ? T(t.GetElementType()) : "ref:" + T(t.GetElementType());
    }

    // an in parameter (not [In] ref): its modreq says so
    static bool In(ParameterInfo p) => p.GetRequiredCustomModifiers().Contains(typeof(System.Runtime.InteropServices.InAttribute));

    // a type as C# spells it
    static string Cs(Type t) {
        var u = Nullable.GetUnderlyingType(t);
        if (u != null) return Cs(u) + "?";
        if (t.IsByRef) return Cs(t.GetElementType());
        if (t.IsArray) return Cs(t.GetElementType()) + "[]";
        return Words.TryGetValue(t, out var w) ? w : t.Name;
    }

    // a method or constructor as C# declares it: public static int Add(int a, int b)
    static string Decl(MethodBase m) {
        var ps = string.Join(", ", m.GetParameters().Select(p => (!p.ParameterType.IsByRef ? "" : p.IsOut && !p.IsIn ? "out " : In(p) ? "in " : "ref ") + Cs(p.ParameterType) + " " + p.Name));
        var head = "public " + (m.IsStatic ? "static " : "");
        var tps = m.IsGenericMethodDefinition ? "<" + string.Join(", ", m.GetGenericArguments().Select(a => a.Name)) + ">" : "";
        return m is MethodInfo mi ? $"{head}{Cs(mi.ReturnType)} {m.Name}{tps}({ps})" : $"{head}{m.DeclaringType.Name.Split('`')[0]}({ps})";
    }

    static void Func(string name, string kind, IEnumerable<(string, string)> ps, Type ret, string decl = "", Type[] tps = null) {
        Console.WriteLine($"func\t{name}\t{kind}\t{decl}");
        foreach (var a in tps ?? new Type[0]) Console.WriteLine($"tparam\t{a.Name}");
        foreach (var (n, t) in ps) Console.WriteLine($"param\t{n}\t{t}");
        Console.WriteLine($"result\t{T(ret)}");
        Console.WriteLine("end");
    }

    static IEnumerable<(string, string)> Params(MethodBase m) => m.GetParameters().Select(p => (p.Name ?? "", P(p)));

    static IEnumerable<(string, string)> One(string n, Type t) => new[] { (n, T(t)) };

    static void Main(string[] a) {
        var asm = Assembly.LoadFrom(a[0]);
        Type[] all;
        try {
            all = asm.GetExportedTypes();
        } catch (ReflectionTypeLoadException e) {
            all = e.Types.Where(t => t != null && t.IsVisible).ToArray();
        }
        // (a delegate type is the fn type of its Invoke, not a type of its own)
        foreach (var t in all.OrderBy(t => t.FullName)) {
            if (typeof(Delegate).IsAssignableFrom(t)) continue;
            if (t.ContainsGenericParameters && (!t.IsGenericTypeDefinition || (t.IsNested && t.DeclaringType.IsGenericTypeDefinition))) Console.WriteLine($"other\t{t.FullName}\tit's inside a generic type");
            else mine.Add(t);
        }
        foreach (var t in mine.OrderBy(t => t.FullName)) {
            string kind = t.IsEnum ? "enum" : t.IsInterface ? "interface" : t.IsValueType ? "struct" : t.IsAbstract && t.IsSealed ? "static" : t.IsAbstract ? "abstract" : "class";
            Console.WriteLine($"type\t{t.FullName}\t{kind}");
            if (t.IsGenericTypeDefinition) foreach (var tp in t.GetGenericArguments()) Console.WriteLine($"tparam\t{tp.Name}");
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
                foreach (var c in t.GetConstructors().OrderBy(c => c.ToString())) Func("new", "ctor", Params(c), t, Decl(c));
            }
            foreach (var m in t.GetMethods(inst).Concat(t.GetMethods(stat)).OrderBy(m => m.Name).ThenBy(m => m.ToString())) {
                if (m.IsSpecialName || m.DeclaringType == typeof(object) || m.DeclaringType == typeof(ValueType)) continue;
                if (m.IsGenericMethodDefinition && t.IsGenericTypeDefinition) {
                    Console.WriteLine($"other\t{t.Name.Split('`')[0]}.{m.Name}\tit's generic in a generic type");
                    continue;
                }
                Func(m.Name, m.IsStatic ? "static" : "inst", Params(m), m.ReturnType, Decl(m), m.IsGenericMethodDefinition ? m.GetGenericArguments() : null);
            }
            foreach (var p in t.GetProperties(inst).Concat(t.GetProperties(stat)).OrderBy(p => p.Name)) {
                if (p.GetIndexParameters().Length > 0) continue;
                var g = p.GetGetMethod();
                var s = p.GetSetMethod();
                var st = (g ?? s).IsStatic;
                if (g != null) Func(p.Name, st ? "sget" : "get", new (string, string)[0], p.PropertyType);
                if (s != null) Func(p.Name, st ? "sset" : "set", One("value", p.PropertyType), typeof(void));
            }
            foreach (var f in t.GetFields(inst).Concat(t.GetFields(stat)).OrderBy(f => f.Name)) {
                Func(f.Name, f.IsStatic ? "sget" : "get", new (string, string)[0], f.FieldType);
                if (!f.IsInitOnly && !f.IsLiteral) Func(f.Name, f.IsStatic ? "sset" : "set", One("value", f.FieldType), typeof(void));
            }
            foreach (var s in supers) Func(s.FullName, "cast", new (string, string)[0], s);
            Console.WriteLine("end");
        }
    }
}
"#;

/// a type's Volt name: Geo.Point is Point, Geo.Outer+Inner Outer_Inner, Geo.Box`1 Box
fn volt_type(full: &str) -> String {
    let mut out = String::new();
    let mut arity = false;
    for c in full.rsplit('.').next().unwrap_or(full).chars() {
        arity = c == '`' || (arity && c.is_ascii_digit());
        if !arity {
            out.push(if c == '+' { '_' } else { c });
        }
    }
    out
}

/// where the ')' closing s's first '(' is (s starts after it), and s's parts split at its top-level
/// commas
fn closing(s: &str) -> Option<usize> {
    let mut depth = 0;
    for (i, c) in s.char_indices() {
        match c {
            '(' | '<' => depth += 1,
            '>' => depth -= 1,
            ')' if depth == 0 => return Some(i),
            ')' => depth -= 1,
            _ => {}
        }
    }
    None
}

fn top_parts(s: &str) -> Vec<&str> {
    if s.is_empty() {
        return Vec::new();
    }
    let (mut out, mut depth, mut start) = (Vec::new(), 0, 0);
    for (i, c) in s.char_indices() {
        match c {
            '(' | '<' => depth += 1,
            ')' | '>' => depth -= 1,
            ',' if depth == 0 => {
                out.push(&s[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    out.push(&s[start..]);
    out
}

fn ty(s: &str, names: &BTreeMap<String, String>) -> Option<Ty> {
    // a delegate: a closure of its Invoke's types (its text result a String, as a closure gives one),
    // which .NET may keep
    if let Some(rest) = s.strip_prefix("fn(") {
        let close = closing(rest)?;
        let ps = top_parts(&rest[..close]).into_iter().map(|p| ty(p, names)).collect::<Option<Vec<_>>>()?;
        let r = match ty(&rest[close + 1..], names)? {
            Ty::Str => Ty::String,
            r => r,
        };
        return Some(Ty::Fn(ps, Box::new(r), FnPass::Boxed, false));
    }
    if let Some(e) = s.strip_suffix("[]") {
        return Some(Ty::Slice(Box::new(ty(e, names)?), true));
    }
    if let Some(e) = s.strip_suffix('?') {
        return Some(Ty::Opt(Box::new(ty(e, names)?)));
    }
    if let Some(g) = s.strip_prefix('$') {
        return Some(Ty::Generic(g.to_string()));
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
    // (a generic one's arity, Box`1, isn't in its Volt name: a plain type of that name keeps it)
    let generic = |f: &str| f.contains('`');
    let mut count: BTreeMap<(String, bool), usize> = BTreeMap::new();
    for f in &fulls {
        *count.entry((volt_type(f), generic(f))).or_default() += 1;
    }
    let mut names = BTreeMap::new();
    for f in &fulls {
        let v = volt_type(f);
        let plain_too = generic(f) && count.contains_key(&(v.clone(), false));
        if count[&(v.clone(), generic(f))] > 1 || plain_too || v == "dotnet_shim" {
            m.left_out.push(format!("{f} (another type is called {v})"));
        } else {
            lang.full.insert(v.clone(), f.to_string());
            names.insert(f.to_string(), v);
        }
    }
    let mut i = 0;
    let mut cur: Option<(String, String)> = None; // the type's Volt name and kind
    let mut def: Option<TypeDef> = None;
    let mut cur_full = String::new();
    while i < rows.len() {
        let f = &rows[i];
        i += 1;
        match f[0] {
            "type" if f.len() == 3 => {
                cur_full = f[1].to_string();
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
            // a generic type's type parameter: a type per instance a program names
            "tparam" if f.len() == 2 => {
                if let Some(d) = def.as_mut() {
                    d.generic = true;
                    d.params.push(f[1].to_string());
                }
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
            "func" if f.len() == 3 || f.len() == 4 => {
                let (mut params, mut ret, mut generics, mut outs) = (Vec::new(), None, Vec::new(), Vec::new());
                // the type itself, as its members spell it (Geo.Box`1<$T>)
                let own = def.as_ref().filter(|d| d.generic).map(|d| format!("{cur_full}<{}>", d.params.iter().map(|p| format!("${p}")).collect::<Vec<_>>().join(",")));
                let ty_of = |t: &str| if own.as_deref() == Some(t) { Some(Ty::SelfTy) } else { ty(t, &names) };
                while i < rows.len() && rows[i][0] != "end" {
                    let r = &rows[i];
                    match (r[0], r.len()) {
                        ("tparam", 2) => generics.push(r[1].to_string()),
                        ("param", 3) => {
                            let n = if r[1].is_empty() { format!("p{}", params.len()) } else { r[1].to_string() };
                            // ref: a Volt reference; out: one of the results
                            let t = if let Some(x) = r[2].strip_prefix("ref:") {
                                ty_of(x).map(|t| Ty::Ref(Box::new(t), true))
                            } else if let Some(x) = r[2].strip_prefix("out:") {
                                let t = ty_of(x).map(|t| if t == Ty::Str { Ty::String } else { t });
                                outs.push((n.clone(), t.clone()));
                                t.map(|t| Ty::Out(Box::new(t), n.clone()))
                            } else {
                                ty_of(r[2])
                            };
                            params.push((n, t));
                        }
                        ("result", 2) => ret = ty_of(r[1]),
                        _ => {}
                    }
                    i += 1;
                }
                i += 1;
                // out parameters are results: the one of a void method is its value, else a tuple
                // (the method's own value first, unnamed)
                if !outs.is_empty() {
                    let named: Option<Vec<(String, Ty)>> = outs.into_iter().map(|(n, t)| t.map(|t| (n, t))).collect();
                    ret = match (ret, named) {
                        (Some(Ty::Unit), Some(mut os)) if os.len() == 1 => os.pop().map(|x| x.1),
                        (Some(Ty::Unit), Some(os)) => Some(Ty::Tuple(os)),
                        (Some(r), Some(os)) => Some(Ty::Tuple(std::iter::once((String::new(), r)).chain(os).collect())),
                        _ => None,
                    };
                }
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
                m.methods.entry(tv).or_default().push(Sig { name, recv, params, ret, skip: None, src: f.get(3).unwrap_or(&"").to_string(), generics, thread_bounds: Vec::new(), call: None });
            }
            "end" => {
                m.types.extend(def.take());
                cur = None;
            }
            "other" if f.len() >= 3 => m.left_out.push(format!("{} ({})", f[1], f[2])),
            _ => {}
        }
    }
    // an overload with out parameters after its plain twin (both are Parse(s) to Volt: the first
    // keeps the name)
    for ms in m.methods.values_mut() {
        ms.sort_by_key(|s| s.params.iter().any(|(_, t)| matches!(t, Some(Ty::Out(..)))));
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
    /// the .NET install bolt found, which the program's hostfxr is told
    root: PathBuf,
}

/// between call() and function(): a void method whose out parameters are its results is a
/// statement, then v is VOID-separated (the one out's local, or nothing the tuple's store reads)
const VOID: &str = "\u{1}";

impl Dotnet {
    /// a type as C# spells it (an out parameter's local, a delegate's result)
    fn cs_ty(&self, g: &Gen, t: &Ty) -> Option<String> {
        Some(match t {
            Ty::Prim(x) => cs(x).to_string(),
            Ty::Char => "char".into(),
            Ty::Str | Ty::String => "string".into(),
            Ty::Slice(e, _) => format!("{}[]", self.cs_ty(g, e)?),
            Ty::Opt(e) => format!("{}?", self.cs_ty(g, e)?),
            Ty::Named(_) => self.path(&g.info(t)?.def),
            _ => return None,
        })
    }

    /// a C# lambda calling Volt closure a's trampoline (its data in a_k, which holds it until .NET
    /// collects the lambda): typed parameters, so C# picks the overload and makes it the
    /// parameter's delegate type (Func, Action or a named one)
    fn lambda(&self, ps: &[Ty], r: &Ty, a: &str) -> Option<String> {
        let (mut lps, mut fps, mut args, mut pins) = (Vec::new(), vec!["IntPtr".to_string()], vec![format!("{a}_k.Env")], Vec::new());
        for (i, p) in ps.iter().enumerate() {
            let x = format!("{a}_x{i}");
            match p {
                Ty::Prim("bool") => {
                    lps.push(format!("bool {x}"));
                    fps.push("byte".into());
                    args.push(format!("(byte)({x} ? 1 : 0)"));
                }
                Ty::Prim(n) => {
                    lps.push(format!("{} {x}", cs(n)));
                    fps.push(cs(n).into());
                    args.push(x);
                }
                Ty::Char => {
                    lps.push(format!("char {x}"));
                    fps.push("uint".into());
                    args.push(format!("(uint){x}"));
                }
                // text: its UTF-8 bytes, pinned for the call
                Ty::Str | Ty::String => {
                    lps.push(format!("string {x}"));
                    fps.extend(["byte*".to_string(), "nuint".to_string()]);
                    pins.push(x.clone());
                    args.extend([format!("{x}_p"), format!("(nuint){x}_b.Length")]);
                }
                _ => return None,
            }
        }
        let (ret, body) = match r {
            Ty::Unit => ("void", "$f;\n        GC.KeepAlive($k);".to_string()),
            Ty::Prim("bool") => ("byte", "var $r = $f != 0;\n        GC.KeepAlive($k);\n        return $r;".to_string()),
            Ty::Prim(n) => (cs(n), "var $r = $f;\n        GC.KeepAlive($k);\n        return $r;".to_string()),
            Ty::Char => ("uint", "var $r = (char)$f;\n        GC.KeepAlive($k);\n        return $r;".to_string()),
            // text: Volt puts its copy in a box the trampoline is given (put_glue)
            Ty::String => {
                fps.push("IntPtr".into());
                args.push(format!("GCHandle.ToIntPtr({a}_h)"));
                ("void", "var $r = new string[1];\n        var $h = GCHandle.Alloc($r);\n        try {\n            $f;\n        } finally {\n            $h.Free();\n        }\n        GC.KeepAlive($k);\n        return $r[0];".to_string())
            }
            _ => return None,
        };
        fps.push(ret.to_string());
        let f = format!("((delegate* unmanaged<{}>)(void*){a})({})", fps.join(", "), args.join(", "));
        // (its locals named for a: a lambda's can't be the enclosing function's)
        let mut body = body.replace("$k", &format!("{a}_k")).replace("$r", &format!("{a}_r")).replace("$h", &format!("{a}_h")).replace("$f", &f);
        for x in pins.iter().rev() {
            body = format!("var {x}_b = Encoding.UTF8.GetBytes({x} ?? \"\");\n        fixed (byte* {x}_p = {x}_b) {{\n        {}\n        }}", body.replace('\n', "\n    "));
        }
        Some(format!("({}) => {{\n        {body}\n    }}", lps.join(", ")))
    }

    fn path(&self, def: &TypeDef) -> String {
        if let Some(n) = &def.rust_name {
            return format!("global::{n}");
        }
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
            Ty::Str | Ty::String => {
                p.params.extend([format!("byte* {a}"), format!("nuint {a}_n")]);
                p.arg = format!("S({a}, {a}_n)");
            }
            // ref: Volt's memory (or the shim's copy of it) passed by ref; what .NET writes goes back
            Ty::Ref(x, true) => match &**x {
                Ty::Prim("bool") => {
                    p.params.push(format!("byte* {a}"));
                    p.pre.push(format!("var {a}_r = *{a} != 0;"));
                    p.arg = format!("ref {a}_r");
                    p.post.push(format!("*{a} = (byte)({a}_r ? 1 : 0);"));
                }
                Ty::Prim(n) => {
                    p.params.push(format!("{}* {a}", cs(n)));
                    p.arg = format!("ref *{a}");
                }
                Ty::Named(_) => {
                    let ti = g.info(x)?;
                    let (path, mg) = (self.path(&ti.def), Gen::mangle(&ti.def));
                    match ti.kind {
                        Kind::Plain => {
                            p.params.push(format!("V_{mg}* {a}"));
                            p.pre.push(format!("var {a}_r = From_{mg}(*{a});"));
                            p.arg = format!("ref {a}_r");
                            p.post.push(format!("*{a} = To_{mg}({a}_r);"));
                        }
                        // the object Volt's handle holds: one .NET points it at instead is the
                        // handle's now
                        Kind::Handle => {
                            p.params.push(format!("IntPtr {a}"));
                            p.pre.push(format!("var {a}_r = H<{path}>({a});"));
                            p.arg = format!("ref {a}_r");
                            p.post.extend([format!("var {a}_g = GCHandle.FromIntPtr({a});"), format!("{a}_g.Target = {a}_r;")]);
                        }
                        Kind::Enum => return None,
                    }
                }
                _ => return None,
            },
            // out: a local of the shim's, which the result reads
            Ty::Out(x, n) => {
                p.pre.push(format!("{} out_{n} = default;", self.cs_ty(g, x)?));
                p.arg = format!("out out_{n}");
            }
            // a Volt fn value: a lambda over its trampoline, holding it until .NET collects it
            Ty::Fn(ps, r, _, _) => {
                p.params.extend([format!("IntPtr {a}"), format!("IntPtr {a}_env"), format!("IntPtr {a}_drop")]);
                p.pre.push(format!("var {a}_k = new VoltFn({a}_env, {a}_drop);"));
                p.arg = self.lambda(ps, r, a)?;
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
            Ty::Str | Ty::String => ShimOut { params: vec![format!("byte** {o}"), format!("nuint* {o}_n")], store: format!("PutStr($v, {o}, {o}_n);") },
            // several results (out parameters): each element's outs (o0, o1...); an out
            // parameter's value is its local, the method's own (unnamed) the call's
            Ty::Tuple(es) => {
                let (mut params, mut stores) = (Vec::new(), Vec::new());
                for (i, (n, t)) in es.iter().enumerate() {
                    let x = self.out(g, t, &format!("{o}{i}"), false)?;
                    params.extend(x.params);
                    stores.push(if n.is_empty() { x.store } else { x.store.replace("$v", &format!("out_{n}")) });
                }
                ShimOut { params, store: stores.join("\n            ") }
            }
            // a delegate: a handle to it (fn_glue calls it)
            Ty::Fn(..) => ShimOut { params: vec![format!("IntPtr* {o}")], store: format!("*{o} = NewH($v);") },
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
        let call = format!("{target}.{}({})", s.call.as_deref().unwrap_or(&s.name), args.join(", "));
        // a void method whose out parameters are its results: the call is a statement, and v the
        // one out's local (several: the tuple's store reads each)
        let outs: Vec<&str> = s.params.iter().filter_map(|(_, t)| if let Some(Ty::Out(_, n)) = t { Some(n.as_str()) } else { None }).collect();
        let own_value = matches!(&s.ret, Some(Ty::Tuple(es)) if es.first().is_some_and(|e| e.0.is_empty()));
        if !outs.is_empty() && !own_value {
            let v = if outs.len() == 1 { format!("out_{}", outs[0]) } else { "0".into() };
            return format!("{VOID}{call}{VOID}{v}");
        }
        call
    }

    fn function(&self, sym: &str, params: &[String], pre: &[String], call: &str, post: &[String], store: Option<&str>, _res: bool) -> String {
        let mut body = String::new();
        for l in pre {
            let _ = writeln!(body, "            {l}");
        }
        // (a void method's out parameters: the call, then v; see call)
        let (call, value) = match call.strip_prefix(VOID).and_then(|c| c.split_once(VOID)) {
            Some((c, v)) => (c, Some(v)),
            None => (call, None),
        };
        match store {
            Some(st) => {
                match value {
                    Some(v) => {
                        let _ = writeln!(body, "            {call};\n            var v = {v};");
                    }
                    None => {
                        let _ = writeln!(body, "            var v = {call};");
                    }
                }
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

    // a delegate .NET gave: called through its handle (DynamicInvoke, whatever its delegate type)
    fn fn_glue(&self, g: &Gen, sym: &str, ps: &[Ty], r: &Ty, _once: bool) -> Option<String> {
        let (mut params, mut pre, mut args, mut post) = (vec!["IntPtr h".to_string()], Vec::new(), Vec::new(), Vec::new());
        for (i, p) in ps.iter().enumerate() {
            let x = self.param(g, p, &format!("a{i}"))?;
            params.extend(x.params);
            pre.extend(x.pre);
            args.push(x.arg);
            post.extend(x.post);
        }
        let mut call = format!("H<Delegate>(h).DynamicInvoke({})", args.join(", "));
        let store = if *r == Ty::Unit {
            None
        } else {
            let o = self.out(g, r, "o", false)?;
            params.extend(o.params);
            call = format!("({})({call})", self.cs_ty(g, r)?);
            Some(o.store)
        };
        let mut f = self.function(&format!("{sym}_call"), &params, &pre, &call, &post, store.as_deref(), false);
        let _ = write!(f, "    [UnmanagedCallersOnly]\n    public static void {sym}_drop(IntPtr h) => GCHandle.FromIntPtr(h).Free();\n\n");
        Some(f)
    }

    // a Volt closure's text result: into the box the lambda gave
    fn put_glue(&self, sym: &str) -> Option<String> {
        Some(format!("    [UnmanagedCallersOnly]\n    public static void {sym}(IntPtr o, byte* p, nuint n) => ((string[])GCHandle.FromIntPtr(o).Target)[0] = S(p, n);\n\n"))
    }

    fn loader(&self, _g: &Gen) -> Option<String> {
        let q = |p: &Path| p.display().to_string().replace('\\', "\\\\").replace('"', "\\\"");
        Some(LOADER.replace("{CONFIG}", &q(&self.asm.with_extension("runtimeconfig.json"))).replace("{ASM}", &q(&self.asm)).replace("{NAME}", &self.asm_name).replace("{ROOT}", &q(&self.root)))
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

    // a Volt closure a delegate calls: freed (its drop) when .NET collects the delegate
    sealed class VoltFn {
        public readonly IntPtr Env;
        readonly IntPtr drop;

        public VoltFn(IntPtr env, IntPtr drop) {
            Env = env;
            this.drop = drop;
        }

        ~VoltFn() => ((delegate* unmanaged<IntPtr, void>)(void*)drop)(Env);
    }

    // an exception: the program stops with its text, as a Volt panic does (a delegate's, not the
    // DynamicInvoke wrapping it)
    static void Fail(Exception e) {
        if (e is System.Reflection.TargetInvocationException t && t.InnerException != null) e = t.InnerException;
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

    // hostfxr_initialize_parameters: its size, the host's path (none) and .NET's root (the install
    // bolt found: a hostfxr the system finds first, PowerShell's on Windows, would guess another)
    struct fxr_params {
        size: usize;
        host_path: void* = null;
        dotnet_root: void* = null;
    }

    fn unit(out: std::vec<u8>&, u: u32) -> void {
        out.push(@cast<u8>(u & 0xFF)) catch @panic("out of memory");
        out.push(@cast<u8>(u >> 8)) catch @panic("out of memory");
    }

    // s as hostfxr's char_t, ending in a zero: UTF-16 on Windows (wchar_t), UTF-8 elsewhere
    fn char_t(s: str) -> std::vec<u8> {
        var out: std::vec<u8> = {};
        comptime if (@cfg("os", "windows")) {
            var i: usize = 0;
            while (i < s.len) {
                val b = @cast<u32>(s[i]);
                var c = b;
                var n: usize = 1;
                if (b >= 0xF0) {
                    c = b & 0x07;
                    n = 4;
                } else if (b >= 0xE0) {
                    c = b & 0x0F;
                    n = 3;
                } else if (b >= 0xC0) {
                    c = b & 0x1F;
                    n = 2;
                }
                for (k) in 1..n {
                    if (i + k < s.len) {
                        c = (c << 6) | (@cast<u32>(s[i + k]) & 0x3F);
                    }
                }
                i += n;
                if (c >= 0x10000) {
                    unit(&out, 0xD800 | ((c - 0x10000) >> 10));
                    unit(&out, 0xDC00 | ((c - 0x10000) & 0x3FF));
                } else {
                    unit(&out, c);
                }
            }
            unit(&out, 0);
        } else {
            for (i) in 0..s.len {
                out.push(s[i]) catch @panic("out of memory");
            }
            out.push(0) catch @panic("out of memory");
        }
        return out;
    }

    // the address of the glue's method name; .NET starts the first time
    fn load(slot: void**, name: str) -> void* {
        if (*slot != null) {
            return *slot;
        }
        if (load_fp == null) {
            val config = char_t("{CONFIG}");
            val root = char_t("{ROOT}");
            var params: fxr_params = { size: @sizeof(fxr_params), dotnet_root: @cast<void*>(root.items().ptr) };
            var h: void* = null;
            val rc = hostfxr_initialize_for_runtime_config(@cast<cstr>(config.items().ptr), @cast<void*>(&params), &h);
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
        val a = char_t("{ASM}");
        val t = char_t("VoltShim, {NAME}");
        val m = char_t(name);
        // UNMANAGEDCALLERSONLY_METHOD: (const char_t*)-1
        val rc = f(@cast<cstr>(a.items().ptr), @cast<cstr>(t.items().ptr), @cast<cstr>(m.items().ptr), @cast<void*>(~@cast<usize>(0)), null, slot);
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
        let desc = "type\tGeo.Point\tstruct\nfield\tX\ttrue\tf64\nfield\tY\ttrue\tf64\nfunc\tnew\tctor\nparam\tx\tf64\nparam\ty\tf64\nresult\tGeo.Point\nend\nfunc\tDist\tinst\nparam\to\tGeo.Point\nresult\tf64\nend\nend\ntype\tGeo.Shape\tclass\nsuper\tGeo.IArea\nfunc\tName\tget\nresult\tstring\nend\nfunc\tName\tset\nparam\tvalue\tstring\nresult\tvoid\nend\nfunc\tGeo.IArea\tcast\nresult\tGeo.IArea\nend\nfunc\tFind\tstatic\nparam\txs\ti32[]\nparam\tx\ti32?\nresult\ti32?\nend\nend\ntype\tGeo.IArea\tinterface\nend\nother\tGeo.Odd\tit's inside a generic type\n";
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
        assert_eq!(m.left_out, ["Geo.Odd (it's inside a generic type)"]);
    }

    #[test]
    fn import_dotnet_generics_refs_delegates() {
        let desc = "type\tGeo.Box`1\tclass\ntparam\tT\nfunc\tnew\tctor\nparam\tv\t$T\nresult\tGeo.Box`1<$T>\nend\nfunc\tGet\tinst\nresult\t$T\nend\nfunc\tValue\tget\nresult\t$T\nend\nend\n\
            type\tGeo.Gen\tstatic\nfunc\tTryParse\tstatic\nparam\ts\tstring\nparam\tv\tout:i32\nresult\tbool\nend\nfunc\tBump\tstatic\nparam\tx\tref:i32\nresult\tvoid\nend\n\
            func\tHalf\tstatic\nparam\tx\ti32\nparam\th\tout:i32\nresult\tvoid\nend\nfunc\tSplit\tstatic\nparam\tw\tout:i32\nparam\tf\tout:string\nresult\tvoid\nend\n\
            func\tApply\tstatic\nparam\tf\tfn(i32,string)string\nresult\ti32\nend\nfunc\tMax\tstatic\ntparam\tT\nparam\ta\t$T\nparam\tb\t$T\nresult\t$T\nend\n\
            func\tPick\tstatic\ntparam\tT\nparam\txs\t$T[]\nresult\t$T?\nend\nend\n";
        let (mut m, mut lang) = read(desc);
        let bx = m.types.iter().find(|t| t.name == "Box").unwrap();
        assert!(bx.generic && bx.opaque && bx.params == ["T"]);
        assert_eq!(m.methods["Box"][0].ret, Some(Ty::SelfTy));
        assert_eq!(m.methods["Box"][1].ret, Some(Ty::Generic("T".into())));
        let gs = |n: &str| m.methods["Gen"].iter().find(|s| s.name == n).unwrap().clone();
        // out: results (a void method's one out is its value); ref: a reference; a delegate: a closure .NET may keep
        assert_eq!(gs("TryParse").params[1].1, Some(Ty::Out(Box::new(Ty::Prim("i32")), "v".into())));
        assert_eq!(gs("TryParse").ret, Some(Ty::Tuple(vec![(String::new(), Ty::Prim("bool")), ("v".into(), Ty::Prim("i32"))])));
        assert_eq!(gs("Bump").params[0].1, Some(Ty::Ref(Box::new(Ty::Prim("i32")), true)));
        assert_eq!(gs("Half").ret, Some(Ty::Prim("i32")));
        assert_eq!(gs("Split").ret, Some(Ty::Tuple(vec![("w".into(), Ty::Prim("i32")), ("f".into(), Ty::String)])));
        assert_eq!(gs("Apply").params[0].1, Some(Ty::Fn(vec![Ty::Prim("i32"), Ty::Str], Box::new(Ty::String), FnPass::Boxed, false)));
        assert_eq!(gs("Max").generics, ["T"]);
        assert_eq!((&gs("Pick").params[0].1, &gs("Pick").ret), (&Some(Ty::Slice(Box::new(Ty::Generic("T".into())), true)), &Some(Ty::Opt(Box::new(Ty::Generic("T".into()))))));
        // the instances a program asked for: Max<int> and Box<int>, its members and properties too
        let made = instances(&mut m, &mut lang, &["Gen::Max\ti32".to_string(), "Box\ti32".to_string()], "geo", &BTreeMap::new());
        assert_eq!(made, [None, Some("Box__i32".to_string())]);
        let max = m.methods["Gen"].iter().find(|s| s.name == "Max__i32").unwrap();
        assert_eq!((max.call.as_deref(), &max.params[0].1), (Some("Max<int>"), &Some(Ty::Prim("i32"))));
        assert_eq!(m.types.iter().find(|t| t.name == "Box__i32").and_then(|t| t.rust_name.as_deref()), Some("Geo.Box<int>"));
        assert_eq!(m.methods["Box__i32"][1].ret, Some(Ty::Prim("i32")));
        assert_eq!(lang.props.get(&("Box__i32".to_string(), "Value".to_string())).map(String::as_str), Some("Value"));
        // a Volt type of the program's own isn't a type argument .NET has
        let _ = instances(&mut m, &mut lang, &["Gen::Max\tmine".to_string()], "geo", &BTreeMap::new());
        assert!(m.left_out.iter().any(|l| l.starts_with("Gen::Max<mine>")));
        assert_eq!(volt_type("Geo.Outer`1+Inner`2"), "Outer_Inner");
        // a plain type keeps a name a generic one shares; an out overload comes after its plain twin
        let (m2, _) = read("type\tGeo.Tag`1\tclass\ntparam\tT\nend\ntype\tGeo.Tag\tclass\nfunc\tParse\tstatic\nparam\ts\tstring\nparam\tv\tout:i32\nresult\tbool\nend\nfunc\tParse\tstatic\nparam\ts\tstring\nresult\ti32\nend\nend\n");
        assert_eq!((m2.types.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(), m2.left_out.clone()), (vec!["Tag"], vec!["Geo.Tag`1 (another type is called Tag)".to_string()]));
        assert_eq!(m2.methods["Tag"][0].params.len(), 1);
        assert_eq!(cs_errors("/x/Shim.cs(3,9): error CS0311: The type 'Geo.Shape' can't be used [/x/Shim.csproj]"), "/x/Shim.cs(3,9): error: CS0311: The type 'Geo.Shape' can't be used");
    }
}
