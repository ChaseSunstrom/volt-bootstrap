// use { "geom.go" } as NAME; — an ordinary Go package, called from Volt. bolt asks Go itself what
// the package exports (DESCRIBE: go/types, run with `go run`), writes a cgo shim (a package that
// imports it and //exports a C function for each) and the Volt side (glue.rs). A program has one Go
// runtime, so the shims are linked as one: each import's flags name its shim (`go-package DIR`),
// and voltc has `bolt import go-link` build them all with go build -buildmode=c-archive. Nothing in
// the Go code changes.
//
//   int, uint -> isize, usize; int8..uint64, float32, float64, bool, byte, rune -> the same sizes
//   string -> str in, std::string out; []T -> T[..] in (the call sees Volt's memory; the package's
//   types are converted, and Go's changes come back), std::vec<T> out; [N]T the same (N checked)
//   (T, error) -> go_error!T (the error's text); error -> go_error!void; (T, bool) -> T?; several
//   results -> a tuple (named as Go names them), (A, B, error) -> go_error!(A, B)
//   ...T (variadic) -> T[..]
//   a struct whose fields are all exported numbers, bools, enums or such structs -> a Volt struct,
//   by value; any other struct -> an owned handle (a runtime/cgo.Handle: Go's collector keeps the
//   value while Volt holds it; copy copies the Go value as Go assigns it, new() is its zero value);
//   *T -> T& in, a handle to that same value out; *int and such -> isize& in, a handle out
//   type T int with constants of type T -> a Volt enum with the same values; any other named basic
//   type (time.Duration too) -> a Volt struct { value: T } (a string one: a handle)
//   map[K]V, map[K]struct{}, chan T, []T and [N]T of other types, *T of others, any other type ->
//   a handle (get, put, len, keys...; add, contains...; send, recv, close; get, put, push), named
//   or not, with the named type's own methods
//   func(...) -> a Volt fn value in (Go keeps it until its collector drops it), a value with call()
//   out; an interface whose methods take and give numbers, bools and text -> a Volt trait (Go's
//   types having its methods attach it; dyn_T holds Go's values of it); any other interface -> dyn_T
//   generic funcs and types -> Volt generics: each instance a program uses is built (go checks
//   its constraints)
//   exported constants of every type -> vals; package variables -> NAME() and set_NAME(v)
//   a panic -> stops the program with its text; each function's try_ form gives it as an error
use super::glue::{ident, volt_ty, FnPass, Gen, Kind, Lang, Model, Recv, ShimOut, ShimParam, Sig, Ty, TraitDef, TypeDef, TypeInfo};
use super::{arg_path, fresh, save, stamp, Made, Req};
use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn import(r: &Req) -> Result<(), String> {
    // the package: the directory of the files named (Go's unit is a directory), or the one named
    let mut dir: Option<PathBuf> = None;
    for a in &r.args {
        let p = arg_path(r, a);
        let d = if p.is_dir() {
            p.clone()
        } else if p.is_file() {
            p.parent().map_or_else(|| PathBuf::from("."), Path::to_path_buf)
        } else {
            return Err(format!("use go: there's no {}", p.display()));
        };
        if dir.as_ref().is_some_and(|x| *x != d) {
            return Err(format!("use go {{ ... }} as {}: a Go package is one directory, and these are in two", r.alias));
        }
        dir = Some(d);
    }
    let dir = dir.ok_or(format!("use go {{ \"file.go\" }} as {}: name a Go file or a package's directory", r.alias))?;
    let module = enclosing_module(&dir);
    // what the build reads: the package's sources, or in a module every package's (one it imports
    // may have changed)
    let mut files = Vec::new();
    match &module {
        Some((root, _)) => {
            go_sources(root, true, &mut files);
            files.extend([root.join("go.mod"), root.join("go.sum")]);
        }
        None => go_sources(&dir, false, &mut files),
    }
    // the package's own inputs (the instances go rejected stay rejected until these change)
    let own_st = stamp(&files, "go package");
    // the instances of its generics a program asked for (voltc writes them)
    if r.out.join("instances").is_file() {
        files.push(r.out.join("instances"));
    }
    let st = stamp(&files, &format!("go {} {} release={}", r.alias, dir.display(), r.release));
    if fresh(r, &st) {
        return Ok(());
    }

    let go = std::env::var("GO").unwrap_or_else(|_| "go".into());
    let desc = describe(r, &go, &dir)?;
    let pkg = desc.lines().find_map(|l| l.strip_prefix("package\t")).unwrap_or("").to_string();

    // what the shim imports: the package where it is, or (a main package, or one outside any
    // module) a copy that can be imported. Module names carry the import's directory name, unique
    // among a program's imports
    let shim_dir = r.out.join("shim");
    std::fs::create_dir_all(&shim_dir).map_err(|e| format!("can't make {}: {e}", shim_dir.display()))?;
    let out = std::fs::canonicalize(&r.out).unwrap_or_else(|_| r.out.clone());
    let id: String = out.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect();
    let shim_pkg = format!("volt_{id}");
    let user_mod = format!("volt_user_{id}");
    let mut gomod = format!("module {shim_pkg}\n\ngo 1.21\n");
    let mut needs = String::new();
    if let Some((root, path)) = &module {
        let _ = write!(needs, "\nrequire {path} v0.0.0\n");
        let _ = write!(gomod, "{needs}replace {path} => {}\n", root.display());
        if let Ok(sum) = std::fs::read_to_string(root.join("go.sum")) {
            crate::build::write_if_changed(&shim_dir.join("go.sum"), &sum)?;
        }
    }
    let path = match &module {
        Some((root, path)) if pkg != "main" => match dir.strip_prefix(root).ok().filter(|x| !x.as_os_str().is_empty()) {
            Some(rel) => format!("{path}/{}", rel.display()),
            None => path.clone(),
        },
        _ => {
            let user = r.out.join("user");
            let _ = std::fs::remove_dir_all(&user);
            std::fs::create_dir_all(&user).map_err(|e| format!("can't make {}: {e}", user.display()))?;
            let mut srcs = Vec::new();
            go_sources(&dir, false, &mut srcs);
            for f in srcs {
                let name = f.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                let to = user.join(&name);
                if name.ends_with(".go") && pkg == "main" {
                    let src = std::fs::read_to_string(&f).map_err(|e| format!("can't read {}: {e}", f.display()))?;
                    std::fs::write(&to, rename_main(&src)).map_err(|e| format!("can't write {}: {e}", to.display()))?;
                } else {
                    std::fs::copy(&f, &to).map_err(|e| format!("can't copy {}: {e}", f.display()))?;
                }
            }
            std::fs::write(user.join("go.mod"), format!("module {user_mod}\n\ngo 1.21\n{needs}")).map_err(|e| format!("can't write go.mod: {e}"))?;
            let _ = write!(gomod, "\nrequire {user_mod} v0.0.0\nreplace {user_mod} => {}\n", out.join("user").display());
            user_mod
        }
    };
    crate::build::write_if_changed(&shim_dir.join("go.mod"), &gomod)?;

    // the shim, with the instances of generics asked for, built now (so an error in the Go code
    // shows at the use line; go-link's build reuses the work): its Volt side, or go's errors
    let build = |lines: &[String], _skip: &BTreeMap<String, String>| -> Result<(String, String), String> {
        let (model, lang) = read(&desc, &r.alias, &path, &shim_pkg, lines);
        let (mut shim, volt) = Gen::new(&model, &r.alias, &lang).write("the package");
        // nothing of the package is called (m.X): imported for its init alone
        let uses = shim.lines().skip(1).any(|l| l.match_indices("m.").any(|(i, _)| i == 0 || !(l.as_bytes()[i - 1].is_ascii_alphanumeric() || l.as_bytes()[i - 1] == b'_')));
        if !uses {
            shim = shim.replacen("\tm \"", "\t_ \"", 1);
        }
        crate::build::write_if_changed(&shim_dir.join("shim.go"), &shim)?;
        let o = Command::new(&go).args(["build", "."]).current_dir(&shim_dir).env("CGO_ENABLED", "1").env("GOFLAGS", "-mod=mod").output().map_err(|e| format!("use go: can't run {go}: {e} (set $GO to the go to use)"))?;
        if o.status.success() { Ok((volt, String::new())) } else { Err(go_errors(&String::from_utf8_lossy(&o.stderr))) }
    };
    let methods = |l: &str, _skip: &BTreeMap<String, String>| -> Vec<String> {
        let (m, _) = read(&desc, &r.alias, &path, &shim_pkg, std::slice::from_ref(&l.to_string()));
        let inst = instance_name(l);
        m.methods.get(&inst).map(|ms| ms.iter().map(|s| s.name.clone()).collect()).unwrap_or_default()
    };
    let (volt, _) = super::with_instances(r, &own_st, build, methods, |e| format!("use go: go couldn't build the glue for {}:\n{e}", dir.display()))?;
    save(r, &Made { volt, flags: vec![format!("go-package {}", out.join("shim").display())], deps: files }, &st)
}

/// go build's errors (file:line:col: what), marked as errors (file:line:col: error: what) the way
/// with_instances finds an instance's reason
fn go_errors(e: &str) -> String {
    e.lines()
        .map(|l| {
            let mut parts = l.splitn(4, ':');
            let (f, line, col) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""), parts.next().unwrap_or(""));
            match parts.next() {
                Some(what) if f.ends_with(".go") && line.parse::<u32>().is_ok() && col.parse::<u32>().is_ok() && !what.trim_start().starts_with("error:") => format!("{f}:{line}:{col}: error:{what}"),
                _ => l.to_string(),
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// an instance's Volt name, from its line (Stack\tisize: Stack__isize), as voltc names it
fn instance_name(line: &str) -> String {
    let mut parts = line.split('\t');
    let path = parts.next().unwrap_or("");
    let name = path.rsplit("::").next().unwrap_or(path);
    format!("{name}__{}", parts.map(ident).collect::<Vec<_>>().join("_"))
}

/// the generic Volt types Go's composites are instances of (map<K, V>, arrayN<T> for [N]T...)
fn is_composite_kind(n: &str) -> bool {
    matches!(n, "map" | "set" | "chan" | "ptr" | "slice") || n.strip_prefix("array").is_some_and(|x| x.parse::<usize>().is_ok())
}

fn generic_def(name: &str, params: &[&str]) -> TypeDef {
    TypeDef { module: Vec::new(), name: name.into(), generic: true, fields: None, variants: None, is_enum: false, clone: true, opaque: false, params: params.iter().map(|p| p.to_string()).collect(), rust_name: None }
}

/// bolt import go-link --out OUT -- DIR...: a program's use go glue packages (DIRs) as one library,
/// with the one Go runtime a program can have: a main package importing them all, built with
/// go build -buildmode=c-archive
pub fn link(r: &Req) -> Result<(), String> {
    let (mut files, mut sums, mut imports) = (Vec::new(), BTreeSet::new(), String::new());
    let mut gomod = String::from("module volt_program\n\ngo 1.21\n");
    for d in &r.args {
        let d = PathBuf::from(d);
        let text = std::fs::read_to_string(d.join("go.mod")).map_err(|e| format!("use go: can't read {}: {e}", d.join("go.mod").display()))?;
        let module = text.lines().find_map(|l| l.strip_prefix("module ")).unwrap_or("").trim().to_string();
        let _ = write!(gomod, "\nrequire {module} v0.0.0\nreplace {module} => {}\n", d.display());
        // what the glue requires and replaces: replacements count in the main module alone
        for l in text.lines().filter(|l| l.starts_with("require ") || l.starts_with("replace ")) {
            if !gomod.lines().any(|x| x == l) {
                let _ = writeln!(gomod, "{l}");
            }
        }
        if let Ok(s) = std::fs::read_to_string(d.join("go.sum")) {
            sums.extend(s.lines().map(str::to_string));
        }
        let _ = writeln!(imports, "\t_ \"{module}\"");
        files.extend([d.join("shim.go"), d.join("go.mod"), d.join("go.sum")]);
        // and the Go code it calls: its import's sources
        if let Some(deps) = d.parent().and_then(|p| std::fs::read_to_string(p.join("import.deps")).ok()) {
            files.extend(deps.lines().filter(|l| !l.is_empty()).map(PathBuf::from));
        }
    }
    let st = stamp(&files, &format!("go-link {}", r.args.join(" ")));
    if fresh(r, &st) {
        return Ok(());
    }
    let main = r.out.join("main");
    std::fs::create_dir_all(&main).map_err(|e| format!("can't make {}: {e}", main.display()))?;
    crate::build::write_if_changed(&main.join("go.mod"), &gomod)?;
    crate::build::write_if_changed(&main.join("go.sum"), &sums.into_iter().map(|l| l + "\n").collect::<String>())?;
    crate::build::write_if_changed(&main.join("main.go"), &format!("// a Volt program's use go imports, with one Go runtime (written by bolt import go-link)\npackage main\n\nimport (\n{imports})\n\nfunc main() {{}}\n"))?;
    let lib_file = std::fs::canonicalize(&r.out).unwrap_or_else(|_| r.out.clone()).join("libvolt_go.a");
    let go = std::env::var("GO").unwrap_or_else(|_| "go".into());
    let mut args = vec!["build", "-buildmode=c-archive", "-o"];
    let lib = lib_file.display().to_string();
    args.extend([lib.as_str(), "."]);
    build(&go, &main, &args, &main)?;
    save(r, &Made { volt: String::new(), flags: vec![lib, "-lpthread".into()], deps: files }, &st)
}

/// go ARGS in dir (cgo on, go.mod and go.sum kept up to date); what went wrong, for the code in what
fn build(go: &str, dir: &Path, args: &[&str], what: &Path) -> Result<(), String> {
    let o = Command::new(go).args(args).current_dir(dir).env("CGO_ENABLED", "1").env("GOFLAGS", "-mod=mod").output().map_err(|e| format!("use go: can't run {go}: {e} (set $GO to the go to use)"))?;
    if !o.status.success() {
        return Err(format!("use go: go couldn't build the glue for {}:\n{}", what.display(), String::from_utf8_lossy(&o.stderr)));
    }
    Ok(())
}

/// the files go build reads in dir (not its tests), sorted; with deep, in the directories below too
/// (not hidden ones, testdata or vendor)
fn go_sources(dir: &Path, deep: bool, out: &mut Vec<PathBuf>) {
    const EXTS: &[&str] = &["go", "c", "h", "s", "S", "cc", "cpp", "cxx", "hh", "hpp", "hxx", "m", "syso"];
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    let mut paths: Vec<PathBuf> = rd.flatten().map(|e| e.path()).collect();
    paths.sort();
    for p in paths {
        let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        if p.is_dir() {
            if deep && !name.starts_with('.') && !name.starts_with('_') && name != "testdata" && name != "vendor" {
                go_sources(&p, true, out);
            }
        } else if !name.ends_with("_test.go") && p.extension().is_some_and(|e| EXTS.contains(&e.to_string_lossy().as_ref())) {
            out.push(p);
        }
    }
}

/// the module dir is in: its root (where go.mod is) and its path
fn enclosing_module(dir: &Path) -> Option<(PathBuf, String)> {
    let mut d = Some(dir);
    while let Some(x) = d {
        if let Ok(text) = std::fs::read_to_string(x.join("go.mod")) {
            let path = text.lines().find_map(|l| l.trim().strip_prefix("module ")).map(|p| p.trim().trim_matches('"').to_string())?;
            return Some((x.to_path_buf(), path));
        }
        d = x.parent();
    }
    None
}

/// a main package's source as an importable package: its package clause renamed
fn rename_main(src: &str) -> String {
    let mut done = false;
    src.lines()
        .map(|l| {
            let rest = l.trim_start().strip_prefix("package main");
            if !done && rest.is_some_and(|r| r.is_empty() || r.starts_with([' ', '\t', '/', ';'])) {
                done = true;
                format!("package user{}", rest.unwrap_or(""))
            } else {
                l.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
        + "\n"
}

/// what the package at dir exports, as DESCRIBE prints it
fn describe(r: &Req, go: &str, dir: &Path) -> Result<String, String> {
    let d = r.out.join("describe");
    std::fs::create_dir_all(&d).map_err(|e| format!("can't make {}: {e}", d.display()))?;
    crate::build::write_if_changed(&d.join("go.mod"), "module volt_describe\n\ngo 1.21\n")?;
    crate::build::write_if_changed(&d.join("main.go"), DESCRIBE)?;
    let o = Command::new(go).args(["run", "."]).arg(dir).current_dir(&d).env("GOFLAGS", "-mod=mod").output().map_err(|e| format!("use go: can't run {go}: {e} (set $GO to the go to use)"))?;
    if !o.status.success() {
        return Err(format!("use go: can't read the package in {}:\n{}", dir.display(), String::from_utf8_lossy(&o.stderr)));
    }
    Ok(String::from_utf8_lossy(&o.stdout).into_owned())
}


/// a Go program printing a package's exported API, a declaration a line (tab-separated); its types
/// (TYPE) in a syntax of its own: int, Name, pN.Name (another package's), Name[T,U], *T, []T, [N]T,
/// map[K]V, chan T, <-chan T, chan<- T, func(A,...B)(R,S), struct{}, any, @N (anonymous):
///   package NAME
///   import pN PATH NAME (a package the API names), anon N GO_EXPR (an anonymous struct or interface)
///   func NAME RECV_TYPE|- none|val|ptr|iface, then src TEXT, tparam NAME, variadic, param NAME
///     TYPE, result NAME TYPE; end
///   struct NAME, then tparam NAME, field NAME exported TYPE; end (its methods follow, as funcs)
///   enum NAME, then value NAME N (in order); end
///   named NAME TYPE (a named type of a basic or other type), then tparam NAME; end
///   interface NAME SEALED (its methods follow, as funcs of kind iface)
///   impl TYPE INTERFACE val|ptr: TYPE (or *TYPE) has INTERFACE's methods
///   alias NAME TYPE, var NAME TYPE, const NAME TYPE LITERAL (a Volt literal; big: too big for
///   Go's numbers), other NAME WHY (what Volt can't use)
/// Other packages' named types the API names are described too, their methods one level deep
const DESCRIBE: &str = r#"package main

import (
	"fmt"
	"go/ast"
	"go/build"
	"go/constant"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

var (
	pkg     *types.Package
	out     strings.Builder
	head    strings.Builder
	aliases = map[*types.Package]string{}
	anons   int
	// other packages' named types the API names, described after the package's own, and how deep
	// (their methods are described one level deep)
	queue []*types.TypeName
	depth = map[*types.TypeName]int{}
	cur   int
	// a generic type's own type parameter names (its methods' receivers may name them otherwise)
	tpNames []string
	ifaces  []*types.TypeName
	typed   []*types.TypeName
)

func emit(format string, a ...any) { fmt.Fprintf(&out, format, a...) }

// a package's name in the shim: m for the package, pN for another
func alias(p *types.Package) string {
	if p == pkg {
		return "m"
	}
	a, ok := aliases[p]
	if !ok {
		a = "p" + strconv.Itoa(len(aliases)+1)
		aliases[p] = a
		fmt.Fprintf(&head, "import\t%s\t%s\t%s\n", a, p.Path(), p.Name())
	}
	return a
}

// a named type's name: Name for the package's, pN.Name for another's (described later), !Name
// for an internal package's (which only its own tree imports)
func named(o *types.TypeName) string {
	if o.Pkg() == nil || o.Pkg() == pkg {
		return o.Name()
	}
	if p := "/" + o.Pkg().Path() + "/"; strings.Contains(p, "/internal/") || strings.HasPrefix(p, "/vendor/") {
		return "!" + o.Name()
	}
	if _, ok := depth[o]; !ok {
		depth[o] = cur + 1
		queue = append(queue, o)
	}
	return alias(o.Pkg()) + "." + o.Name()
}

func ts(t types.Type) string {
	switch t := t.(type) {
	case *types.Alias:
		return ts(types.Unalias(t))
	case *types.Basic:
		switch t.Kind() {
		case types.UntypedBool:
			return "bool"
		case types.UntypedInt:
			return "int"
		case types.UntypedRune:
			return "int32"
		case types.UntypedFloat:
			return "float64"
		case types.UntypedComplex:
			return "complex128"
		case types.UntypedString:
			return "string"
		}
		return t.Name()
	case *types.Named:
		s := named(t.Obj())
		if a := t.TypeArgs(); a != nil && a.Len() > 0 {
			var xs []string
			for i := 0; i < a.Len(); i++ {
				xs = append(xs, ts(a.At(i)))
			}
			s += "[" + strings.Join(xs, ",") + "]"
		}
		return s
	case *types.TypeParam:
		if i := t.Index(); tpNames != nil && i < len(tpNames) {
			return tpNames[i]
		}
		return t.Obj().Name()
	case *types.Pointer:
		return "*" + ts(t.Elem())
	case *types.Slice:
		return "[]" + ts(t.Elem())
	case *types.Array:
		return "[" + strconv.FormatInt(t.Len(), 10) + "]" + ts(t.Elem())
	case *types.Map:
		return "map[" + ts(t.Key()) + "]" + ts(t.Elem())
	case *types.Chan:
		return [...]string{"chan ", "chan<- ", "<-chan "}[t.Dir()] + ts(t.Elem())
	case *types.Signature:
		return "func(" + tuple(t.Params(), t.Variadic()) + ")(" + tuple(t.Results(), false) + ")"
	case *types.Interface:
		if t.Empty() {
			return "any"
		}
	case *types.Struct:
		if t.NumFields() == 0 {
			return "struct{}"
		}
	}
	fmt.Fprintf(&head, "anon\t%d\t%s\n", anons, types.TypeString(t, alias))
	anons++
	return "@" + strconv.Itoa(anons-1)
}

func tuple(t *types.Tuple, variadic bool) string {
	var xs []string
	for i := 0; i < t.Len(); i++ {
		s := ts(t.At(i).Type())
		if variadic && i == t.Len()-1 {
			s = "..." + strings.TrimPrefix(s, "[]")
		}
		xs = append(xs, s)
	}
	return strings.Join(xs, ",")
}

func short(p *types.Package) string {
	if p == pkg {
		return ""
	}
	return p.Name()
}

func sig(name, recv, kind string, o types.Object, s *types.Signature) {
	emit("func\t%s\t%s\t%s\n", name, recv, kind)
	emit("src\t%s\n", strings.Join(strings.Fields(types.ObjectString(o, short)), " "))
	for i := 0; i < s.TypeParams().Len(); i++ {
		emit("tparam\t%s\n", s.TypeParams().At(i).Obj().Name())
	}
	if s.Variadic() {
		emit("variadic\n")
	}
	for i := 0; i < s.Params().Len(); i++ {
		p := s.Params().At(i)
		emit("param\t%s\t%s\n", p.Name(), ts(p.Type()))
	}
	for i := 0; i < s.Results().Len(); i++ {
		r := s.Results().At(i)
		emit("result\t%s\t%s\n", r.Name(), ts(r.Type()))
	}
	emit("end\n")
}

// text as a Volt string literal
func volt(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); {
		r, n := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == utf8.RuneError && n <= 1:
			fmt.Fprintf(&b, "\\x%02x", s[i])
		case r == '"' || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r == '\n':
			b.WriteString("\\n")
		case r == '\t':
			b.WriteString("\\t")
		case r == '\r':
			b.WriteString("\\r")
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, "\\x%02x", r)
		default:
			b.WriteString(s[i : i+n])
		}
		i += n
	}
	b.WriteByte('"')
	return b.String()
}

func float(v constant.Value) string {
	f, _ := constant.Float64Val(constant.ToFloat(v))
	if math.IsInf(f, 0) {
		return "big"
	}
	s := strconv.FormatFloat(f, 'f', -1, 64)
	if !strings.Contains(s, ".") {
		s += ".0"
	}
	return s
}

func konst(c *types.Const) {
	v := c.Val()
	b, _ := c.Type().Underlying().(*types.Basic)
	lit := "big"
	switch {
	case b == nil:
		emit("other\t%s\ta constant of type %s\n", c.Name(), ts(c.Type()))
		return
	case b.Info()&types.IsBoolean != 0:
		lit = strconv.FormatBool(constant.BoolVal(v))
	case b.Info()&types.IsString != 0:
		lit = volt(constant.StringVal(v))
	case b.Info()&types.IsInteger != 0:
		if x, ok := constant.Int64Val(constant.ToInt(v)); ok {
			lit = strconv.FormatInt(x, 10)
		} else if x, ok := constant.Uint64Val(constant.ToInt(v)); ok {
			lit = strconv.FormatUint(x, 10)
		}
	case b.Info()&types.IsFloat != 0:
		lit = float(v)
	case b.Info()&types.IsComplex != 0:
		re, im := float(constant.Real(v)), float(constant.Imag(v))
		if re != "big" && im != "big" {
			lit = re + "," + im
		}
	}
	emit("const\t%s\t%s\t%s\n", c.Name(), ts(c.Type()), lit)
}

// a named type (the package's, or another's), its methods when full
func describe(o *types.TypeName, full bool, enums map[*types.TypeName][]*types.Const) {
	name := named(o)
	if o.IsAlias() {
		emit("alias\t%s\t%s\n", name, ts(o.Type()))
		return
	}
	nt, ok := o.Type().(*types.Named)
	if !ok {
		emit("other\t%s\ta type Volt can't hold\n", name)
		return
	}
	tpNames = nil
	defer func() { tpNames = nil }()
	for i := 0; i < nt.TypeParams().Len(); i++ {
		tpNames = append(tpNames, nt.TypeParams().At(i).Obj().Name())
	}
	tparams := func() {
		for _, n := range tpNames {
			emit("tparam\t%s\n", n)
		}
	}
	switch u := nt.Underlying().(type) {
	case *types.Struct:
		emit("struct\t%s\n", name)
		tparams()
		for i := 0; i < u.NumFields(); i++ {
			f := u.Field(i)
			if !full {
				// another package's, past the first level: held by handle, its fields not described
				emit("field\t_\tfalse\tint\n")
				break
			}
			emit("field\t%s\t%v\t%s\n", f.Name(), f.Exported() && !f.Embedded(), ts(f.Type()))
		}
		emit("end\n")
	case *types.Interface:
		if len(tpNames) > 0 {
			emit("other\t%s\ta generic interface\n", name)
			return
		}
		if !u.IsMethodSet() {
			emit("other\t%s\ta constraint (in Go, only a type parameter has one)\n", name)
			return
		}
		sealed := false
		for i := 0; i < u.NumMethods(); i++ {
			sealed = sealed || !u.Method(i).Exported()
		}
		// (another package's, past the first level: only Go's values of it, its methods not described)
		kind := map[bool]string{true: "sealed", false: "open"}[sealed]
		if !full {
			kind = "deep"
		}
		emit("interface\t%s\t%s\n", name, kind)
		ifaces = append(ifaces, o)
		if full {
			for i := 0; i < u.NumMethods(); i++ {
				if m := u.Method(i); m.Exported() {
					sig(m.Name(), name, "iface", m, m.Type().(*types.Signature))
				}
			}
		}
		return
	case *types.Basic:
		if cs := enums[o]; cs != nil {
			sort.Slice(cs, func(i, j int) bool { return cs[i].Pos() < cs[j].Pos() })
			emit("enum\t%s\n", name)
			for _, c := range cs {
				if v, exact := constant.Int64Val(c.Val()); exact {
					emit("value\t%s\t%d\n", c.Name(), v)
				}
			}
			emit("end\n")
		} else {
			emit("named\t%s\t%s\n", name, ts(u))
			tparams()
			emit("end\n")
		}
	default:
		emit("named\t%s\t%s\n", name, ts(u))
		tparams()
		emit("end\n")
	}
	if len(tpNames) == 0 {
		typed = append(typed, o)
	}
	if !full {
		return
	}
	for i := 0; i < nt.NumMethods(); i++ {
		m := nt.Method(i)
		if !m.Exported() {
			continue
		}
		s := m.Type().(*types.Signature)
		recv := "val"
		if _, ok := s.Recv().Type().(*types.Pointer); ok {
			recv = "ptr"
		}
		sig(m.Name(), name, recv, m, s)
	}
}

func main() {
	dir := os.Args[1]
	bp, err := build.ImportDir(dir, 0)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fset := token.NewFileSet()
	var files []*ast.File
	for _, n := range append(append([]string{}, bp.GoFiles...), bp.CgoFiles...) {
		f, err := parser.ParseFile(fset, filepath(dir, n), nil, 0)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		files = append(files, f)
	}
	// a package that doesn't check (an import go can't find) still says what it can
	conf := types.Config{Importer: importer.ForCompiler(fset, "source", nil), FakeImportC: true, Error: func(error) {}}
	pkg, _ = conf.Check(bp.Name, fset, files, nil)
	scope := pkg.Scope()
	// a named integer type with exported constants of its own is an enum
	enums := map[*types.TypeName][]*types.Const{}
	for _, n := range scope.Names() {
		if c, ok := scope.Lookup(n).(*types.Const); ok && c.Exported() {
			if nt, ok := c.Type().(*types.Named); ok && nt.Obj().Pkg() == pkg {
				if b, ok := nt.Underlying().(*types.Basic); ok && b.Info()&types.IsInteger != 0 {
					enums[nt.Obj()] = append(enums[nt.Obj()], c)
				}
			}
		}
	}
	for _, n := range scope.Names() {
		o := scope.Lookup(n)
		if !o.Exported() {
			continue
		}
		switch o := o.(type) {
		case *types.Func:
			sig(n, "-", "none", o, o.Type().(*types.Signature))
		case *types.Const:
			if nt, ok := o.Type().(*types.Named); ok && enums[nt.Obj()] != nil {
				continue
			}
			konst(o)
		case *types.Var:
			emit("var\t%s\t%s\n", n, ts(o.Type()))
		case *types.TypeName:
			describe(o, true, enums)
		}
	}
	// other packages' types the API names (and theirs, one level deeper, without their methods)
	for i := 0; i < len(queue); i++ {
		o := queue[i]
		cur = depth[o]
		if o.Exported() {
			describe(o, cur <= 1, nil)
		}
	}
	// which of these types have which interfaces' methods
	for _, t := range typed {
		for _, i := range ifaces {
			it := i.Type().Underlying().(*types.Interface)
			if types.Implements(t.Type(), it) {
				emit("impl\t%s\t%s\tval\n", named(t), named(i))
			} else if types.Implements(types.NewPointer(t.Type()), it) {
				emit("impl\t%s\t%s\tptr\n", named(t), named(i))
			}
		}
	}
	fmt.Printf("package\t%s\n%s%s", bp.Name, head.String(), out.String())
}

func filepath(dir, n string) string { return strings.TrimSuffix(dir, "/") + "/" + n }
"#;

/// a Go type, as DESCRIBE writes it
#[derive(Clone, Debug, PartialEq)]
enum GT {
    /// a basic type, a type parameter, or a named type (the package's Name, another's pN.Name),
    /// with its type arguments
    Name(String, Vec<GT>),
    Ptr(Box<GT>),
    Slice(Box<GT>),
    Array(usize, Box<GT>),
    Map(Box<GT>, Box<GT>),
    Chan(Dir, Box<GT>),
    /// parameters, results, and whether the last parameter is ...T
    Func(Vec<GT>, Vec<GT>, bool),
    /// struct{}
    Empty,
    /// an anonymous struct or interface type (DESCRIBE's anon N)
    Anon(usize),
}

/// which way a channel goes
#[derive(Clone, Copy, Debug, PartialEq)]
enum Dir {
    Both,
    Recv,
    Send,
}

fn parse_gt(s: &str) -> Option<GT> {
    match gt(s.trim())? {
        (t, "") => Some(t),
        _ => None,
    }
}

fn boxed(r: &str) -> Option<(Box<GT>, &str)> {
    gt(r).map(|(t, r)| (Box::new(t), r))
}

/// a type at the start of s, and what follows it
fn gt(s: &str) -> Option<(GT, &str)> {
    if let Some(r) = s.strip_prefix('*') {
        let (e, r) = boxed(r)?;
        return Some((GT::Ptr(e), r));
    }
    if let Some(r) = s.strip_prefix("[]") {
        let (e, r) = boxed(r)?;
        return Some((GT::Slice(e), r));
    }
    if let Some(r) = s.strip_prefix("map[") {
        let (k, r) = boxed(r)?;
        let (v, r) = boxed(r.strip_prefix(']')?)?;
        return Some((GT::Map(k, v), r));
    }
    if let Some(r) = s.strip_prefix('[') {
        let end = r.find(']')?;
        let n = r[..end].parse().ok()?;
        let (e, r) = boxed(&r[end + 1..])?;
        return Some((GT::Array(n, e), r));
    }
    for (p, d) in [("<-chan ", Dir::Recv), ("chan<- ", Dir::Send), ("chan ", Dir::Both)] {
        if let Some(r) = s.strip_prefix(p) {
            let (e, r) = boxed(r)?;
            return Some((GT::Chan(d, e), r));
        }
    }
    if let Some(r) = s.strip_prefix("func(") {
        let (ps, variadic, r) = gt_list(r, ')')?;
        let (rs, _, r) = gt_list(r.strip_prefix('(')?, ')')?;
        return Some((GT::Func(ps, rs, variadic), r));
    }
    if let Some(r) = s.strip_prefix("struct{}") {
        return Some((GT::Empty, r));
    }
    if let Some(r) = s.strip_prefix('@') {
        let end = r.find(|c: char| !c.is_ascii_digit()).unwrap_or(r.len());
        return Some((GT::Anon(r[..end].parse().ok()?), &r[end..]));
    }
    let end = s.find(['[', ']', '(', ')', ',', ' ']).unwrap_or(s.len());
    if end == 0 {
        return None;
    }
    let (name, r) = (s[..end].to_string(), &s[end..]);
    if let Some(r) = r.strip_prefix('[') {
        let (args, _, r) = gt_list(r, ']')?;
        return Some((GT::Name(name, args), r));
    }
    Some((GT::Name(name, Vec::new()), r))
}

/// types separated by commas up to close (the last may be ...T), and what follows
fn gt_list(mut s: &str, close: char) -> Option<(Vec<GT>, bool, &str)> {
    let mut out = Vec::new();
    if let Some(r) = s.strip_prefix(close) {
        return Some((out, false, r));
    }
    let mut variadic = false;
    loop {
        if let Some(r) = s.strip_prefix("...") {
            variadic = true;
            s = r;
        }
        let (t, r) = gt(s)?;
        out.push(t);
        if let Some(r) = r.strip_prefix(',') {
            s = r;
            continue;
        }
        return Some((out, variadic, r.strip_prefix(close)?));
    }
}

/// an interface value as its handle (dyn_I), as a callback or a trait method has it
fn dyn_handle(t: Ty) -> Ty {
    match t {
        Ty::Dyn(tr, _) => Ty::Named(format!("dyn_{tr}")),
        t => t,
    }
}

/// a Go basic type Volt has
fn basic(n: &str) -> Option<Ty> {
    Some(match n {
        "int" => Ty::Prim("isize"),
        "uint" => Ty::Prim("usize"),
        "int8" => Ty::Prim("i8"),
        "int16" => Ty::Prim("i16"),
        "int32" | "rune" => Ty::Prim("i32"),
        "int64" => Ty::Prim("i64"),
        "uint8" | "byte" => Ty::Prim("u8"),
        "uint16" => Ty::Prim("u16"),
        "uint32" => Ty::Prim("u32"),
        "uint64" => Ty::Prim("u64"),
        "float32" => Ty::Prim("f32"),
        "float64" => Ty::Prim("f64"),
        "bool" => Ty::Prim("bool"),
        "string" => Ty::Str,
        _ => return None,
    })
}

/// the Go type of a Volt number
fn go_prim(x: &str) -> &'static str {
    match x {
        "i8" => "int8",
        "i16" => "int16",
        "i32" => "int32",
        "i64" => "int64",
        "u8" => "uint8",
        "u16" => "uint16",
        "u32" => "uint32",
        "u64" => "uint64",
        "isize" => "int",
        "usize" => "uint",
        "f32" => "float32",
        "f64" => "float64",
        _ => "bool",
    }
}

/// the C type of a Volt number (in the shim's C helpers)
fn c_prim(x: &str) -> &'static str {
    match x {
        "i8" => "int8_t",
        "i16" => "int16_t",
        "i32" => "int32_t",
        "i64" => "int64_t",
        "u8" => "uint8_t",
        "u16" => "uint16_t",
        "u32" => "uint32_t",
        "u64" => "uint64_t",
        "isize" => "intptr_t",
        "usize" => "uintptr_t",
        "f32" => "float",
        "f64" => "double",
        _ => "bool",
    }
}

/// what the shim does with one of the import's types beyond glue's kinds
#[derive(Clone, Debug, PartialEq)]
enum Synth {
    /// a named basic type (Celsius float64): a Volt struct { value: T }
    Newtype,
    /// complex64, complex128 (and named ones): a Volt struct { re, im }
    Complex,
    /// a channel (whichever way it goes, held as Go made it), its elements' Go type
    Chan(String),
}

/// a named type DESCRIBE declared
#[derive(Clone)]
enum Decl {
    /// fields (name, visible, type)
    Struct(Vec<(String, bool, GT)>),
    Enum(Vec<(String, i128)>),
    /// a named type of another (a basic one, a map, a func...)
    Named(GT),
    /// whether Volt's types can have it: open; sealed (it has unexported methods, which no other
    /// package's type can have); deep (another package's, its methods not described)
    Iface(&'static str),
}

#[derive(Clone)]
struct DeclInfo {
    decl: Decl,
    tparams: Vec<String>,
    /// its Volt name and namespace: another package's types are in a namespace of its name
    /// (st::time::Duration), named pkg_Name when another type has the name
    vname: String,
    module: Vec<String>,
}

/// a func or method as DESCRIBE wrote it
#[derive(Clone, Default)]
struct GoSig {
    name: String,
    /// "-", or the type's Go name
    recv: String,
    kind: String,
    src: String,
    tparams: Vec<String>,
    params: Vec<(String, GT)>,
    results: Vec<(String, GT)>,
    variadic: bool,
}

/// where a type is: a parameter, a result, or inside another type
#[derive(Clone, Copy, PartialEq)]
enum Pos {
    In,
    Out,
    Elem,
}

/// reads DESCRIBE's output into the glue's model and the shim's knowledge of each type
struct Reader<'a> {
    alias: &'a str,
    m: Model,
    decls: BTreeMap<String, DeclInfo>,
    sigs: Vec<GoSig>,
    anons: BTreeMap<usize, String>,
    /// pN -> the package's name
    pkgs: BTreeMap<String, String>,
    /// Volt type name -> its Go type expression
    exprs: BTreeMap<String, String>,
    synth: BTreeMap<String, Synth>,
    /// type parameters in scope: an instance's (its Volt text, Volt type, Go type)
    tps: BTreeMap<String, Option<(String, Ty, String)>>,
    /// (type or "", name) of funcs and methods whose last parameter is ...T
    variadic: BTreeSet<String>,
    /// the interfaces that are Volt traits (by Go name), and the interfaces each type has
    traits: BTreeSet<String>,
    impls: BTreeMap<String, Vec<String>>,
    /// the composite types named as instances of map, set, chan, ptr or slice: their Go types
    gen_gts: BTreeMap<String, GT>,
    /// the instances made (their names as a program spells them: Stack__isize: geom::Stack<isize>)
    inst_texts: BTreeMap<String, String>,
}

/// DESCRIBE's output as the glue's model (with the instances of generics these lines ask for) and
/// the shim's half
fn read(desc: &str, alias: &str, path: &str, shim_pkg: &str, lines: &[String]) -> (Model, Go) {
    let mut r = Reader { alias, m: Model::default(), decls: BTreeMap::new(), sigs: Vec::new(), anons: BTreeMap::new(), pkgs: BTreeMap::new(), exprs: BTreeMap::new(), synth: BTreeMap::new(), tps: BTreeMap::new(), variadic: BTreeSet::new(), traits: BTreeSet::new(), impls: BTreeMap::new(), gen_gts: BTreeMap::new(), inst_texts: BTreeMap::new() };
    r.read(desc);
    for l in lines {
        r.instance(l);
    }
    let imports = r.pkgs.keys().map(|a| (a.clone(), desc.lines().find_map(|l| l.strip_prefix(&format!("import\t{a}\t"))).and_then(|x| x.split('\t').next()).unwrap_or("").to_string())).collect();
    let go = Go { path: path.to_string(), pkg: shim_pkg.to_string(), synth: r.synth, variadic: r.variadic, imports, helpers: RefCell::default(), c_helpers: RefCell::default(), fns: RefCell::default(), tuples: RefCell::default() };
    (r.m, go)
}

impl Reader<'_> {
    fn read(&mut self, desc: &str) {
        let rows: Vec<Vec<&str>> = desc.lines().map(|l| l.split('\t').collect()).collect();
        let field = |f: &Vec<&str>, k: usize| f.get(k).copied().unwrap_or("").to_string();
        // the named types first (a signature may name any), then the funcs
        let mut i = 0;
        let mut others: Vec<Vec<&str>> = Vec::new();
        while i < rows.len() {
            let f = rows[i].clone();
            i += 1;
            // a section's rows, up to its end
            let mut section = || {
                let mut rs = Vec::new();
                while i < rows.len() && rows[i][0] != "end" {
                    rs.push(rows[i].clone());
                    i += 1;
                }
                i += 1;
                rs
            };
            let tparams = |rs: &[Vec<&str>]| rs.iter().filter(|r| r[0] == "tparam").map(|r| field(r, 1)).collect::<Vec<_>>();
            match f[0] {
                "import" if f.len() >= 4 => {
                    // (two packages of one name: the second's types are pkgN_T)
                    let mut name = field(&f, 3);
                    if self.pkgs.values().any(|x| *x == name) {
                        name = format!("{name}{}", field(&f, 1).trim_start_matches('p'));
                    }
                    self.pkgs.insert(field(&f, 1), name);
                }
                "anon" if f.len() >= 3 => {
                    self.anons.insert(f[1].parse().unwrap_or(0), f[2..].join("\t"));
                }
                "struct" => {
                    let rs = section();
                    let fields = rs.iter().filter(|r| r[0] == "field" && r.len() == 4).map(|r| (field(r, 1), r[2] == "true", parse_gt(r[3]).unwrap_or(GT::Empty))).collect();
                    self.declare(&field(&f, 1), Decl::Struct(fields), tparams(&rs));
                }
                "enum" => {
                    let rs = section();
                    let vs = rs.iter().filter_map(|r| Some((field(r, 1), r.get(2)?.parse::<i128>().ok()?))).collect();
                    self.declare(&field(&f, 1), Decl::Enum(vs), Vec::new());
                }
                "named" => {
                    let rs = section();
                    match parse_gt(&field(&f, 2)) {
                        Some(t) => self.declare(&field(&f, 1), Decl::Named(t), tparams(&rs)),
                        None => self.m.left_out.push(format!("{} (its type)", f[1])),
                    }
                }
                "interface" => {
                    let kind = match f.get(2).copied() {
                        Some("open") => "open",
                        Some("deep") => "deep",
                        _ => "sealed",
                    };
                    self.declare(&field(&f, 1), Decl::Iface(kind), Vec::new());
                }
                "impl" if f.len() == 4 => {
                    self.impls.entry(field(&f, 1)).or_default().push(field(&f, 2));
                    others.push(f);
                }
                "func" => {
                    let rs = section();
                    let mut s = GoSig { name: field(&f, 1), recv: field(&f, 2), kind: field(&f, 3), ..GoSig::default() };
                    for r in rs {
                        match r[0] {
                            "src" => s.src = r[1..].join(" "),
                            "tparam" => s.tparams.push(field(&r, 1)),
                            "variadic" => s.variadic = true,
                            "param" | "result" if r.len() == 3 => {
                                let t = parse_gt(r[2]).unwrap_or(GT::Anon(usize::MAX));
                                if r[0] == "param" { s.params.push((r[1].to_string(), t)) } else { s.results.push((r[1].to_string(), t)) }
                            }
                            _ => {}
                        }
                    }
                    self.sigs.push(s);
                }
                _ => others.push(f),
            }
        }
        // the interfaces Volt's types can have: Volt traits
        let ifaces: Vec<(String, DeclInfo)> = self.decls.iter().filter(|(_, d)| matches!(d.decl, Decl::Iface(_))).map(|(n, d)| (n.clone(), d.clone())).collect();
        for pass in 0..2 {
            for (n, d) in &ifaces {
                let ms: Vec<GoSig> = self.sigs.iter().filter(|s| s.kind == "iface" && s.recv == *n).cloned().collect();
                let methods: Vec<Result<Sig, String>> = ms.iter().map(|gs| self.sig(gs, true)).collect();
                if pass == 0 {
                    if matches!(d.decl, Decl::Iface("open")) && !methods.is_empty() && methods.iter().all(|s| s.as_ref().is_ok_and(|s| self.bridgeable(s))) {
                        self.traits.insert(n.clone());
                    }
                    continue;
                }
                self.interface(n, d, &ms, methods);
            }
        }

        // the types (a generic one's instances come as programs ask), then the funcs
        self.generic_composites();
        let names: Vec<String> = self.decls.keys().cloned().collect();
        for n in &names {
            let d = self.decls[n].clone();
            if d.tparams.is_empty() {
                let expr = self.go_name(n);
                if let Err(why) = self.define(n, &d, &d.vname.clone(), &expr) {
                    self.m.left_out.push(format!("{n} ({why})"));
                }
            } else {
                self.m.types.push(TypeDef { module: d.module.clone(), name: d.vname.clone(), generic: true, fields: None, variants: None, is_enum: false, clone: true, opaque: false, params: d.tparams.clone(), rust_name: None });
            }
        }
        for gs in self.sigs.clone() {
            if gs.recv != "-" {
                continue;
            }
            self.tps = gs.tparams.iter().map(|t| (t.clone(), None)).collect();
            match self.sig(&gs, false) {
                Ok(mut s) => {
                    s.generics = gs.tparams.clone();
                    if gs.variadic {
                        self.variadic.insert(format!(".{}", s.name));
                    }
                    self.m.fns.push((Vec::new(), s));
                }
                Err(why) => self.m.left_out.push(format!("{} ({why})", gs.name)),
            }
            self.tps.clear();
        }
        for f in others {
            let field = |k: usize| f.get(k).copied().unwrap_or("").to_string();
            match f[0] {
                "const" if f.len() == 4 => self.constant(&field(1), &field(2), &field(3)),
                "var" if f.len() == 3 => self.variable(&field(1), &field(2)),
                "alias" if f.len() == 3 => match parse_gt(f[2]).map(|t| self.ty(&t, Pos::Elem)) {
                    Some(Ok(t)) => self.m.aliases.push((Vec::new(), self.vname(f[1]), t)),
                    Some(Err(why)) => self.m.left_out.push(format!("{} ({why})", f[1])),
                    None => self.m.left_out.push(format!("{} (a type alias)", f[1])),
                },
                "impl" if f.len() == 4 => {
                    let (t, i) = (field(1), field(2));
                    let (tv, iv) = (self.vname(&t), self.vname(&i));
                    if !self.decls.get(&t).is_some_and(|d| d.tparams.is_empty()) || !self.exprs.contains_key(&tv) {
                        continue;
                    }
                    if self.traits.contains(&i) {
                        self.m.impls.push((tv.clone(), iv.clone()));
                    }
                    if let Some(ie) = self.exprs.get(&format!("dyn_{iv}")).cloned() {
                        // Go's value of the interface (for a call, a slice or a map taking one): as_I()
                        let r = if f[3] == "ptr" { "&$r" } else { "$r" };
                        let s = Sig { name: format!("as_{iv}"), recv: Recv::Ref, params: Vec::new(), ret: Some(Ty::Named(format!("dyn_{iv}"))), skip: None, src: format!("{ie}({r})"), generics: Vec::new(), call: Some(format!("=({ie})({r})")) };
                        self.m.methods.entry(tv).or_default().push(s);
                    }
                }
                "other" if f.len() >= 3 => self.m.left_out.push(format!("{} ({})", f[1], f[2])),
                _ => {}
            }
        }
    }

    /// an interface: a Volt trait when Volt's types can have it (each method's types are numbers,
    /// bools and text), else only its values Go makes (dyn_I, with its methods)
    fn interface(&mut self, n: &str, d: &DeclInfo, ms: &[GoSig], methods: Vec<Result<Sig, String>>) {
        let mut ok = Vec::new();
        for (gs, s) in ms.iter().zip(methods) {
            match s {
                Ok(s) => ok.push(s),
                Err(why) => self.m.left_out.push(format!("{n}'s {} ({why})", gs.name)),
            }
        }
        if self.traits.contains(n) {
            self.m.traits.push(TraitDef { module: d.module.clone(), name: d.vname.clone(), methods: ok.into_iter().map(|s| (s, false)).collect(), skip: None });
        } else {
            let why = match d.decl {
                Decl::Iface("sealed") => Some("it has unexported methods, so in Go only its own package's types have it"),
                Decl::Iface("open") if !ms.is_empty() => Some("a method takes or gives a type a Volt method can't (a slice of slices or of arrays, say)"),
                _ => None,
            };
            if let Some(why) = why {
                self.m.left_out.push(format!("{} as a trait Volt's types attach ({why}): Go's values of it are dyn_{}", d.vname, d.vname));
            }
            self.m.methods.entry(format!("dyn_{}", d.vname)).or_default().extend(ok);
        }
    }

    /// a named type's Volt name
    fn vname(&self, n: &str) -> String {
        if let Some(d) = self.decls.get(n) {
            return d.vname.clone();
        }
        match n.split_once('.') {
            Some((a, t)) => format!("{}_{t}", self.pkgs.get(a).map_or(a, String::as_str)),
            None => n.to_string(),
        }
    }

    /// a named type's Go name in the shim (m.Name, pN.Name)
    fn go_name(&self, n: &str) -> String {
        if n.contains('.') { n.to_string() } else { format!("m.{n}") }
    }

    fn declare(&mut self, n: &str, decl: Decl, tparams: Vec<String>) {
        let (vname, module) = match n.split_once('.') {
            Some((a, t)) => {
                let pkg = self.pkgs.get(a).cloned().unwrap_or_else(|| a.to_string());
                let taken = self.decls.values().any(|d| d.vname == t);
                (if taken { format!("{pkg}_{t}") } else { t.to_string() }, vec![pkg])
            }
            None => (n.to_string(), Vec::new()),
        };
        self.decls.insert(n.to_string(), DeclInfo { decl, tparams, vname, module });
    }

    /// a type's Volt path, from anywhere in the import
    fn volt_path(&self, vn: &str) -> String {
        let module = self.m.types.iter().find(|t| t.name == vn).map(|t| t.module.clone()).unwrap_or_default();
        let mut p = vec![self.alias.to_string()];
        p.extend(module);
        p.push(vn.to_string());
        p.join("::")
    }

    /// a type's definition (the type or an instance of a generic one, by Volt name vn and Go type
    /// expr): its TypeDef, the methods the shim gives it, and its own methods
    fn define(&mut self, n: &str, d: &DeclInfo, vn: &str, expr: &str) -> Result<(), String> {
        let own = |r: &Self| r.go_name(n) != *expr || n.contains('.');
        let mut def = TypeDef { module: d.module.clone(), name: vn.to_string(), generic: false, fields: None, variants: None, is_enum: false, clone: true, opaque: false, params: Vec::new(), rust_name: own(self).then(|| expr.to_string()) };
        self.exprs.insert(vn.to_string(), expr.to_string());
        match &d.decl {
            Decl::Struct(fs) => {
                let mut fields = Vec::new();
                for (f, public, t) in fs {
                    fields.push((f.clone(), *public, self.ty(t, Pos::Elem).ok()));
                }
                def.fields = Some(fields);
                self.m.types.push(def);
                self.statics(vn, &[("new", Vec::new(), format!("zero[{expr}]()"))]);
                // a handle's exported fields: F() and set_F(v) (a plain struct's are Volt's own)
                if !self.plain(n, &mut BTreeSet::new()) {
                    for (f, public, g) in fs.iter().filter(|x| x.1) {
                        let _ = public;
                        let r = (|| -> Result<(Ty, Ty), String> { Ok((self.ty(g, Pos::Out)?, self.ty(g, Pos::In)?)) })();
                        match r {
                            Ok((o, i)) => {
                                let get = Sig { name: f.clone(), recv: Recv::Ref, params: Vec::new(), ret: Some(o), skip: None, src: format!("field {f} {}", self.go_expr(g)), generics: Vec::new(), call: Some(format!("=$r.{f}")) };
                                let set = Sig { name: format!("set_{f}"), recv: Recv::Ref, params: vec![("value".into(), Some(i))], ret: Some(Ty::Unit), skip: None, src: format!("field {f} {}", self.go_expr(g)), generics: Vec::new(), call: Some(format!("=$r.{f} = $0")) };
                                self.m.methods.entry(vn.to_string()).or_default().extend([get, set]);
                            }
                            Err(why) => self.m.left_out.push(format!("{vn}'s field {f} ({why})")),
                        }
                    }
                }
            }
            Decl::Enum(vs) => {
                def.variants = Some(vs.clone());
                def.is_enum = true;
                def.clone = false;
                self.m.types.push(def);
            }
            Decl::Iface(_) => {
                // Go's values of it: a handle (dyn_I), which has its methods (attaching the trait)
                let dyn_n = format!("dyn_{vn}");
                def.name = dyn_n.clone();
                def.rust_name = Some(expr.to_string());
                self.exprs.insert(dyn_n.clone(), expr.to_string());
                self.m.types.push(def);
                if self.traits.contains(n) {
                    self.m.impls.push((dyn_n.clone(), vn.to_string()));
                    // and a Volt value of a type attaching it, as Go's value of it
                    let s = Sig { name: "new".into(), recv: Recv::None, params: vec![("value".into(), Some(Ty::Dyn(vn.to_string(), FnPass::Value)))], ret: Some(Ty::Named(dyn_n.clone())), skip: None, src: format!("{expr}(value)"), generics: Vec::new(), call: Some(format!("=({expr})($0)")) };
                    self.m.methods.entry(dyn_n).or_default().push(s);
                }
            }
            Decl::Named(GT::Func(..)) => {
                // its signature (a Volt fn type), as an alias
                if let Decl::Named(t) = &d.decl {
                    let t = self.ty(t, Pos::Elem)?;
                    self.m.aliases.push((Vec::new(), vn.to_string(), t));
                }
                self.exprs.remove(vn);
                return Ok(());
            }
            Decl::Named(u) => {
                self.underlying(vn, expr, u, def)?;
            }
        }
        // its own methods (but those a trait it attaches has: its attach block's)
        let traits: Vec<String> = self.impls.get(n).into_iter().flatten().filter(|i| self.traits.contains(*i)).cloned().collect();
        let attached: BTreeSet<String> = self.sigs.iter().filter(|s| s.kind == "iface" && traits.contains(&s.recv)).map(|s| s.name.clone()).collect();
        for gs in self.sigs.clone() {
            if gs.recv != n || gs.kind == "iface" || attached.contains(&gs.name) {
                continue;
            }
            match self.sig(&gs, false) {
                Ok(s) => {
                    if gs.variadic {
                        self.variadic.insert(format!("{vn}.{}", s.name));
                    }
                    self.m.methods.entry(vn.to_string()).or_default().push(s);
                }
                Err(why) => self.m.left_out.push(format!("{vn}::{} ({why})", gs.name)),
            }
        }
        Ok(())
    }

    /// a named type of a basic or composite type (or an anonymous composite one): its TypeDef, by
    /// what it holds, and the methods the shim gives it
    fn underlying(&mut self, vn: &str, expr: &str, u: &GT, mut def: TypeDef) -> Result<(), String> {
        def.rust_name = Some(expr.to_string());
        self.exprs.insert(vn.to_string(), expr.to_string());
        let m = |name: &str, params: Vec<(&str, Ty)>, ret: Ty, call: String| Sig { name: name.into(), recv: Recv::Ref, params: params.into_iter().map(|(n, t)| (n.to_string(), Some(t))).collect(), ret: Some(ret), skip: None, src: String::new(), generics: Vec::new(), call: Some(format!("={call}")) };
        let mut ms: Vec<Sig> = Vec::new();
        match u {
            GT::Name(b, a) if a.is_empty() && (basic(b).is_some() || b == "uintptr") => {
                let t = basic(b).unwrap_or(Ty::Prim("usize"));
                match t {
                    Ty::Prim(p) => {
                        def.fields = Some(vec![("value".into(), true, Some(Ty::Prim(p)))]);
                        self.synth.insert(vn.to_string(), Synth::Newtype);
                    }
                    _ => {
                        // text: a handle, made from a str
                        self.statics(vn, &[("new", vec![("value", Ty::Str)], format!("({expr})($0)"))]);
                        ms.push(m("value", Vec::new(), Ty::Str, "string($r)".into()));
                    }
                }
            }
            GT::Name(c, a) if a.is_empty() && (c == "complex64" || c == "complex128") => {
                let f = if c == "complex64" { "f32" } else { "f64" };
                def.fields = Some(vec![("re".into(), true, Some(Ty::Prim(f))), ("im".into(), true, Some(Ty::Prim(f)))]);
                self.synth.insert(vn.to_string(), Synth::Complex);
            }
            GT::Map(k, v) => {
                let kt = self.ty(k, Pos::In)?;
                self.statics(vn, &[("new", Vec::new(), format!("make({expr})"))]);
                ms.push(m("len", Vec::new(), Ty::Prim("isize"), "len($r)".into()));
                ms.push(m("contains", vec![("key", kt.clone())], Ty::Prim("bool"), "mapHas($r, $0)".into()));
                ms.push(m("remove", vec![("key", kt.clone())], Ty::Unit, "delete($r, $0)".into()));
                if **v == GT::Empty {
                    ms.push(m("add", vec![("key", kt.clone())], Ty::Unit, "$r[$0] = struct{}{}".into()));
                } else {
                    let (vi, vo) = (self.ty(v, Pos::In)?, self.ty(v, Pos::Out)?);
                    ms.push(m("get", vec![("key", kt.clone())], Ty::Opt(Box::new(vo)), "mapGet($r, $0)".into()));
                    ms.push(m("put", vec![("key", kt.clone()), ("value", vi)], Ty::Unit, "$r[$0] = $1".into()));
                }
                if let Ok(Ty::Vec(e)) = self.ty(&GT::Slice(k.clone()), Pos::Out) {
                    ms.push(m("keys", Vec::new(), Ty::Vec(e), "mapKeys($r)".into()));
                }
            }
            GT::Slice(e) | GT::Array(_, e) => {
                let (ei, eo) = (self.ty(e, Pos::In)?, self.ty(e, Pos::Out)?);
                let whole = if matches!(u, GT::Array(..)) { "$r[:]" } else { "$r" };
                self.statics(vn, &[("new", Vec::new(), format!("zero[{expr}]()"))]);
                ms.push(m("len", Vec::new(), Ty::Prim("isize"), "len($r)".into()));
                ms.push(m("get", vec![("i", Ty::Prim("isize"))], eo, "$r[$0]".into()));
                ms.push(m("put", vec![("i", Ty::Prim("isize")), ("value", ei.clone())], Ty::Unit, "$r[$0] = $1".into()));
                if matches!(u, GT::Slice(_)) {
                    ms.push(m("push", vec![("value", ei)], Ty::Unit, "$r = append($r, $0)".into()));
                }
                if let Ok(Ty::Vec(x)) = self.ty(&GT::Slice(e.clone()), Pos::Out) {
                    ms.push(m("items", Vec::new(), Ty::Vec(x), whole.into()));
                }
            }
            GT::Chan(_, e) => {
                let (ei, eo) = (self.ty(e, Pos::In)?, self.ty(e, Pos::Out)?);
                let ge = self.go_expr(e);
                self.synth.insert(vn.to_string(), Synth::Chan(ge.clone()));
                self.statics(vn, &[("new", vec![("capacity", Ty::Prim("isize"))], format!("make({expr}, $0)"))]);
                ms.push(m("send", vec![("value", ei)], Ty::Unit, "chanSend($r, $0)".into()));
                ms.push(m("recv", Vec::new(), Ty::Opt(Box::new(eo)), format!("chanRecv[{ge}]($r)")));
                ms.push(m("close", Vec::new(), Ty::Unit, "chanV($r).Close()".into()));
                ms.push(m("len", Vec::new(), Ty::Prim("isize"), "chanV($r).Len()".into()));
                ms.push(m("cap", Vec::new(), Ty::Prim("isize"), "chanV($r).Cap()".into()));
            }
            GT::Ptr(e) => {
                let (ei, eo) = (self.ty(e, Pos::In)?, self.ty(e, Pos::Out)?);
                let ge = self.go_expr(e);
                self.statics(vn, &[("new", Vec::new(), format!("({expr})(new({ge}))"))]);
                ms.push(m("get", Vec::new(), eo, "*$r".into()));
                ms.push(m("put", vec![("value", ei)], Ty::Unit, "*$r = $0".into()));
            }
            // anything else (an anonymous struct, another package's generic type...): a handle Go
            // fills
            _ => {}
        }
        self.m.types.push(def);
        self.m.methods.entry(vn.to_string()).or_default().extend(ms);
        Ok(())
    }

    /// whether a Volt type can have a method of this signature (glue's cb_in and cb_out, with the
    /// shim's: numbers, bools, text, slices of numbers in, and the package's types)
    fn bridgeable(&self, s: &Sig) -> bool {
        let arg = |t: &Ty| match t {
            Ty::Prim(_) | Ty::Str | Ty::String | Ty::Named(_) | Ty::Fn(..) => true,
            Ty::Ref(x, _) => matches!(&**x, Ty::Named(_) | Ty::Prim(_)),
            Ty::Vec(e) | Ty::Slice(e, _) | Ty::Array(e, _) => matches!(&**e, Ty::Prim(_) | Ty::Str | Ty::Named(_)) || matches!(&**e, Ty::Ref(x, _) if matches!(&**x, Ty::Named(_))),
            _ => false,
        };
        let one = |t: &Ty| match t {
            Ty::Unit | Ty::Prim(_) | Ty::Str | Ty::String | Ty::Named(_) | Ty::Fn(..) => true,
            // (a plain struct's *T is its value, a copy)
            Ty::Ref(x, false) => matches!(&**x, Ty::Named(_)),
            Ty::Vec(_) | Ty::Slice(..) | Ty::Array(..) => arg(t),
            _ => false,
        };
        let one = |t: &Ty| match t {
            Ty::Opt(x) => **x != Ty::Str && one(x),
            t => one(t),
        };
        let ret = |t: &Ty| match t {
            Ty::Tuple(es) => es.iter().all(|(_, t)| *t != Ty::Str && one(t)),
            t => one(t),
        };
        let ret = |t: &Ty| match t {
            Ty::Res(x) => **x != Ty::Str && ret(x),
            t => ret(t),
        };
        s.params.iter().all(|(_, t)| t.as_ref().is_some_and(arg)) && s.ret.as_ref().is_some_and(ret)
    }

    /// whether struct n is one Volt holds by value (glue's rule: every field exported and a number,
    /// a bool, an enum, a named number or such a struct)
    fn plain(&self, n: &str, seen: &mut BTreeSet<String>) -> bool {
        if !seen.insert(n.to_string()) {
            return false;
        }
        let Some(Decl::Struct(fs)) = self.decls.get(n).map(|d| &d.decl) else { return false };
        !fs.is_empty()
            && fs.iter().all(|(_, public, g)| {
                *public
                    && match g {
                        GT::Name(x, a) if a.is_empty() => match (basic(x), self.tps.get(x), self.decls.get(x).map(|d| &d.decl)) {
                            (Some(t), _, _) => t != Ty::Str,
                            (_, Some(Some((_, t, _))), _) => matches!(t, Ty::Prim(_)),
                            (_, _, Some(Decl::Enum(_))) => true,
                            (_, _, Some(Decl::Named(GT::Name(b, _)))) => basic(b).is_some_and(|t| t != Ty::Str) || b == "uintptr" || b.starts_with("complex"),
                            (_, _, Some(Decl::Struct(_))) => self.plain(x, seen),
                            _ => x.starts_with("complex"),
                        },
                        _ => false,
                    }
            })
    }

    /// static methods of type vn the shim makes: name, parameters, the Go expression (template)
    fn statics(&mut self, vn: &str, fs: &[(&str, Vec<(&str, Ty)>, String)]) {
        for (name, ps, call) in fs {
            let s = Sig { name: name.to_string(), recv: Recv::None, params: ps.iter().map(|(n, t)| (n.to_string(), Some(t.clone()))).collect(), ret: Some(Ty::Named(vn.to_string())), skip: None, src: String::new(), generics: Vec::new(), call: Some(format!("={call}")) };
            self.m.methods.entry(vn.to_string()).or_default().push(s);
        }
    }

    /// a composite type with no name of its own: a handle type named for it: a map's, a set's or a
    /// channel's as the instance of map<K, V>, set<K> or chan<T> a program names would be
    /// (map<std::string, isize>), else for its Go type (slice_slice_int)
    fn anonymous(&mut self, g: &GT) -> Result<Ty, String> {
        let Some(l) = self.generic_line(g) else {
            let base = self.mangle(g);
            return self.anonymous_named(g, &base);
        };
        let t = self.anonymous_named(g, &instance_name(&l))?;
        if let Ty::Named(n) = &t {
            self.gen_gts.insert(n.clone(), g.clone());
            let (kind, args) = l.split_once('\t').unwrap_or((&l, ""));
            self.inst_texts.insert(n.clone(), format!("{}::{kind}<{}>", self.alias, args.replace('\t', ", ")));
        }
        Ok(t)
    }

    /// the generic Volt type a composite is an instance of, and its type arguments: map, set, chan,
    /// ptr, slice, and arrayN for [N]T (Volt's generics take types, so the length is in the name;
    /// its type is made here)
    fn composite_kind<'g>(&mut self, g: &'g GT) -> Option<(String, Vec<&'g GT>)> {
        let (kind, args): (String, Vec<&GT>) = match g {
            GT::Map(k, v) if **v == GT::Empty => ("set".into(), vec![k]),
            GT::Map(k, v) => ("map".into(), vec![k, v]),
            GT::Chan(_, e) => ("chan".into(), vec![e]),
            GT::Ptr(e) => ("ptr".into(), vec![e]),
            GT::Slice(e) => ("slice".into(), vec![e]),
            GT::Array(n, e) => {
                let kind = format!("array{n}");
                if !self.m.types.iter().any(|t| t.name == kind) {
                    self.m.types.push(generic_def(&kind, &["T"]));
                }
                (kind, vec![e])
            }
            _ => return None,
        };
        Some((kind, args))
    }

    /// a map's, a set's, a channel's, a pointer's, a slice's or an array's line as an instance of the generic
    /// Volt type (map\tK\tV), when Volt names each of its types the way voltc does
    fn generic_line(&mut self, g: &GT) -> Option<String> {
        let (kind, args) = self.composite_kind(g)?;
        let mut texts = Vec::new();
        for a in args {
            let text = match a {
                GT::Name(n, x) if x.is_empty() && matches!(self.tps.get(n), Some(Some(_))) => self.tps[n].as_ref()?.0.clone(),
                _ => {
                    let t = self.ty(a, Pos::Elem).ok()?;
                    if !self.spelled(&t) {
                        return None;
                    }
                    self.volt_text(&t)?
                }
            };
            texts.push(text);
        }
        Some(format!("{kind}\t{}", texts.join("\t")))
    }

    /// whether t is a type an instance's line names as voltc does (the package's own types and
    /// the generic composites' instances, not other handles of composite types), or a type
    /// parameter or instance of one in a generic declaration
    fn spelled(&self, t: &Ty) -> bool {
        match t {
            Ty::Prim(_) | Ty::Str | Ty::String | Ty::Generic(_) => true,
            Ty::Named(n) => self.decls.values().any(|d| d.vname == *n) || self.inst_texts.contains_key(n),
            Ty::Vec(e) => self.spelled(e),
            Ty::Inst(_, a) => a.iter().all(|x| self.spelled(x)),
            _ => false,
        }
    }

    /// the generic Volt types map<K, V>, set<K>, chan<T>, ptr<T> and slice<T>, whose instances are
    /// Go's maps, sets, channels, pointers and slices (those Volt doesn't hold itself)
    fn generic_composites(&mut self) {
        for (n, ps) in [("map", &["K", "V"][..]), ("set", &["K"]), ("chan", &["T"]), ("ptr", &["T"]), ("slice", &["T"])] {
            self.m.types.push(generic_def(n, ps));
        }
    }

    /// a composite type's handle type, named vn (made once)
    fn anonymous_named(&mut self, g: &GT, base: &str) -> Result<Ty, String> {
        let expr = self.go_expr(g);
        // (another type with the same name for Volt: a number after it)
        let base = base.to_string();
        let mut vn = base.clone();
        for k in 2.. {
            if self.exprs.get(&vn).is_none_or(|e| *e == expr) {
                break;
            }
            vn = format!("{base}{k}");
        }
        if !self.exprs.contains_key(&vn) {
            let def = TypeDef { module: Vec::new(), name: vn.clone(), generic: false, fields: None, variants: None, is_enum: false, clone: true, opaque: false, params: Vec::new(), rust_name: Some(expr.clone()) };
            // (registered first: an element may name it again)
            self.exprs.insert(vn.clone(), expr.clone());
            if let Err(why) = self.underlying(&vn, &expr, g, def) {
                self.exprs.remove(&vn);
                return Err(why);
            }
        }
        Ok(Ty::Named(vn))
    }

    /// a Volt name for a Go type (map[string]int: map_string_int)
    fn mangle(&self, g: &GT) -> String {
        match g {
            GT::Name(n, a) => {
                if let Some(Some((text, _, _))) = self.tps.get(n) {
                    return ident(text);
                }
                let mut s = self.vname(n).replace('.', "_");
                for x in a {
                    s = format!("{s}_{}", self.mangle(x));
                }
                s
            }
            GT::Ptr(e) => format!("ptr_{}", self.mangle(e)),
            GT::Slice(e) => format!("slice_{}", self.mangle(e)),
            GT::Array(n, e) => format!("array{n}_{}", self.mangle(e)),
            GT::Map(k, v) if **v == GT::Empty => format!("set_{}", self.mangle(k)),
            GT::Map(k, v) => format!("map_{}_{}", self.mangle(k), self.mangle(v)),
            GT::Chan(_, e) => format!("chan_{}", self.mangle(e)),
            GT::Func(ps, rs, _) => {
                let mut s = "func".to_string();
                for p in ps {
                    s = format!("{s}_{}", self.mangle(p));
                }
                if !rs.is_empty() {
                    s.push('_');
                    for r in rs {
                        s = format!("{s}_{}", self.mangle(r));
                    }
                }
                s
            }
            GT::Empty => "empty".into(),
            GT::Anon(i) => format!("anon{i}"),
        }
    }

    /// a Go type as the shim writes it
    fn go_expr(&self, g: &GT) -> String {
        let list = |xs: &[GT]| xs.iter().map(|x| self.go_expr(x)).collect::<Vec<_>>().join(", ");
        match g {
            GT::Name(n, a) => {
                if let Some(Some((_, _, go))) = self.tps.get(n) {
                    return go.clone();
                }
                let base = if self.decls.contains_key(n) { self.go_name(n) } else { n.clone() };
                if a.is_empty() { base } else { format!("{base}[{}]", list(a)) }
            }
            GT::Ptr(e) => format!("*{}", self.go_expr(e)),
            GT::Slice(e) => format!("[]{}", self.go_expr(e)),
            GT::Array(n, e) => format!("[{n}]{}", self.go_expr(e)),
            GT::Map(k, v) => format!("map[{}]{}", self.go_expr(k), self.go_expr(v)),
            GT::Chan(d, e) => format!("{}{}", ["chan ", "<-chan ", "chan<- "][*d as usize], self.go_expr(e)),
            GT::Func(ps, rs, variadic) => {
                let mut p: Vec<String> = ps.iter().map(|x| self.go_expr(x)).collect();
                if let (true, Some(l)) = (*variadic, p.last_mut()) {
                    *l = format!("...{l}");
                }
                let r = match rs.len() {
                    0 => String::new(),
                    1 => format!(" {}", self.go_expr(&rs[0])),
                    _ => format!(" ({})", list(rs)),
                };
                format!("func({}){r}", p.join(", "))
            }
            GT::Empty => "struct{}".into(),
            GT::Anon(i) => self.anons.get(i).cloned().unwrap_or_else(|| "any".into()),
        }
    }

    /// a Go type as Volt has it (Err: why it can't)
    fn ty(&mut self, g: &GT, pos: Pos) -> Result<Ty, String> {
        match g {
            GT::Name(n, args) => {
                if args.is_empty() {
                    if let Some(t) = basic(n) {
                        return Ok(t);
                    }
                    if let Some(x) = self.tps.get(n) {
                        return Ok(x.as_ref().map_or_else(|| Ty::Generic(n.clone()), |x| x.1.clone()));
                    }
                }
                match n.as_str() {
                    "uintptr" | "complex64" | "complex128" => return self.builtin(n, &GT::Name(n.clone(), Vec::new())),
                    "error" => return self.error_ty(),
                    "any" => return self.builtin("dyn_any", &GT::Name("any".into(), Vec::new())),
                    "unsafe.Pointer" => return self.builtin("unsafe_Pointer", &GT::Anon(usize::MAX)),
                    _ => {}
                }
                let Some(d) = self.decls.get(n).cloned() else {
                    return Err(match n.strip_prefix('!') {
                        Some(n) => format!("its type {n} is in an internal package, which in Go only its own tree imports"),
                        None => format!("its type {n} isn't exported"),
                    });
                };
                if !d.tparams.is_empty() {
                    return self.instance_ty(n, &d, args);
                }
                match &d.decl {
                    Decl::Named(f @ GT::Func(..)) => self.ty(f, pos),
                    Decl::Iface(_) if self.traits.contains(n) && pos != Pos::Elem => Ok(Ty::Dyn(d.vname.clone(), FnPass::Value)),
                    Decl::Iface(_) => Ok(Ty::Named(format!("dyn_{}", d.vname))),
                    _ => Ok(Ty::Named(d.vname.clone())),
                }
            }
            GT::Ptr(e) => {
                // *T of a type parameter: T& in, ptr<T> out
                if let GT::Name(n, a) = &**e {
                    if a.is_empty() && self.tps.contains_key(n) {
                        return match (pos, &self.tps[n]) {
                            (Pos::In, None) => Ok(Ty::Ref(Box::new(Ty::Generic(n.clone())), true)),
                            (Pos::In, Some((_, t, _))) => Ok(Ty::Ref(Box::new(t.clone()), true)),
                            _ => self.composite(g),
                        };
                    }
                }
                // a struct: that value (a plain one's copied in and back out), a handle out
                if let GT::Name(n, _) = &**e {
                    if self.decls.get(n).is_some_and(|d| matches!(d.decl, Decl::Struct(_))) {
                        return Ok(Ty::Ref(Box::new(self.ty(e, Pos::Elem)?), pos != Pos::Out));
                    }
                    if pos == Pos::In {
                        if let Some(t @ Ty::Prim(_)) = basic(n) {
                            return Ok(Ty::Ref(Box::new(t), true));
                        }
                    }
                }
                self.composite(g)
            }
            GT::Slice(e) | GT::Array(_, e) => {
                let et = self.ty(e, Pos::Elem)?;
                // ([]T of a type parameter: T[..] whatever T's instance is, as the declaration says)
                let tparam = matches!(&**e, GT::Name(n, a) if a.is_empty() && self.tps.contains_key(n));
                if !tparam && !self.flat(&et) {
                    return self.composite(g);
                }
                Ok(match g {
                    GT::Array(n, _) => Ty::Array(Box::new(et), *n),
                    _ => Ty::Vec(Box::new(et)),
                })
            }
            // (in a generic declaration, a parameter's map<K, V> is lent, as a handle is)
            GT::Map(..) => match self.composite(g)? {
                t @ Ty::Inst(..) if pos == Pos::In => Ok(Ty::Ref(Box::new(t), false)),
                t => Ok(t),
            },
            GT::Chan(d, e) => {
                // one Volt type whichever way it goes (made of a both-ways one)
                let t = self.composite(&GT::Chan(Dir::Both, e.clone()))?;
                // the way a parameter's channel goes: Recv <-chan, Send chan<-
                Ok(if pos == Pos::In && (*d != Dir::Both || matches!(t, Ty::Inst(..))) { Ty::Ref(Box::new(t), *d == Dir::Send) } else { t })
            }
            GT::Func(ps, rs, variadic) => {
                if *variadic {
                    return Err("a func type taking a variable number of arguments".into());
                }
                let mut pt = Vec::new();
                for p in ps {
                    pt.push(dyn_handle(self.ty(p, Pos::In)?));
                }
                let is = |g: &GT, x: &str| matches!(g, GT::Name(n, a) if n == x && a.is_empty());
                let one = |r: &mut Self, g: &GT| -> Result<Ty, String> { if is(g, "string") { Ok(Ty::String) } else { Ok(dyn_handle(r.ty(g, Pos::Out)?)) } };
                let tuple = |r: &mut Self, xs: &[GT]| -> Result<Ty, String> {
                    let mut es = Vec::new();
                    for x in xs {
                        es.push((String::new(), one(r, x)?));
                    }
                    Ok(Ty::Tuple(es))
                };
                let r = match rs.as_slice() {
                    [] => Ty::Unit,
                    [e] if is(e, "error") => Ty::Res(Box::new(Ty::Unit)),
                    [t] => one(self, t)?,
                    [t, e] if is(e, "error") => Ty::Res(Box::new(one(self, t)?)),
                    [t, b] if is(b, "bool") => Ty::Opt(Box::new(one(self, t)?)),
                    [ts @ .., e] if is(e, "error") => Ty::Res(Box::new(tuple(self, ts)?)),
                    ts => tuple(self, ts)?,
                };
                Ok(Ty::Fn(pt, Box::new(r), FnPass::Value, false))
            }
            GT::Empty | GT::Anon(_) => self.composite(g),
        }
    }

    /// whether a slice of t is Volt's memory (T[..], std::vec<T>), or a handle of its own
    fn flat(&self, t: &Ty) -> bool {
        match t {
            Ty::Prim(_) | Ty::Str | Ty::String | Ty::Generic(_) | Ty::Inst(..) => true,
            Ty::Named(n) => !matches!(self.synth.get(n), Some(Synth::Chan(_))),
            Ty::Ref(x, _) => matches!(&**x, Ty::Named(n) if !matches!(self.synth.get(n), Some(Synth::Chan(_)))),
            _ => false,
        }
    }

    /// a composite type (or a pointer to anything but a struct): a handle of its own, made once;
    /// in a generic declaration, a map, a set or a channel of its type parameters is map<K, V>,
    /// set<K> or chan<T>
    fn composite(&mut self, g: &GT) -> Result<Ty, String> {
        if self.has_tparam(g) {
            let (kind, args) = self.composite_kind(g).ok_or("it's generic over a composite of its type parameters, which Volt has no generic spelling of")?;
            let kind = kind.as_str();
            let args: Vec<&GT> = args;
            let mut tys = Vec::new();
            for a in args {
                let t = self.ty(a, Pos::Elem)?;
                if !self.spelled(&t) {
                    return Err(format!("it's generic over a {kind} of {}, which Volt has no generic spelling of", self.go_expr(a)));
                }
                tys.push(t);
            }
            return Ok(Ty::Inst(kind.into(), tys));
        }
        self.anonymous(g)
    }

    fn has_tparam(&self, g: &GT) -> bool {
        match g {
            GT::Name(n, a) => matches!(self.tps.get(n), Some(None)) || a.iter().any(|x| self.has_tparam(x)),
            GT::Ptr(e) | GT::Slice(e) | GT::Array(_, e) | GT::Chan(_, e) => self.has_tparam(e),
            GT::Map(k, v) => self.has_tparam(k) || self.has_tparam(v),
            GT::Func(ps, rs, _) => ps.iter().chain(rs).any(|x| self.has_tparam(x)),
            GT::Empty | GT::Anon(_) => false,
        }
    }

    /// uintptr, complex64, complex128, any, unsafe.Pointer: a type of their own (vn)
    fn builtin(&mut self, vn: &str, g: &GT) -> Result<Ty, String> {
        if !self.exprs.contains_key(vn) {
            let expr = match vn {
                "dyn_any" => "any".to_string(),
                "unsafe_Pointer" => "unsafe.Pointer".to_string(),
                x => x.to_string(),
            };
            let def = TypeDef { module: Vec::new(), name: vn.to_string(), generic: false, fields: None, variants: None, is_enum: false, clone: true, opaque: false, params: Vec::new(), rust_name: Some(expr.clone()) };
            match g {
                GT::Name(n, _) if n != "any" => self.underlying(vn, &expr, g, def)?,
                _ => {
                    self.exprs.insert(vn.to_string(), expr);
                    self.m.types.push(def);
                }
            }
        }
        Ok(Ty::Named(vn.to_string()))
    }

    /// Go's error interface where it isn't a result's: dyn_error, with Error() and new(text)
    fn error_ty(&mut self) -> Result<Ty, String> {
        let vn = "dyn_error";
        if !self.exprs.contains_key(vn) {
            self.exprs.insert(vn.into(), "error".into());
            self.m.types.push(TypeDef { module: Vec::new(), name: vn.into(), generic: false, fields: None, variants: None, is_enum: false, clone: true, opaque: false, params: Vec::new(), rust_name: Some("error".into()) });
            self.statics(vn, &[("new", vec![("text", Ty::Str)], "errNew($0)".into())]);
            let s = Sig { name: "Error".into(), recv: Recv::Ref, params: Vec::new(), ret: Some(Ty::Str), skip: None, src: "func (error) Error() string".into(), generics: Vec::new(), call: None };
            self.m.methods.entry(vn.into()).or_default().push(s);
        }
        Ok(Ty::Named(vn.into()))
    }

    /// a generic type with these arguments: in a generic declaration, Name<T>; else the instance
    /// a program would name (made now)
    fn instance_ty(&mut self, n: &str, d: &DeclInfo, args: &[GT]) -> Result<Ty, String> {
        // a generic func type (iter.Seq[int]): its signature with the arguments in place
        if let Decl::Named(f @ GT::Func(..)) = &d.decl {
            let mut tps = self.tps.clone();
            for (p, a) in d.tparams.iter().zip(args) {
                let t = self.ty(a, Pos::Elem)?;
                tps.insert(p.clone(), Some((self.volt_text(&t).unwrap_or_default(), t, self.go_expr(a))));
            }
            let saved = std::mem::replace(&mut self.tps, tps);
            let r = self.ty(f, Pos::Elem);
            self.tps = saved;
            return r;
        }
        if n.contains('.') {
            // another package's generic type: a handle of its own
            return self.anonymous(&GT::Name(n.to_string(), args.to_vec()));
        }
        let mut tys = Vec::new();
        for a in args {
            tys.push(self.ty(a, Pos::Elem)?);
        }
        if args.iter().any(|a| self.has_tparam(a)) {
            return Ok(Ty::Inst(d.vname.clone(), tys));
        }
        let mut texts = Vec::new();
        for t in &tys {
            texts.push(self.volt_text(t).ok_or_else(|| format!("{n}'s instance has a type argument Volt can't name here"))?);
        }
        let line = format!("{n}\t{}", texts.join("\t"));
        self.type_instance(&line).map(Ty::Named)
    }

    /// a type as a program names it in an instance's line (voltc's names)
    fn volt_text(&self, t: &Ty) -> Option<String> {
        Some(match t {
            Ty::Prim(p) => p.to_string(),
            Ty::Str | Ty::String => "std::string<std::mem::default_allocator>".into(),
            // (an instance as voltc names it once it's made: geom::Stack__isize)
            Ty::Named(n) => self.volt_path(n),
            Ty::Vec(e) => format!("std::vec<{}, std::mem::default_allocator>", self.volt_text(e)?),
            _ => return None,
        })
    }

    /// a Volt type's Go type (an instance's type arguments)
    fn go_of(&self, t: &Ty) -> Option<String> {
        Some(match t {
            Ty::Prim(p) => go_prim(p).to_string(),
            Ty::Str | Ty::String => "string".into(),
            Ty::Named(n) => self.exprs.get(n)?.clone(),
            Ty::Vec(e) | Ty::Slice(e, _) => format!("[]{}", self.go_of(e)?),
            _ => return None,
        })
    }

    /// the instance a line asks for (Stack\tisize, Max\tisize): a type's, or a func's
    fn instance(&mut self, line: &str) {
        let mut parts = line.split('\t');
        let n = parts.next().unwrap_or("").to_string();
        let args: Vec<String> = parts.map(String::from).collect();
        let inst = instance_name(line);
        if self.decls.get(&n).is_some_and(|d| !d.tparams.is_empty()) {
            if let Err(why) = self.type_instance(line) {
                self.m.left_out.push(format!("{inst} ({why})"));
            }
            return;
        }
        if is_composite_kind(&n) {
            if let Err(why) = self.composite_instance(&n, &args, &inst) {
                self.m.left_out.push(format!("{inst} ({why})"));
            }
            return;
        }
        let Some(gs) = self.sigs.iter().find(|s| s.name == n && s.recv == "-" && !s.tparams.is_empty()).cloned() else { return };
        if self.m.fns.iter().any(|(_, s)| s.name == inst) {
            return;
        }
        let what = format!("{n}<{}>", args.join(", "));
        let r = (|| -> Result<Sig, String> {
            let gos = self.substitution(&gs.tparams, &args)?;
            let mut s = self.sig(&gs, false)?;
            s.call = Some(format!("{n}[{}]", gos.join(", ")));
            s.name = inst.clone();
            s.src = format!("{} [{}]", gs.src, gs.tparams.iter().zip(&args).map(|(p, a)| format!("{p} = {a}")).collect::<Vec<_>>().join(", "));
            Ok(s)
        })();
        self.tps.clear();
        match r {
            Ok(s) => {
                if gs.variadic {
                    self.variadic.insert(format!(".{inst}"));
                }
                self.m.fns.push((Vec::new(), s));
            }
            Err(why) => self.m.left_out.push(format!("{inst} ({what}: {why})")),
        }
    }

    /// map<K, V>, set<K> or chan<T> for these Volt types: Go's map, set or channel of theirs
    fn composite_instance(&mut self, kind: &str, args: &[String], inst: &str) -> Result<(), String> {
        let want = if kind == "map" { 2 } else { 1 };
        // (the type, if only a program names it)
        if let Some(n) = kind.strip_prefix("array").and_then(|x| x.parse::<usize>().ok()) {
            self.composite_kind(&GT::Array(n, Box::new(GT::Empty)));
        }
        if args.len() != want {
            return Err(format!("it takes {want} types"));
        }
        let mut gts = Vec::new();
        for a in args {
            let t = self.volt_arg(a).ok_or_else(|| format!("Volt's {a} has no Go type here"))?;
            gts.push(self.gt_of(&t).ok_or_else(|| format!("Volt's {a} has no Go type here"))?);
        }
        let g = match (kind, gts.as_slice()) {
            ("map", [k, v]) => GT::Map(Box::new(k.clone()), Box::new(v.clone())),
            ("set", [k]) => GT::Map(Box::new(k.clone()), Box::new(GT::Empty)),
            ("ptr", [e]) => GT::Ptr(Box::new(e.clone())),
            ("slice", [e]) => GT::Slice(Box::new(e.clone())),
            ("chan", [e]) => GT::Chan(Dir::Both, Box::new(e.clone())),
            (k, [e]) => GT::Array(k.strip_prefix("array").and_then(|x| x.parse().ok()).ok_or("its types")?, Box::new(e.clone())),
            _ => return Err("its types".into()),
        };
        self.anonymous_named(&g, inst)?;
        self.gen_gts.insert(inst.to_string(), g);
        self.inst_texts.insert(inst.to_string(), format!("{}::{kind}<{}>", self.alias, args.join(", ")));
        Ok(())
    }

    /// a type an instance's line names (voltc's text: isize, std::vec<isize, A>, geom::Point,
    /// geom::map<K, V>, geom::Stack<isize>), the instances it names made now
    fn volt_arg(&mut self, a: &str) -> Option<Ty> {
        let a = a.trim();
        // (the arguments of a type's <...>, split at its own commas)
        let split = |x: &str| -> Vec<String> {
            let (mut out, mut depth, mut cur) = (Vec::new(), 0, String::new());
            for c in x.chars() {
                match c {
                    '<' => depth += 1,
                    '>' => depth -= 1,
                    ',' if depth == 0 => {
                        out.push(cur.trim().to_string());
                        cur.clear();
                        continue;
                    }
                    _ => {}
                }
                cur.push(c);
            }
            out.push(cur.trim().to_string());
            out
        };
        if let Some(inner) = a.strip_prefix("std::vec<").and_then(|x| x.strip_suffix('>')) {
            return Some(Ty::Vec(Box::new(self.volt_arg(split(inner).first()?)?)));
        }
        if let Some((n, args)) = a.strip_prefix(self.alias).and_then(|x| x.strip_prefix("::")).and_then(|x| x.strip_suffix('>')).and_then(|x| x.split_once('<')) {
            let args = split(args);
            let line = format!("{n}\t{}", args.join("\t"));
            let inst = instance_name(&line);
            if !self.exprs.contains_key(&inst) {
                // (made outside the instance being read)
                let saved = std::mem::take(&mut self.tps);
                let r = if is_composite_kind(n) { self.composite_instance(n, &args, &inst) } else { self.type_instance(&line).map(|_| ()) };
                self.tps = saved;
                r.ok()?;
            }
            return Some(Ty::Named(inst));
        }
        let known: BTreeMap<String, Vec<String>> = self.m.types.iter().map(|t| (t.name.clone(), t.module.clone())).collect();
        volt_ty(a, self.alias, &known)
    }

    /// a Volt type as a Go one (an instance's argument)
    fn gt_of(&self, t: &Ty) -> Option<GT> {
        let name = |n: &str| GT::Name(n.into(), Vec::new());
        Some(match t {
            Ty::Prim(p) => name(go_prim(p)),
            Ty::Str | Ty::String => name("string"),
            Ty::Named(n) => match self.decls.iter().find(|(_, d)| d.vname == *n) {
                Some((g, _)) => name(g),
                None => self.gen_gts.get(n)?.clone(),
            },
            Ty::Vec(e) | Ty::Slice(e, _) => GT::Slice(Box::new(self.gt_of(e)?)),
            _ => return None,
        })
    }

    /// the type parameters as an instance's arguments (Volt type names) have them: their Go types
    fn substitution(&mut self, tparams: &[String], args: &[String]) -> Result<Vec<String>, String> {
        if args.len() != tparams.len() {
            return Err(format!("it takes {} types", tparams.len()));
        }
        let mut gos = Vec::new();
        self.tps.clear();
        for (p, a) in tparams.iter().zip(args) {
            let t = self.volt_arg(a).ok_or_else(|| format!("Volt's {a} has no Go type here"))?;
            let go = self.go_of(&t).ok_or_else(|| format!("Volt's {a} has no Go type here"))?;
            gos.push(go.clone());
            self.tps.insert(p.clone(), Some((a.clone(), t, go)));
        }
        Ok(gos)
    }

    /// a generic type's instance (line: Stack\tisize), made once: its Volt name
    fn type_instance(&mut self, line: &str) -> Result<String, String> {
        let inst = instance_name(line);
        if self.exprs.contains_key(&inst) {
            return Ok(inst);
        }
        let mut parts = line.split('\t');
        let n = parts.next().unwrap_or("").to_string();
        let args: Vec<String> = parts.map(String::from).collect();
        let d = self.decls.get(&n).cloned().ok_or_else(|| format!("{n} isn't a generic type"))?;
        let saved = std::mem::take(&mut self.tps);
        let r = (|| -> Result<(), String> {
            let gos = self.substitution(&d.tparams, &args)?;
            let expr = format!("{}[{}]", self.go_name(&n), gos.join(", "));
            self.exprs.insert(inst.clone(), expr.clone());
            self.inst_texts.insert(inst.clone(), format!("{}<{}>", self.volt_path(&d.vname), args.join(", ")));
            let gargs: Option<Vec<GT>> = d.tparams.iter().map(|p| self.tps.get(p).cloned().flatten().and_then(|x| self.gt_of(&x.1))).collect();
            if let Some(gargs) = gargs {
                self.gen_gts.insert(inst.clone(), GT::Name(n.clone(), gargs));
            }
            self.define(&n, &d, &inst, &expr)
        })();
        self.tps = saved;
        r.map(|_| inst)
    }

    /// a func's or method's signature as Volt has it; in_trait: an interface's method (its text
    /// results are std::string, which Volt's trait gives)
    fn sig(&mut self, gs: &GoSig, in_trait: bool) -> Result<Sig, String> {
        let mut params = Vec::new();
        for (i, (n, t)) in gs.params.iter().enumerate() {
            let n = if n.is_empty() || n == "_" { format!("p{i}") } else { n.clone() };
            params.push((n, Some(self.ty(t, Pos::In)?)));
        }
        let is = |g: &GT, x: &str| matches!(g, GT::Name(n, a) if n == x && a.is_empty());
        let rs = &gs.results;
        let one = |r: &mut Self, g: &GT| -> Result<Ty, String> { if in_trait && is(g, "string") { Ok(Ty::String) } else { r.ty(g, Pos::Out) } };
        let tuple = |r: &mut Self, xs: &[(String, GT)]| -> Result<Ty, String> {
            let mut es = Vec::new();
            for (n, g) in xs {
                es.push((n.clone(), r.ty(g, Pos::Out)?));
            }
            Ok(Ty::Tuple(es))
        };
        let ret = match rs.len() {
            0 => Ty::Unit,
            1 if is(&rs[0].1, "error") => Ty::Res(Box::new(Ty::Unit)),
            1 => one(self, &rs[0].1)?,
            2 if is(&rs[1].1, "error") => Ty::Res(Box::new(one(self, &rs[0].1)?)),
            2 if is(&rs[1].1, "bool") => Ty::Opt(Box::new(one(self, &rs[0].1)?)),
            n if is(&rs[n - 1].1, "error") => Ty::Res(Box::new(tuple(self, &rs[..n - 1])?)),
            _ => tuple(self, rs)?,
        };
        let recv = match gs.kind.as_str() {
            "val" => Recv::Value,
            "ptr" | "iface" => Recv::Mut,
            _ => Recv::None,
        };
        // a trait method's interface values: their handles (dyn_I), whichever way they go
        let (params, ret) = if in_trait { (params.into_iter().map(|(n, t)| (n, t.map(dyn_handle))).collect(), dyn_handle(ret)) } else { (params, ret) };
        Ok(Sig { name: gs.name.clone(), recv, params, ret: Some(ret), skip: None, src: gs.src.clone(), generics: Vec::new(), call: None })
    }

    /// an exported constant: a val of its type (a named basic type's: { value: V })
    fn constant(&mut self, name: &str, t: &str, lit: &str) {
        if lit == "big" {
            self.m.left_out.push(format!("{name} (an untyped constant no Go number can hold)"));
            return;
        }
        let ty = parse_gt(t).map(|g| self.ty(&g, Pos::Out));
        let c = match ty {
            Some(Ok(Ty::Prim(p))) => Some((p.to_string(), lit.to_string())),
            Some(Ok(Ty::Str)) => Some(("str".to_string(), lit.to_string())),
            Some(Ok(Ty::Named(n))) => match self.synth.get(&n) {
                Some(Synth::Newtype) => Some((self.volt_path(&n), format!("{{ value: {lit} }}"))),
                Some(Synth::Complex) => lit.split_once(',').map(|(re, im)| (self.volt_path(&n), format!("{{ re: {re}, im: {im} }}"))),
                // a named string type: its text
                _ if lit.starts_with('"') => Some(("str".to_string(), lit.to_string())),
                _ => None,
            },
            _ => None,
        };
        match c {
            Some((vt, v)) => self.m.consts.push((Vec::new(), name.to_string(), vt, v)),
            None => self.m.left_out.push(format!("{name} (a constant of type {t})")),
        }
    }

    /// a package variable: NAME() gives its value, set_NAME(v) sets it
    fn variable(&mut self, name: &str, t: &str) {
        let Some(g) = parse_gt(t) else { return };
        let r = (|| -> Result<(Ty, Ty), String> { Ok((self.ty(&g, Pos::Out)?, self.ty(&g, Pos::In)?)) })();
        match r {
            Ok((o, i)) => {
                let src = format!("var {name} {}", self.go_expr(&g));
                self.m.fns.push((Vec::new(), Sig { name: name.into(), recv: Recv::None, params: Vec::new(), ret: Some(o), skip: None, src: src.clone(), generics: Vec::new(), call: Some(format!("=m.{name}")) }));
                self.m.fns.push((Vec::new(), Sig { name: format!("set_{name}"), recv: Recv::None, params: vec![("value".into(), Some(i))], ret: Some(Ty::Unit), skip: None, src, generics: Vec::new(), call: Some(format!("=m.{name} = $0")) }));
            }
            Err(why) => self.m.left_out.push(format!("{name} ({why})")),
        }
    }
}

/// the shim's half: each type's and call's Go side
struct Go {
    /// the import path of the package the shim calls
    path: String,
    /// the shim's package name
    pkg: String,
    synth: BTreeMap<String, Synth>,
    /// (type or "", name) of funcs and methods whose last parameter is ...T
    variadic: BTreeSet<String>,
    /// pN -> import path
    imports: Vec<(String, String)>,
    /// what the shim's functions need, written once: Go and C helpers by name, the closures' Go
    /// types (mkfnK), the sizes of tuples results have
    helpers: RefCell<BTreeMap<String, String>>,
    c_helpers: RefCell<BTreeMap<String, String>>,
    fns: RefCell<Vec<String>>,
    tuples: RefCell<BTreeSet<usize>>,
}

impl Go {
    /// a type's Go type, from the shim
    fn path(def: &TypeDef) -> String {
        def.rust_name.clone().unwrap_or_else(|| format!("m.{}", def.name))
    }

    /// the elements' Go type of a channel type (by Volt name)
    fn chan_elem(&self, n: &str) -> Option<&str> {
        match self.synth.get(n) {
            Some(Synth::Chan(e)) => Some(e),
            _ => None,
        }
    }

    /// a Volt type's Go type, as the shim converts it
    fn go_of(&self, g: &Gen, t: &Ty) -> Option<String> {
        Some(match t {
            Ty::Prim(x) => go_prim(x).to_string(),
            Ty::Str | Ty::String => "string".into(),
            Ty::Named(_) => Self::path(&g.info(t)?.def),
            Ty::Ref(x, _) => format!("*{}", self.go_of(g, x)?),
            Ty::Vec(e) | Ty::Slice(e, _) => format!("[]{}", self.go_of(g, e)?),
            Ty::Array(e, n) => format!("[{n}]{}", self.go_of(g, e)?),
            _ => return None,
        })
    }

    /// a closure's Go type
    fn func_type(&self, g: &Gen, ps: &[Ty], r: &Ty) -> Option<String> {
        let mut a = Vec::new();
        for p in ps {
            a.push(self.cb_go(g, p)?);
        }
        let r = match r {
            Ty::Unit => String::new(),
            x => format!(" {}", self.cb_go(g, x)?),
        };
        Some(format!("func({}){r}", a.join(", ")))
    }

    /// a type's Go type in a closure's or a trait method's signature
    fn cb_go(&self, g: &Gen, t: &Ty) -> Option<String> {
        match t {
            Ty::Str | Ty::String => Some("string".into()),
            Ty::Res(x) if **x == Ty::Unit => Some("error".into()),
            Ty::Res(x) => Some(match self.cb_go(g, x)? {
                t if t.starts_with('(') => format!("{}, error)", &t[..t.len() - 1]),
                t => format!("({t}, error)"),
            }),
            Ty::Tuple(es) => Some(format!("({})", es.iter().map(|(_, t)| self.cb_go(g, t)).collect::<Option<Vec<_>>>()?.join(", "))),
            Ty::Opt(x) => Some(format!("({}, bool)", self.cb_go(g, x)?)),
            Ty::Fn(ps, r, _, _) => self.func_type(g, ps, r),
            t => self.go_of(g, t),
        }
    }

    /// a Go value x the shim hands a Volt function it calls (glue's cb_in): the C helper's
    /// parameters (as it declares them, and as the Volt function takes them), the Go lines before
    /// the call, the Go arguments, and the lines after it
    #[allow(clippy::type_complexity)]
    fn cb_in(&self, g: &Gen, t: &Ty, x: &str) -> Option<(Vec<(String, String)>, Vec<String>, Vec<String>, Vec<String>)> {
        let same = |c: &str| (c.to_string(), c.to_string());
        Some(match t {
            Ty::Prim(p) => (vec![same(c_prim(p))], Vec::new(), vec![format!("C.{}({x})", c_prim(p))], Vec::new()),
            Ty::Str | Ty::String => (vec![same("uint8_t*"), same("size_t")], Vec::new(), vec![format!("(*C.uint8_t)(unsafe.Pointer(unsafe.StringData({x})))"), format!("C.size_t(len({x}))")], Vec::new()),
            // a Go func: a handle to it, which the Volt function owns
            Ty::Fn(..) => (vec![("uintptr_t".into(), "void*".into())], Vec::new(), vec![format!("C.uintptr_t(cgo.NewHandle({x}))")], Vec::new()),
            // a *int: Go's number, which Volt may change for the call
            Ty::Ref(n, _) if matches!(**n, Ty::Prim(_)) => {
                let Ty::Prim(p) = **n else { return None };
                let c = format!("{}*", c_prim(p));
                (vec![(c.clone(), c)], Vec::new(), vec![format!("(*C.{})(unsafe.Pointer({x}))", c_prim(p))], Vec::new())
            }
            // an array: a copy, so its slice goes (nothing comes back)
            Ty::Array(e, _) => {
                let s = format!("{x}_s");
                let (cps, mut before, args, after) = self.cb_in(g, &Ty::Slice(e.clone(), false), &s)?;
                before.insert(0, format!("{s} := {x}[:]"));
                (cps, before, args, after)
            }
            // Go's numbers, lent for the call; text copied (and freed after); the package's types as
            // Volt holds them (mirrors, handles it doesn't free, enums), Volt's changes put back
            Ty::Slice(e, _) | Ty::Vec(e) => {
                let n = format!("C.size_t(len({x}))");
                match &**e {
                    Ty::Prim(_) => (vec![same("void*"), same("size_t")], Vec::new(), vec![format!("unsafe.Pointer(unsafe.SliceData({x}))"), n], Vec::new()),
                    Ty::Str | Ty::String => (vec![same("void*"), same("size_t")], vec![format!("{x}_c := cStrs({x})")], vec![format!("{x}_c"), n], vec![format!("freeStrs({x}_c, len({x}))")]),
                    Ty::Named(_) | Ty::Ref(..) => {
                        let ti = g.elem_info(e)?;
                        let (gp, mg) = (Self::path(&ti.def), Gen::mangle(&ti.def));
                        let (to, from) = match (ti.kind, matches!(**e, Ty::Ref(..))) {
                            (Kind::Plain, false) => (format!("to_{mg}"), Some(format!("from_{mg}"))),
                            (Kind::Plain, true) => (format!("func(x *{gp}) V_{mg} {{ return to_{mg}(*x) }}"), None),
                            (Kind::Handle, false) => (format!("func(x {gp}) voltH {{ return voltH{{hOf(x), true}} }}"), None),
                            (Kind::Handle, true) => (format!("func(x *{gp}) voltH {{ return voltH{{newH(x), true}} }}"), None),
                            (Kind::Enum, _) => (format!("func(x {gp}) int64 {{ return int64(x) }}"), Some(format!("func(x int64) {gp} {{ return {gp}(x) }}"))),
                        };
                        let mut after = Vec::new();
                        match (ti.kind, from) {
                            (_, Some(f)) => after.push(format!("unmap({x}, {x}_v, {f})")),
                            (Kind::Handle, None) if !matches!(**e, Ty::Ref(..)) => after.push(format!("hBackDrop({x}, {x}_v)")),
                            (Kind::Handle, None) => after.push(format!("hDrop({x}_v)")),
                            _ => {}
                        }
                        (vec![same("void*"), same("size_t")], vec![format!("{x}_v := mapped({x}, {to})")], vec![format!("unsafe.Pointer(unsafe.SliceData({x}_v))"), n], after)
                    }
                    _ => return None,
                }
            }
            Ty::Named(_) | Ty::Ref(..) => {
                let (named, by_ref) = match t {
                    Ty::Ref(x, _) => (&**x, true),
                    x => (x, false),
                };
                let ti = g.info(named)?;
                let mg = Gen::mangle(&ti.def);
                match (ti.kind, by_ref) {
                    (Kind::Plain, false) => (vec![same("void*")], vec![format!("{x}_v := to_{mg}({x})")], vec![format!("unsafe.Pointer(&{x}_v)")], Vec::new()),
                    // a *T: the Volt function changes a copy, which comes back
                    (Kind::Plain, true) => (vec![same("void*")], vec![format!("{x}_v := to_{mg}(*{x})")], vec![format!("unsafe.Pointer(&{x}_v)")], vec![format!("*{x} = from_{mg}({x}_v)")]),
                    // a handle of its own, which the Volt function frees
                    (Kind::Handle, false) => (vec![("uintptr_t".into(), "void*".into())], Vec::new(), vec![format!("C.uintptr_t(hOf({x}))")], Vec::new()),
                    (Kind::Handle, true) => (vec![("uintptr_t".into(), "void*".into())], Vec::new(), vec![format!("C.uintptr_t(newH({x}))")], Vec::new()),
                    (Kind::Enum, false) => (vec![same("int64_t")], Vec::new(), vec![format!("C.int64_t(int64({x}))")], Vec::new()),
                    _ => return None,
                }
            }
            _ => return None,
        })
    }

    /// what a Volt function the shim calls gives back (glue's cb_out; a trait method's number
    /// through o): the C helper's return type, its out parameters (declared, as the Volt function
    /// takes them), the Go lines before the call (r: a number it returns), the Go arguments, the
    /// lines after, and the Go value
    #[allow(clippy::type_complexity)]
    fn cb_out(&self, g: &Gen, r: &Ty, stored: bool, o: &str) -> Option<(String, Vec<(String, String)>, Vec<String>, Vec<String>, Vec<String>, String)> {
        let same = |c: &str| (c.to_string(), c.to_string());
        Some(match r {
            Ty::Unit => ("void".into(), Vec::new(), Vec::new(), Vec::new(), Vec::new(), String::new()),
            Ty::Prim(p) if stored => ("void".into(), vec![same(&format!("{}*", c_prim(p)))], vec![format!("var {o} C.{}", c_prim(p))], vec![format!("&{o}")], Vec::new(), format!("{}({o})", go_prim(p))),
            Ty::Prim(p) => (c_prim(p).into(), Vec::new(), Vec::new(), Vec::new(), Vec::new(), format!("{}(r)", go_prim(p))),
            // Volt's text, put (a copy) where the handle o says, while Volt's lives
            Ty::String => ("void".into(), vec![("uintptr_t".into(), "void*".into())], vec![format!("var {o} string"), format!("{o}h := cgo.NewHandle(&{o})")], vec![format!("C.uintptr_t({o}h)")], vec![format!("{o}h.Delete()")], o.into()),
            Ty::Str => ("void".into(), vec![same("uint8_t**"), same("size_t*")], vec![format!("var {o} *C.uint8_t"), format!("var {o}_n C.size_t")], vec![format!("&{o}"), format!("&{o}_n")], Vec::new(), format!("str(unsafe.Pointer({o}), uintptr({o}_n))")),
            // a slice: Volt pushes each element onto the one the handle o says
            Ty::Vec(e) | Ty::Slice(e, _) | Ty::Array(e, _) => {
                let t = self.cb_go(g, e)?;
                // (an array: exactly n of them)
                let v = match r {
                    Ty::Array(_, n) => format!("[{n}]{t}(count({o}, {n}))"),
                    _ => o.into(),
                };
                ("void".into(), vec![("uintptr_t".into(), "void*".into())], vec![format!("var {o} []{t}"), format!("{o}h := cgo.NewHandle(&{o})")], vec![format!("C.uintptr_t({o}h)")], vec![format!("{o}h.Delete()")], v)
            }
            // a Volt closure: a Go func calling it through its trampoline
            Ty::Fn(ps, r, _, _) => {
                let k = self.mkfn(g, ps, r)?;
                let outs = vec![same("void**"), same("void**"), same("void**")];
                let pre = vec![format!("var {o}, {o}_env, {o}_drop unsafe.Pointer")];
                let args = vec![format!("(*unsafe.Pointer)(unsafe.Pointer(&{o}))"), format!("(*unsafe.Pointer)(unsafe.Pointer(&{o}_env))"), format!("(*unsafe.Pointer)(unsafe.Pointer(&{o}_drop))")];
                ("void".into(), outs, pre, args, Vec::new(), format!("{k}({o}, {o}_env, {o}_drop)"))
            }
            // (T, bool): the value's outs, and whether there's one
            Ty::Opt(x) => {
                let (_, mut outs, mut pre, mut args, after, v) = self.cb_out(g, x, true, &format!("{o}v"))?;
                let t = self.cb_go(g, x)?;
                outs.push(same("bool*"));
                pre.push(format!("var {o} C.bool"));
                args.push(format!("&{o}"));
                ("void".into(), outs, pre, args, after, format!("optV(bool({o}), func() {t} {{ return {v} }})"))
            }
            // several values: each through its own outs
            Ty::Tuple(es) => {
                let (mut outs, mut pre, mut args, mut after, mut vals) = (Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new());
                for (i, (_, t)) in es.iter().enumerate() {
                    let (_, os, p, a, f, v) = self.cb_out(g, t, true, &format!("{o}{i}"))?;
                    outs.extend(os);
                    pre.extend(p);
                    args.extend(a);
                    after.extend(f);
                    vals.push(v);
                }
                ("void".into(), outs, pre, args, after, vals.join(", "))
            }
            Ty::Named(_) | Ty::Ref(_, false) => {
                let (named, by_ref) = match r {
                    Ty::Ref(x, _) => (&**x, true),
                    x => (x, false),
                };
                let ti = g.info(named)?;
                let (gp, mg) = (Self::path(&ti.def), Gen::mangle(&ti.def));
                match (ti.kind, by_ref) {
                    (Kind::Plain, false) => ("void".into(), vec![same("void*")], vec![format!("var {o} V_{mg}")], vec![format!("unsafe.Pointer(&{o})")], Vec::new(), format!("from_{mg}({o})")),
                    // a *T: a pointer to a copy
                    (Kind::Plain, true) => ("void".into(), vec![same("void*")], vec![format!("var {o} V_{mg}")], vec![format!("unsafe.Pointer(&{o})")], Vec::new(), format!("ptrTo(from_{mg}({o}))")),
                    // the handle Volt gave up: its value, the handle deleted
                    (Kind::Handle, _) => ("void".into(), vec![same("void*")], vec![format!("var {o} C.uintptr_t")], vec![format!("unsafe.Pointer(&{o})")], Vec::new(), format!("{}[{gp}](uintptr({o}))", if by_ref { "takeP" } else { "takeH" })),
                    (Kind::Enum, false) => ("void".into(), vec![same("int64_t*")], vec![format!("var {o} C.int64_t")], vec![format!("&{o}")], Vec::new(), format!("{gp}({o})")),
                    _ => return None,
                }
            }
            _ => return None,
        })
    }

    /// a Go func's body calling Volt function f (its env, data g) through C helper c: params' Go
    /// names x0.., what it gives back
    fn cb_call(&self, g: &Gen, ps: &[Ty], r: &Ty, c: &str, f: &str, env: &str, keep: &str, trait_method: bool) -> Option<(String, String, String)> {
        let (mut cparams, mut ctypes, mut cargs) = (vec!["void* env".to_string()], vec!["void*".to_string()], vec!["env".to_string()]);
        let (mut gps, mut pre, mut gargs) = (Vec::new(), Vec::new(), vec![f.to_string(), env.to_string()]);
        let mut slot = 0;
        let mut add = |cps: Vec<(String, String)>, cparams: &mut Vec<String>, ctypes: &mut Vec<String>, cargs: &mut Vec<String>| {
            for (decl, fty) in cps {
                cparams.push(format!("{decl} c{slot}"));
                cargs.push(if decl == fty { format!("c{slot}") } else { format!("({fty})c{slot}") });
                ctypes.push(fty);
                slot += 1;
            }
        };
        let mut back = Vec::new();
        for (i, t) in ps.iter().enumerate() {
            let x = format!("x{i}");
            let (cps, before, args, after) = self.cb_in(g, t, &x)?;
            gps.push(format!("{x} {}", self.cb_go(g, t)?));
            add(cps, &mut cparams, &mut ctypes, &mut cargs);
            pre.extend(before);
            gargs.extend(args);
            back.extend(after);
        }
        // an error: status 1, its text put where the handle eh says
        let (val, res) = match r {
            Ty::Res(x) => (&**x, true),
            x => (x, false),
        };
        let (mut crt, mut outs, before, args, mut after, value) = self.cb_out(g, val, trait_method || res, "o")?;
        let mut gargs_out = args;
        let mut pre_out = before;
        if res {
            crt = "uint8_t".into();
            outs.push(("uintptr_t".into(), "void*".into()));
            pre_out.extend(["var eo string".to_string(), "eh := cgo.NewHandle(&eo)".to_string()]);
            gargs_out.push("C.uintptr_t(eh)".into());
            after.push("eh.Delete()".into());
        }
        add(outs, &mut cparams, &mut ctypes, &mut cargs);
        pre.extend(pre_out);
        gargs.extend(gargs_out);
        let call = format!("C.{c}({})", gargs.join(", "));
        let mut body: String = pre.iter().map(|l| format!("\t{l}\n")).collect();
        let _ = writeln!(body, "\t{}{call}", if crt == "void" { "" } else { "r := " });
        for l in back.iter().chain(&after) {
            let _ = writeln!(body, "\t{l}");
        }
        let _ = writeln!(body, "\truntime.KeepAlive({keep})");
        if res {
            let zero = match val {
                Ty::Unit => String::new(),
                Ty::Tuple(es) => es.iter().map(|(_, t)| self.cb_go(g, t).map(|t| format!("*new({t}), "))).collect::<Option<String>>()?,
                v => format!("*new({}), ", self.cb_go(g, v)?),
            };
            let ok = if *val == Ty::Unit { String::new() } else { format!("{value}, ") };
            let _ = writeln!(body, "\tif r != 0 {{\n\t\treturn {zero}errNew(eo)\n\t}}\n\treturn {ok}nil");
        } else if !value.is_empty() {
            let _ = writeln!(body, "\treturn {value}");
        }
        let ret = if crt == "void" { "" } else { "return " };
        let helper = format!("static inline {crt} {c}(void* f, {}) {{ {ret}(({crt} (*)({}))f)({}); }}\n", cparams.join(", "), ctypes.join(", "), cargs.join(", "));
        Some((gps.join(", "), body, helper))
    }

    /// the function making a Go func of a Volt closure of this signature (its trampoline f, its
    /// data env, and drop, which frees it once Go's collector is done with the func): mkfnK
    fn mkfn(&self, g: &Gen, ps: &[Ty], r: &Ty) -> Option<String> {
        let ft = self.func_type(g, ps, r)?;
        let k = {
            let mut fns = self.fns.borrow_mut();
            match fns.iter().position(|x| *x == ft) {
                Some(k) => k,
                None => {
                    fns.push(ft.clone());
                    fns.len() - 1
                }
            }
        };
        let name = format!("mkfn{k}");
        if self.helpers.borrow().contains_key(&name) {
            return Some(name);
        }
        let (gps, body, helper) = self.cb_call(g, ps, r, &format!("volt_tramp{k}"), "f", "g.env", "g", false)?;
        let body = body.replace("\n\t", "\n\t\t").replacen('\t', "\t\t", 1);
        let grt = match r {
            Ty::Unit => String::new(),
            r => format!(" {}", self.cb_go(g, r)?),
        };
        self.c_helpers.borrow_mut().insert(format!("volt_tramp{k}"), helper);
        self.helpers.borrow_mut().insert(name.clone(), format!("// a Volt {ft}, as a Go func\nfunc {name}(f, env, drop unsafe.Pointer) {ft} {{\n\tg := newEnv(env, drop)\n\treturn func({gps}){grt} {{\n{body}\t}}\n}}\n\n"));
        Some(name)
    }

    /// Volt's elements (a, a_n) as the call's slice: the expression, what comes before it, and what
    /// puts the call's changes back after it
    fn elems_in(&self, g: &Gen, e: &Ty, a: &str) -> Option<(String, Option<String>, Option<String>)> {
        Some(match e {
            Ty::Prim(x) => (format!("sl[{}]({a}, {a}_n)", go_prim(x)), None, None),
            Ty::Str | Ty::String => (format!("strs({a}, {a}_n)"), None, None),
            // lists of numbers: Volt's lists, in place (each as a pointer and a length)
            Ty::Vec(x) if matches!(**x, Ty::Prim(_)) => {
                let Ty::Prim(x) = &**x else { return None };
                let t = go_prim(x);
                (format!("each({a}, {a}_n, func(x voltStr) []{t} {{ return sl[{t}](x.p, x.n) }})"), None, None)
            }
            Ty::Named(_) | Ty::Ref(..) => {
                let ti = g.elem_info(e)?;
                let (gp, mg) = (Self::path(&ti.def), Gen::mangle(&ti.def));
                let (f, back) = match (ti.kind, matches!(e, Ty::Ref(..))) {
                    (Kind::Plain, false) => (format!("from_{mg}"), Some(format!("back({a}, {a}_s, to_{mg})"))),
                    (Kind::Plain, true) => (format!("func(x V_{mg}) *{gp} {{ v := from_{mg}(x); return &v }}"), Some(format!("back({a}, {a}_s, func(x *{gp}) V_{mg} {{ return to_{mg}(*x) }})"))),
                    (Kind::Handle, false) => (format!("hvOf[{gp}]"), Some(format!("hBack({a}, {a}_s)"))),
                    (Kind::Handle, true) => (format!("hpOf[{gp}]"), None),
                    (Kind::Enum, _) => (format!("func(x int64) {gp} {{ return {gp}(x) }}"), Some(format!("back({a}, {a}_s, func(x {gp}) int64 {{ return int64(x) }})"))),
                };
                (format!("{a}_s"), Some(format!("{a}_s := each({a}, {a}_n, {f})")), back)
            }
            _ => return None,
        })
    }

    /// a call's elements (v, a slice) for Volt (o, o_n)
    fn elems_out(&self, g: &Gen, e: &Ty, v: &str, o: &str) -> Option<String> {
        Some(match e {
            Ty::Prim(x) => format!("putSl[{}]({v}, {o}, {o}_n)", go_prim(x)),
            Ty::Str | Ty::String => format!("putStrs({v}, {o}, {o}_n)"),
            Ty::Named(_) | Ty::Ref(..) => {
                let ti = g.elem_info(e)?;
                let (gp, mg) = (Self::path(&ti.def), Gen::mangle(&ti.def));
                let f = match (ti.kind, matches!(e, Ty::Ref(..))) {
                    (Kind::Plain, false) => format!("to_{mg}"),
                    (Kind::Plain, true) => format!("func(x *{gp}) V_{mg} {{ return to_{mg}(*x) }}"),
                    (Kind::Handle, false) => format!("hOf[{gp}]"),
                    (Kind::Handle, true) => format!("newH[{gp}]"),
                    (Kind::Enum, _) => format!("func(x {gp}) int64 {{ return int64(x) }}"),
                };
                format!("putEach({v}, {o}, {o}_n, {f})")
            }
            _ => return None,
        })
    }
}

/// a call template's text with its receiver ($r) and arguments ($0, $1...) in place
fn template(t: &str, recv: &str, args: &[String]) -> String {
    let mut s = t.replace("$r", recv);
    for (i, a) in args.iter().enumerate().rev() {
        s = s.replace(&format!("${i}"), a);
    }
    s
}

impl Lang for Go {
    fn catches(&self) -> bool {
        true
    }

    fn cb_types(&self) -> bool {
        true
    }

    fn short(&self) -> &'static str {
        "go"
    }

    fn name(&self) -> &'static str {
        "Go"
    }

    fn by_value_moves(&self, _ti: &TypeInfo) -> bool {
        // a Go value passed by value is copied, as Go copies it
        false
    }

    fn param(&self, g: &Gen, t: &Ty, a: &str) -> Option<ShimParam> {
        let mut p = ShimParam::default();
        match t {
            Ty::Prim(x) => {
                p.params.push(format!("{a} {}", go_prim(x)));
                p.arg = a.to_string();
            }
            Ty::Str | Ty::String => {
                p.params.extend([format!("{a} unsafe.Pointer"), format!("{a}_n uintptr")]);
                p.arg = format!("str({a}, {a}_n)");
            }
            // *int and such: Volt's number, which the call may change
            Ty::Ref(x, true) if matches!(**x, Ty::Prim(_)) => {
                let Ty::Prim(x) = **x else { return None };
                p.params.push(format!("{a} unsafe.Pointer"));
                p.pre.push(format!("{a}_v := *(*{})({a})", go_prim(x)));
                p.arg = format!("&{a}_v");
                p.post.push(format!("*(*{})({a}) = {a}_v", go_prim(x)));
            }
            Ty::Slice(e, _) | Ty::Vec(e) | Ty::Array(e, _) => {
                p.params.extend([format!("{a} unsafe.Pointer"), format!("{a}_n uintptr")]);
                let (arg, pre, back) = self.elems_in(g, e, a)?;
                p.pre.extend(pre);
                if let Ty::Array(_, n) = t {
                    // an array is a copy: n elements, and nothing comes back
                    let et = match &**e {
                        Ty::Str | Ty::String => "string".to_string(),
                        e => self.go_of(g, e)?,
                    };
                    p.arg = format!("[{n}]{et}(count({arg}, {n}))");
                } else {
                    p.arg = arg;
                    p.post.extend(back);
                }
            }
            Ty::Named(_) | Ty::Ref(..) => {
                let (named, by_ref, mutable) = match t {
                    Ty::Ref(x, m) => (&**x, true, *m),
                    x => (x, false, false),
                };
                let ti = g.info(named)?;
                let (gp, mg) = (Self::path(&ti.def), Gen::mangle(&ti.def));
                match ti.kind {
                    Kind::Plain => {
                        p.params.push(format!("{a} unsafe.Pointer"));
                        if by_ref {
                            // a *T: Go may change it, and the change comes back
                            p.pre.push(format!("{a}_v := from_{mg}(*(*V_{mg})({a}))"));
                            p.arg = format!("&{a}_v");
                            p.post.push(format!("*(*V_{mg})({a}) = to_{mg}({a}_v)"));
                        } else {
                            p.arg = format!("from_{mg}(*(*V_{mg})({a}))");
                        }
                    }
                    Kind::Handle => {
                        p.params.push(format!("{a} uintptr"));
                        p.arg = match (self.chan_elem(&ti.def.name), by_ref, mutable) {
                            // a channel, as the way the call takes it
                            (Some(_), false, _) => format!("chanAs[{gp}]({a})"),
                            (Some(e), true, false) => format!("chanAs[<-chan {e}]({a})"),
                            (Some(e), true, true) => format!("chanAs[chan<- {e}]({a})"),
                            (None, true, _) => format!("hptr[{gp}]({a})"),
                            (None, false, _) => format!("*hptr[{gp}]({a})"),
                        };
                    }
                    Kind::Enum => {
                        if by_ref {
                            return None;
                        }
                        p.params.push(format!("{a} int64"));
                        p.arg = format!("{gp}({a})");
                    }
                }
            }
            // a Volt closure: a Go func calling it through its trampoline
            Ty::Fn(ps, r, _, _) => {
                let k = self.mkfn(g, ps, r)?;
                p.params.extend([format!("{a} unsafe.Pointer"), format!("{a}_env unsafe.Pointer"), format!("{a}_drop unsafe.Pointer")]);
                p.arg = format!("{k}({a}, {a}_env, {a}_drop)");
            }
            // a Volt value of a type attaching the trait, and its methods' table: a Go value
            Ty::Dyn(tr, _) => {
                let mg = Gen::trait_mangle(g.traits.get(tr)?);
                p.params.extend([format!("{a} unsafe.Pointer"), format!("{a}_t unsafe.Pointer")]);
                p.arg = format!("mk_{mg}({a}, {a}_t)");
            }
            _ => return None,
        }
        Some(p)
    }

    fn receiver(&self, _g: &Gen, ti: &TypeInfo, recv: Recv) -> Option<ShimParam> {
        let (gp, mg) = (Self::path(&ti.def), Gen::mangle(&ti.def));
        let mut p = ShimParam::default();
        match ti.kind {
            Kind::Plain => {
                p.params.push("this unsafe.Pointer".into());
                p.pre.push(format!("this_v := from_{mg}(*(*V_{mg})(this))"));
                if recv == Recv::Mut {
                    p.post.push(format!("*(*V_{mg})(this) = to_{mg}(this_v)"));
                }
                p.arg = "this_v".into();
            }
            Kind::Handle => {
                p.params.push("this uintptr".into());
                // the value itself (addressable: a method on *T changes it); a channel as Go made it
                p.arg = if self.chan_elem(&ti.def.name).is_some() { "cgo.Handle(this).Value()".into() } else { format!("(*hptr[{gp}](this))") };
            }
            Kind::Enum => {
                if recv == Recv::Mut {
                    return None;
                }
                p.params.push("this int64".into());
                p.arg = format!("{gp}(this)");
            }
        }
        Some(p)
    }

    fn out(&self, g: &Gen, t: &Ty, o: &str, _owned: bool) -> Option<ShimOut> {
        let ptrs = |names: &[&str]| names.iter().map(|n| format!("{n} unsafe.Pointer")).collect::<Vec<_>>();
        Some(match t {
            Ty::Prim(x) => ShimOut { params: ptrs(&[o]), store: format!("*(*{})({o}) = $v", go_prim(x)) },
            Ty::Str | Ty::String => ShimOut { params: ptrs(&[o, &format!("{o}_n")]), store: format!("putStr($v, {o}, {o}_n)") },
            Ty::Slice(e, _) | Ty::Vec(e) | Ty::Array(e, _) => {
                let v = if matches!(t, Ty::Array(..)) { "$v[:]" } else { "$v" };
                ShimOut { params: ptrs(&[o, &format!("{o}_n")]), store: self.elems_out(g, e, v, o)? }
            }
            Ty::Named(_) | Ty::Ref(..) => {
                let (named, by_ref) = match t {
                    Ty::Ref(x, _) => (&**x, true),
                    x => (x, false),
                };
                let ti = g.info(named)?;
                let mg = Gen::mangle(&ti.def);
                match (ti.kind, by_ref) {
                    (Kind::Plain, false) => ShimOut { params: ptrs(&[o]), store: format!("*(*V_{mg})({o}) = to_{mg}($v)") },
                    (Kind::Plain, true) => ShimOut { params: ptrs(&[o]), store: format!("*(*V_{mg})({o}) = to_{mg}(*$v)") },
                    // a *T: a handle to that same value; a T: to a copy of it
                    (Kind::Handle, true) => ShimOut { params: ptrs(&[o]), store: format!("*(*uintptr)({o}) = newH($v)") },
                    (Kind::Handle, false) => ShimOut { params: ptrs(&[o]), store: format!("{o}_x := $v\n\t*(*uintptr)({o}) = newH(&{o}_x)") },
                    (Kind::Enum, false) => ShimOut { params: ptrs(&[o]), store: format!("*(*int64)({o}) = int64($v)") },
                    (Kind::Enum, true) => return None,
                }
            }
            // a Go value of an interface: a handle (dyn_I)
            Ty::Dyn(..) => ShimOut { params: ptrs(&[o]), store: format!("{o}_x := $v\n\t*(*uintptr)({o}) = newH(&{o}_x)") },
            // a Go func: a handle to it, which Volt calls
            Ty::Fn(ps, r, _, _) => ShimOut { params: ptrs(&[o]), store: format!("*(*uintptr)({o}) = uintptr(cgo.NewHandle(({})($v)))", self.func_type(g, ps, r)?) },
            Ty::Opt(inner) => {
                let x = self.out(g, inner, o, false)?;
                let mut params = ptrs(&[&format!("{o}_has")]);
                params.extend(x.params);
                let inner = x.store.replace("$v", "$v.v").replace("\n\t", "\n\t\t");
                ShimOut { params, store: format!("if $v.ok {{\n\t\t*(*bool)({o}_has) = true\n\t\t{inner}\n\t}}") }
            }
            // several results: each in its own outs
            Ty::Tuple(es) => {
                let (mut params, mut stores) = (Vec::new(), Vec::new());
                for (i, (_, et)) in es.iter().enumerate() {
                    let x = self.out(g, et, &format!("{o}{i}"), false)?;
                    params.extend(x.params);
                    stores.push(x.store.replace("$v", &format!("$v.f{i}")));
                }
                ShimOut { params, store: stores.join("\n\t") }
            }
            _ => return None,
        })
    }

    fn call(&self, _g: &Gen, _module: &[String], s: &Sig, self_ty: Option<&TypeInfo>, recv: Option<&str>, args: &[String]) -> String {
        let mut args = args.to_vec();
        // ...T: the slice spread
        if self.variadic.contains(&format!("{}.{}", self_ty.map_or("", |t| t.def.name.as_str()), s.name)) {
            if let Some(l) = args.last_mut() {
                l.push_str("...");
            }
        }
        let call = match (&s.call, recv) {
            // the shim's own (a handle type's get, put...; a package variable)
            (Some(c), _) if c.starts_with('=') => template(&c[1..], recv.unwrap_or(""), &args),
            (Some(c), Some(r)) => format!("{r}.{c}({})", args.join(", ")),
            // a generic's instance: Name[types]
            (Some(c), None) => format!("m.{c}({})", args.join(", ")),
            (None, Some(r)) => format!("{r}.{}({})", s.name, args.join(", ")),
            (None, None) => format!("m.{}({})", s.name, args.join(", ")),
        };
        // (T, bool) as one value; several results as one
        match &s.ret {
            Some(Ty::Opt(_)) => format!("mkopt({call})"),
            Some(Ty::Tuple(es)) => {
                self.tuples.borrow_mut().insert(es.len());
                format!("tup{}({call})", es.len())
            }
            Some(Ty::Res(x)) => match &**x {
                Ty::Tuple(es) => {
                    self.tuples.borrow_mut().insert(es.len());
                    format!("tup{}e({call})", es.len())
                }
                _ => call,
            },
            _ => call,
        }
    }

    fn function(&self, sym: &str, params: &[String], pre: &[String], call: &str, post: &[String], store: Option<&str>, res: bool) -> String {
        let mut ps = params.to_vec();
        ps.extend(["e unsafe.Pointer".to_string(), "e_n unsafe.Pointer".to_string()]);
        // a panic is its text for Volt (status 2): it never unwinds through C
        let mut body = String::from("\tdefer catch(&st, e, e_n)\n");
        for l in pre {
            let _ = writeln!(body, "\t{l}");
        }
        // a *T parameter's changes come back even when the call fails
        let post = |body: &mut String| {
            for l in post {
                let _ = writeln!(body, "\t{l}");
            }
        };
        let fail = "\tif err != nil {\n\t\tputStr(err.Error(), e, e_n)\n\t\treturn 1\n\t}\n";
        match (store, res) {
            (Some(st), true) => {
                let _ = writeln!(body, "\tv, err := {call}");
                post(&mut body);
                body.push_str(fail);
                let _ = writeln!(body, "\t{}", st.replace("$v", "v"));
            }
            (None, true) => {
                let _ = writeln!(body, "\terr := {call}");
                post(&mut body);
                body.push_str(fail);
            }
            (Some(st), false) => {
                let _ = writeln!(body, "\tv := {call}");
                post(&mut body);
                let _ = writeln!(body, "\t{}", st.replace("$v", "v"));
            }
            (None, false) => {
                let _ = writeln!(body, "\t{call}");
                post(&mut body);
            }
        }
        body.push_str("\treturn 0\n");
        format!("//export {sym}\nfunc {sym}({}) (st uint8) {{\n{body}}}\n\n", ps.join(", "))
    }

    fn type_glue(&self, g: &Gen, ti: &TypeInfo) -> String {
        let (gp, mg) = (Self::path(&ti.def), Gen::mangle(&ti.def));
        let mut out = String::new();
        let fields = ti.def.fields.clone().unwrap_or_default();
        match (ti.kind, self.synth.get(&ti.def.name)) {
            // a named basic type: its value
            (Kind::Plain, Some(Synth::Newtype)) => {
                let Some((_, _, Some(Ty::Prim(x)))) = fields.first() else { return out };
                let t = go_prim(x);
                let _ = write!(out, "type V_{mg} struct {{\n\tvalue {t}\n}}\n\nfunc from_{mg}(v V_{mg}) {gp} {{\n\treturn {gp}(v.value)\n}}\n\nfunc to_{mg}(v {gp}) V_{mg} {{\n\treturn V_{mg}{{value: {t}(v)}}\n}}\n\n");
            }
            (Kind::Plain, Some(Synth::Complex)) => {
                let Some((_, _, Some(Ty::Prim(x)))) = fields.first() else { return out };
                let t = go_prim(x);
                let _ = write!(out, "type V_{mg} struct {{\n\tre {t}\n\tim {t}\n}}\n\nfunc from_{mg}(v V_{mg}) {gp} {{\n\treturn {gp}(complex(v.re, v.im))\n}}\n\nfunc to_{mg}(v {gp}) V_{mg} {{\n\treturn V_{mg}{{{t}(real(v)), {t}(imag(v))}}\n}}\n\n");
            }
            (Kind::Plain, _) => {
                let (mut fs, mut from, mut to) = (String::new(), String::new(), String::new());
                for (f, _, t) in fields {
                    match t {
                        Some(Ty::Prim(x)) => {
                            let _ = writeln!(fs, "\t{f} {}", go_prim(x));
                            let _ = write!(from, "{f}: v.{f}, ");
                            let _ = write!(to, "{f}: v.{f}, ");
                        }
                        Some(Ty::Named(n)) => {
                            let o = &g.types[&n];
                            let (op, omg) = (Self::path(&o.def), Gen::mangle(&o.def));
                            if o.kind == Kind::Enum {
                                let _ = writeln!(fs, "\t{f} int64");
                                let _ = write!(from, "{f}: {op}(v.{f}), ");
                                let _ = write!(to, "{f}: int64(v.{f}), ");
                            } else {
                                let _ = writeln!(fs, "\t{f} V_{omg}");
                                let _ = write!(from, "{f}: from_{omg}(v.{f}), ");
                                let _ = write!(to, "{f}: to_{omg}(v.{f}), ");
                            }
                        }
                        _ => {}
                    }
                }
                // the Volt struct's layout, field for field
                let _ = write!(out, "type V_{mg} struct {{\n{fs}}}\n\nfunc from_{mg}(v V_{mg}) {gp} {{\n\treturn {gp}{{{from}}}\n}}\n\nfunc to_{mg}(v {gp}) V_{mg} {{\n\treturn V_{mg}{{{to}}}\n}}\n\n");
            }
            (Kind::Handle, _) => {
                let (drop, clone) = (g.sym(&[&mg, "drop"]), g.sym(&[&mg, "clone"]));
                let _ = write!(out, "//export {drop}\nfunc {drop}(h uintptr) {{\n\tcgo.Handle(h).Delete()\n}}\n\n");
                if ti.def.clone {
                    let _ = write!(out, "//export {clone}\nfunc {clone}(h uintptr) uintptr {{\n\treturn hcopy(h)\n}}\n\n");
                }
            }
            (Kind::Enum, _) => {}
        }
        out
    }

    fn fn_glue(&self, g: &Gen, sym: &str, ps: &[Ty], r: &Ty, _once: bool) -> Option<String> {
        let ft = self.func_type(g, ps, r)?;
        // its parameters and result as a function's
        let mut cps = vec!["h uintptr".to_string()];
        let (mut pre, mut args, mut post) = (Vec::new(), Vec::new(), Vec::new());
        for (i, t) in ps.iter().enumerate() {
            let p = self.param(g, t, &format!("a{i}"))?;
            cps.extend(p.params);
            pre.extend(p.pre);
            args.push(p.arg);
            post.extend(p.post);
        }
        let call = format!("f({})", args.join(", "));
        let mut body: String = pre.iter().map(|l| format!("\t{l}\n")).collect();
        let fail = "if err != nil {\n\t\tputStr(err.Error(), e, e_n)\n\t\treturn 1\n\t}".to_string();
        match r {
            Ty::Unit => {
                let _ = writeln!(body, "\t{call}");
            }
            Ty::Res(x) if **x == Ty::Unit => {
                let _ = writeln!(body, "\terr := {call}");
                post.push(fail);
            }
            Ty::Res(x) => {
                let o = self.out(g, x, "o", false)?;
                cps.extend(o.params);
                let call = match &**x {
                    Ty::Tuple(es) => {
                        self.tuples.borrow_mut().insert(es.len());
                        format!("tup{}e({call})", es.len())
                    }
                    _ => call,
                };
                let _ = writeln!(body, "\tv, err := {call}");
                post.extend([fail, o.store.replace("$v", "v")]);
            }
            r => {
                let o = self.out(g, r, "o", false)?;
                cps.extend(o.params);
                let call = match r {
                    Ty::Tuple(es) => {
                        self.tuples.borrow_mut().insert(es.len());
                        format!("tup{}({call})", es.len())
                    }
                    Ty::Opt(_) => format!("mkopt({call})"),
                    _ => call,
                };
                let _ = writeln!(body, "\tv := {call}");
                post.push(o.store.replace("$v", "v"));
            }
        }
        for l in post {
            let _ = writeln!(body, "\t{l}");
        }
        cps.extend(["e unsafe.Pointer".to_string(), "e_n unsafe.Pointer".to_string()]);
        Some(format!("//export {sym}_call\nfunc {sym}_call({}) (st uint8) {{\n\tdefer catch(&st, e, e_n)\n\tf := cgo.Handle(h).Value().({ft})\n{body}\treturn 0\n}}\n\n//export {sym}_drop\nfunc {sym}_drop(h uintptr) {{\n\tcgo.Handle(h).Delete()\n}}\n\n", cps.join(", ")))
    }

    fn trait_glue(&self, g: &Gen, t: &TraitDef, ms: &[(Sig, bool)]) -> Option<String> {
        let mg = Gen::trait_mangle(t);
        // the interface's Go type (its values' handle's)
        let gi = g.types.values().find(|ti| ti.def.name == format!("dyn_{}", t.name) && ti.def.module == t.module).map(|ti| Self::path(&ti.def))?;
        let mut fields = vec!["\tdrop unsafe.Pointer".to_string()];
        let mut methods = String::new();
        for (s, _) in ms {
            let n = &s.name;
            fields.push(format!("\tm_{n} unsafe.Pointer"));
            let ps: Vec<Ty> = s.params.iter().map(|(_, t)| t.clone()).collect::<Option<_>>()?;
            let r = s.ret.as_ref()?;
            let c = format!("volt_tc_{mg}_{n}");
            let (gps, body, helper) = self.cb_call(g, &ps, r, &c, &format!("v.t.m_{n}"), "v.g.env", "v.g", true)?;
            let grt = match r {
                Ty::Unit => String::new(),
                r => format!(" {}", self.cb_go(g, r)?),
            };
            self.c_helpers.borrow_mut().insert(c, helper);
            let _ = write!(methods, "func (v *volt_{mg}) {n}({gps}){grt} {{\n{body}}}\n\n");
        }
        Some(format!("// {mg} on a Volt value: its methods' table (drop: null when the value is lent), and the Go type\n// with the interface's methods calling them\ntype vt_{mg} struct {{\n{}\n}}\n\ntype volt_{mg} struct {{\n\tg *voltEnv\n\tt vt_{mg}\n}}\n\nfunc mk_{mg}(env, t unsafe.Pointer) {gi} {{\n\tif t == nil {{\n\t\t// Go's own value of it (dyn_{mg})\n\t\treturn *hptr[{gi}](uintptr(env))\n\t}}\n\tv := &volt_{mg}{{t: *(*vt_{mg})(t)}}\n\tv.g = newEnv(env, v.t.drop)\n\treturn v\n}}\n\n{methods}", fields.join("\n")))
    }

    fn push_glue(&self, g: &Gen, sym: &str, e: &Ty) -> Option<String> {
        let p = self.param(g, if *e == Ty::String { &Ty::Str } else { e }, "a")?;
        let t = self.cb_go(g, e)?;
        let pre: String = p.pre.iter().map(|l| format!("\t{l}\n")).collect();
        let post: String = p.post.iter().map(|l| format!("\t{l}\n")).collect();
        // (a panic, as the argument's handle being invalid, is recovered: it never unwinds through the Volt function)
        Some(format!("// an element of a Volt function's slice result, appended to the slice o (a handle) says\n//export {sym}\nfunc {sym}(o uintptr, {}, e, e_n unsafe.Pointer) (st uint8) {{\n\tdefer catch(&st, e, e_n)\n{pre}\tp := cgo.Handle(o).Value().(*[]{t})\n\t*p = append(*p, {})\n{post}\treturn 0\n}}\n\n", p.params.join(", "), p.arg))
    }

    fn put_glue(&self, sym: &str) -> Option<String> {
        Some(format!("// text a Volt function gives back, put where o (a handle of a *string) says\n//export {sym}\nfunc {sym}(o unsafe.Pointer, p unsafe.Pointer, n uintptr) {{\n\t*cgo.Handle(uintptr(o)).Value().(*string) = str(p, n)\n}}\n\n"))
    }

    fn prelude(&self, g: &Gen) -> String {
        let free = |what: &str| format!("volt_go_{}_free_{what}", g.alias);
        // the other packages the types name (each named: an unused import doesn't build)
        let exprs: Vec<String> = g.types.values().map(|ti| Self::path(&ti.def)).collect();
        let mut imports = String::new();
        let mut uses = String::new();
        for (a, path) in &self.imports {
            let used: Vec<&String> = exprs.iter().filter(|e| e.contains(&format!("{a}."))).collect();
            if used.is_empty() {
                continue;
            }
            let _ = writeln!(imports, "\t{a} \"{path}\"");
            for e in used {
                let _ = writeln!(uses, "var _ *{e}");
            }
        }
        let c: String = self.c_helpers.borrow().values().cloned().collect();
        let mut s = format!(
            "// the glue between a Volt program and package {}, written by bolt import (use go)\npackage {}\n\n/*\n#include <stdlib.h>\n#include <stdint.h>\n#include <stdbool.h>\n\nstatic inline void volt_drop(void* f, void* env) {{ ((void (*)(void*))f)(env); }}\n{c}*/\nimport \"C\"\n\nimport (\n\t\"fmt\"\n\t\"reflect\"\n\t\"runtime\"\n\t\"runtime/cgo\"\n\t\"unsafe\"\n\n\tm \"{}\"\n{imports})\n\n{uses}",
            self.path, self.pkg, self.path
        );
        s.push_str(PRELUDE);
        for n in self.tuples.borrow().iter() {
            let ps: Vec<String> = (0..*n).map(|i| format!("A{i}")).collect();
            let fs: String = (0..*n).map(|i| format!("\tf{i} A{i}\n")).collect();
            let args: Vec<String> = (0..*n).map(|i| format!("a{i} A{i}")).collect();
            let vals: Vec<String> = (0..*n).map(|i| format!("a{i}")).collect();
            let (ps, args, vals) = (ps.join(", "), args.join(", "), vals.join(", "));
            let _ = write!(s, "// {n} results as one value\ntype t{n}[{ps} any] struct {{\n{fs}}}\n\nfunc tup{n}[{ps} any]({args}) t{n}[{ps}] {{\n\treturn t{n}[{ps}]{{{vals}}}\n}}\n\nfunc tup{n}e[{ps} any]({args}, err error) (t{n}[{ps}], error) {{\n\treturn t{n}[{ps}]{{{vals}}}, err\n}}\n\n");
        }
        for h in self.helpers.borrow().values() {
            s.push_str(h);
        }
        let q = format!("volt_go_{}_quiet", g.alias);
        let _ = write!(s, "// a try_ form's call: Go says nothing of a panic it recovers, so there's nothing to quiet\n//export {q}\nfunc {q}(on bool) bool {{\n\treturn false\n}}\n\n");
        let _ = write!(s, "//export {}\nfunc {}(p unsafe.Pointer, n uintptr) {{\n\tC.free(p)\n}}\n\n", free("bytes"), free("bytes"));
        let mut frees: Vec<String> = g.vec_elems.iter().map(|x| format!("{x}s")).collect();
        for n in &g.elem_types {
            match g.types.get(n).map(|ti| ti.kind) {
                Some(Kind::Handle) => frees.push("ptrs".into()),
                Some(Kind::Plain) => frees.push(format!("{}s", Gen::mangle(&g.types[n].def))),
                _ => {}
            }
        }
        frees.sort();
        frees.dedup();
        for x in frees {
            let f = free(&x);
            let _ = write!(s, "//export {f}\nfunc {f}(p unsafe.Pointer, n uintptr) {{\n\tC.free(p)\n}}\n\n");
        }
        if g.strs {
            let f = free("strs");
            let _ = write!(s, "//export {f}\nfunc {f}(p unsafe.Pointer, n uintptr) {{\n\tfor _, x := range unsafe.Slice((*voltStr)(p), n) {{\n\t\tC.free(x.p)\n\t}}\n\tC.free(p)\n}}\n\n");
        }
        s
    }
}

/// the shim's helpers: Volt's memory as Go values, Go's values copied to the C heap for Volt,
/// handles, channels, maps, panics
const PRELUDE: &str = r#"// a str as Volt passes it in a list
type voltStr struct {
	p unsafe.Pointer
	n uintptr
}

// a handle as Volt holds it (in a list)
type voltH struct {
	h    uintptr
	lent bool
}

func str(p unsafe.Pointer, n uintptr) string {
	if n == 0 {
		return ""
	}
	return string(unsafe.Slice((*byte)(p), n))
}

// Volt's elements, in place: what Go changes, Volt sees
func sl[T any](p unsafe.Pointer, n uintptr) []T {
	if n == 0 {
		return nil
	}
	return unsafe.Slice((*T)(p), n)
}

func strs(p unsafe.Pointer, n uintptr) []string {
	out := make([]string, n)
	for i, x := range sl[voltStr](p, n) {
		out[i] = str(x.p, x.n)
	}
	return out
}

// Volt's elements as the call's (f converts each); back puts the call's changes back
func each[T, U any](p unsafe.Pointer, n uintptr, f func(T) U) []U {
	out := make([]U, n)
	for i, x := range sl[T](p, n) {
		out[i] = f(x)
	}
	return out
}

func back[T, U any](p unsafe.Pointer, s []U, f func(U) T) {
	dst := sl[T](p, uintptr(len(s)))
	for i := range dst {
		dst[i] = f(s[i])
	}
}

// an array type's elements: exactly n of them
func count[T any](s []T, n int) []T {
	if len(s) != n {
		panic(fmt.Sprintf("Go takes %d elements here, and Volt gave %d", n, len(s)))
	}
	return s
}

func ptrTo[T any](x T) *T {
	return &x
}

// the value a handle holds (a *T: Go's collector keeps it while Volt holds the handle)
func hptr[T any](h uintptr) *T {
	return cgo.Handle(h).Value().(*T)
}

func newH[T any](p *T) uintptr {
	if p == nil {
		return 0
	}
	return uintptr(cgo.NewHandle(p))
}

// a handle to a copy of x
func hOf[T any](x T) uintptr {
	return newH(&x)
}

// Volt's handles in a list, as values and as pointers; hBack puts the call's changes in each
func hvOf[T any](x voltH) T {
	return *hptr[T](x.h)
}

func hpOf[T any](x voltH) *T {
	return hptr[T](x.h)
}

func hBack[T any](p unsafe.Pointer, s []T) {
	for i, x := range sl[voltH](p, uintptr(len(s))) {
		*hptr[T](x.h) = s[i]
	}
}

// a Go slice's elements as Volt holds them (f converts each), for a Volt function the shim calls;
// unmap puts its changes back
func mapped[T, U any](s []T, f func(T) U) []U {
	out := make([]U, len(s))
	for i, x := range s {
		out[i] = f(x)
	}
	return out
}

func unmap[T, U any](s []T, v []U, f func(U) T) {
	for i, x := range v {
		s[i] = f(x)
	}
}

// the handles a Volt function was lent: the values (copies) back, then the handles deleted
func hBackDrop[T any](s []T, v []voltH) {
	for i, x := range v {
		s[i] = *hptr[T](x.h)
	}
	hDrop(v)
}

func hDrop(v []voltH) {
	for _, x := range v {
		cgo.Handle(x.h).Delete()
	}
}

// Go's text as Volt's str[..] (copies in C memory: Go's may not be kept there), and freed
func cStrs(s []string) unsafe.Pointer {
	if len(s) == 0 {
		return nil
	}
	p := C.malloc(C.size_t(uintptr(len(s)) * unsafe.Sizeof(voltStr{})))
	out := unsafe.Slice((*voltStr)(p), len(s))
	for i, x := range s {
		out[i] = voltStr{nil, uintptr(len(x))}
		if len(x) > 0 {
			out[i].p = C.CBytes([]byte(x))
		}
	}
	return p
}

func freeStrs(p unsafe.Pointer, n int) {
	if p == nil {
		return
	}
	for _, x := range unsafe.Slice((*voltStr)(p), n) {
		C.free(x.p)
	}
	C.free(p)
}

// the value of a handle Volt gave up (a Volt function's result), the handle deleted
func takeH[T any](h uintptr) T {
	v := *hptr[T](h)
	cgo.Handle(h).Delete()
	return v
}

func takeP[T any](h uintptr) *T {
	v := hptr[T](h)
	cgo.Handle(h).Delete()
	return v
}

// a copy of the value a handle holds, in a handle of its own (Volt's copy: Go's assignment)
func hcopy(h uintptr) uintptr {
	v := reflect.ValueOf(cgo.Handle(h).Value()).Elem()
	p := reflect.New(v.Type())
	p.Elem().Set(v)
	return uintptr(cgo.NewHandle(p.Interface()))
}

// a channel a handle holds (as Go made it, whichever way it goes), and as the type a call takes
func chanV(c any) reflect.Value {
	return reflect.ValueOf(c).Elem()
}

func chanAs[C any](h uintptr) C {
	return chanV(cgo.Handle(h).Value()).Convert(reflect.TypeOf((*C)(nil)).Elem()).Interface().(C)
}

func chanSend[T any](c any, v T) {
	chanV(c).Send(reflect.ValueOf(&v).Elem())
}

func chanRecv[T any](c any) (T, bool) {
	var v T
	x, ok := chanV(c).Recv()
	if ok {
		reflect.ValueOf(&v).Elem().Set(x)
	}
	return v, ok
}

func mapGet[M ~map[K]V, K comparable, V any](m M, k K) (V, bool) {
	v, ok := m[k]
	return v, ok
}

func mapHas[M ~map[K]V, K comparable, V any](m M, k K) bool {
	_, ok := m[k]
	return ok
}

func mapKeys[M ~map[K]V, K comparable, V any](m M) []K {
	ks := make([]K, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	return ks
}

func zero[T any]() (z T) {
	return
}

func errNew(s string) error {
	return fmt.Errorf("%s", s)
}

func putStr(v string, o, o_n unsafe.Pointer) {
	*(*uintptr)(o_n) = uintptr(len(v))
	if len(v) == 0 {
		*(*unsafe.Pointer)(o) = nil
		return
	}
	*(*unsafe.Pointer)(o) = C.CBytes([]byte(v))
}

func putSl[T any](v []T, o, o_n unsafe.Pointer) {
	*(*uintptr)(o_n) = uintptr(len(v))
	if len(v) == 0 {
		*(*unsafe.Pointer)(o) = nil
		return
	}
	p := C.malloc(C.size_t(uintptr(len(v)) * unsafe.Sizeof(v[0])))
	copy(unsafe.Slice((*T)(p), len(v)), v)
	*(*unsafe.Pointer)(o) = p
}

func putStrs(v []string, o, o_n unsafe.Pointer) {
	*(*uintptr)(o_n) = uintptr(len(v))
	if len(v) == 0 {
		*(*unsafe.Pointer)(o) = nil
		return
	}
	p := C.malloc(C.size_t(uintptr(len(v)) * unsafe.Sizeof(voltStr{})))
	out := unsafe.Slice((*voltStr)(p), len(v))
	for i, x := range v {
		out[i].n = uintptr(len(x))
		out[i].p = nil
		if len(x) > 0 {
			out[i].p = C.CBytes([]byte(x))
		}
	}
	*(*unsafe.Pointer)(o) = p
}

// each element converted (f), in memory Volt frees
func putEach[T, U any](v []T, o, o_n unsafe.Pointer, f func(T) U) {
	*(*uintptr)(o_n) = uintptr(len(v))
	if len(v) == 0 {
		*(*unsafe.Pointer)(o) = nil
		return
	}
	var u U
	p := C.malloc(C.size_t(uintptr(len(v)) * unsafe.Sizeof(u)))
	dst := unsafe.Slice((*U)(p), len(v))
	for i := range v {
		dst[i] = f(v[i])
	}
	*(*unsafe.Pointer)(o) = p
}

// (T, bool) as one value
type opt[T any] struct {
	v  T
	ok bool
}

func mkopt[T any](v T, ok bool) opt[T] {
	return opt[T]{v, ok}
}

// a Volt function's T? as Go's (T, bool): its value only when there's one
func optV[T any](ok bool, f func() T) (T, bool) {
	if !ok {
		return *new(T), false
	}
	return f(), true
}

// a panic, as its text for Volt (status 2): recovered here, it never unwinds through C
func catch(st *uint8, e, e_n unsafe.Pointer) {
	if r := recover(); r != nil {
		putStr(fmt.Sprint(r), e, e_n)
		*st = 2
	}
}

// a Volt value Go holds (a closure's data, a trait's value): drop (null when Volt only lends it)
// frees it once Go's collector is done with it
type voltEnv struct {
	env, drop unsafe.Pointer
}

func newEnv(env, drop unsafe.Pointer) *voltEnv {
	g := &voltEnv{env, drop}
	if drop != nil {
		runtime.SetFinalizer(g, func(g *voltEnv) { C.volt_drop(g.drop, g.env) })
	}
	return g
}

"#;

#[cfg(test)]
mod tests {
    use super::*;

    fn name(n: &str) -> GT {
        GT::Name(n.into(), Vec::new())
    }

    #[test]
    fn import_go_types() {
        let b = Box::new;
        assert_eq!(parse_gt("int"), Some(name("int")));
        assert_eq!(parse_gt("map[string][]*Point"), Some(GT::Map(b(name("string")), b(GT::Slice(b(GT::Ptr(b(name("Point")))))))));
        assert_eq!(parse_gt("func(int,...string)(bool,error)"), Some(GT::Func(vec![name("int"), name("string")], vec![name("bool"), name("error")], true)));
        assert_eq!(parse_gt("func()()"), Some(GT::Func(Vec::new(), Vec::new(), false)));
        assert_eq!(parse_gt("<-chan p1.Duration"), Some(GT::Chan(Dir::Recv, b(name("p1.Duration")))));
        assert_eq!(parse_gt("chan<- int"), Some(GT::Chan(Dir::Send, b(name("int")))));
        assert_eq!(parse_gt("Stack[map[int]bool,T]"), Some(GT::Name("Stack".into(), vec![GT::Map(b(name("int")), b(name("bool"))), name("T")])));
        assert_eq!(parse_gt("[3]float64"), Some(GT::Array(3, b(name("float64")))));
        assert_eq!(parse_gt("map[string]struct{}"), Some(GT::Map(b(name("string")), b(GT::Empty))));
        assert_eq!(parse_gt("[]@2"), Some(GT::Slice(b(GT::Anon(2)))));
        assert_eq!(parse_gt("map[int"), None);
        assert_eq!(parse_gt("int)"), None);
    }

    #[test]
    fn import_go_read() {
        let desc = [
            "package\tgeom",
            "import\tp1\ttime\ttime",
            "struct\tPoint\nfield\tX\ttrue\tfloat64\nend",
            "func\tNorm\tPoint\tval\nsrc\tfunc (Point).Norm() float64\nresult\t\tfloat64\nend",
            "enum\tColor\nvalue\tRed\t0\nvalue\tGreen\t1\nend",
            "named\tCelsius\tfloat64\nend",
            "named\tInventory\tmap[string]int\nend",
            "named\tOp\tfunc(int,int)(int)\nend",
            "named\tp1.Duration\tint64\nend",
            "interface\tFigure\topen",
            "func\tArea\tFigure\tiface\nresult\t\tfloat64\nend",
            "func\tName\tFigure\tiface\nresult\t\tstring\nend",
            "interface\tSealed\tsealed",
            "struct\tStack\ntparam\tT\nfield\titems\tfalse\t[]T\nend",
            "func\tPush\tStack\tptr\nparam\tx\tT\nend",
            "func\tParse\t-\tnone\nparam\ts\tstring\nresult\t\tint\nresult\t\terror\nend",
            "func\tFind\t-\tnone\nparam\t_\t[]int\nparam\tx\tint\nresult\t\tint\nresult\t\tbool\nend",
            "func\tMinMax\t-\tnone\nparam\txs\t[]int\nresult\tlo\tint\nresult\thi\tint\nend",
            "func\tDivmod\t-\tnone\nparam\ta\tint\nparam\tb\tint\nresult\t\tint\nresult\t\tint\nresult\t\terror\nend",
            "func\tTotal\t-\tnone\nvariadic\nparam\txs\t[]int\nresult\t\tint\nend",
            "func\tMax\t-\tnone\ntparam\tT\nvariadic\nparam\txs\t[]T\nresult\t\tT\nend",
            "func\tKeys\t-\tnone\ntparam\tK\ntparam\tV\nparam\tm\tmap[K]V\nresult\t\t[]K\nend",
            "func\tChunk\t-\tnone\ntparam\tT\nparam\txs\t[]T\nresult\t\t[][]T\nend",
            "func\tPtrOf\t-\tnone\ntparam\tT\nparam\tx\tT\nresult\t\t*T\nend",
            "func\tTwice\t-\tnone\ntparam\tT\nparam\txs\t[]T\nresult\t\t[2][]T\nend",
            "func\tRange\t-\tnone\nparam\tn\tint\nresult\t\t<-chan int\nend",
            "func\tFill\t-\tnone\nparam\tc\tchan<- int\nparam\tf\tOp\nend",
            "func\tSpread\t-\tnone\nparam\tf\tfunc(int)(int,string,error)\nresult\t\tstring\nend",
            "func\tWait\t-\tnone\nparam\td\tp1.Duration\nparam\tp\t*int\nresult\t\t*int\nend",
            "func\tTell\t-\tnone\nparam\tf\tFigure\nresult\t\tFigure\nend",
            "func\tUnique\t-\tnone\nresult\t\tmap[string]struct{}\nend",
            "const\tBoiling\tCelsius\t100.0",
            "const\tBig\tint\tbig",
            "var\tCounter\tint",
            "impl\tPoint\tFigure\tval",
            "other\tZ\ta constraint (in Go, only a type parameter has one)",
        ]
        .join("\n");
        let (m, go) = read(&desc, "geom", "geom", "volt_x", &["Max\tisize".to_string(), "Stack\tf64".to_string(), "Chunk\tisize".to_string()]);
        let f = |n: &str| m.fns.iter().map(|x| &x.1).find(|s| s.name == n).unwrap_or_else(|| panic!("no {n}"));
        let named = |n: &str| Ty::Named(n.into());
        assert_eq!(f("Parse").ret, Some(Ty::Res(Box::new(Ty::Prim("isize")))));
        assert_eq!(f("Find").ret, Some(Ty::Opt(Box::new(Ty::Prim("isize")))));
        assert_eq!(f("Find").params[0].0, "p0");
        // several results: a tuple, named as Go names them; with an error, a result of one
        assert_eq!(f("MinMax").ret, Some(Ty::Tuple(vec![("lo".into(), Ty::Prim("isize")), ("hi".into(), Ty::Prim("isize"))])));
        assert_eq!(f("Divmod").ret, Some(Ty::Res(Box::new(Ty::Tuple(vec![(String::new(), Ty::Prim("isize")), (String::new(), Ty::Prim("isize"))])))));
        // a variadic takes a slice (the call spreads it)
        assert_eq!(f("Total").params[0].1, Some(Ty::Vec(Box::new(Ty::Prim("isize")))));
        assert!(go.variadic.contains(".Total") && go.variadic.contains(".Max__isize"));
        // generics: the declaration, and the instance a line asks for
        assert_eq!(f("Max").generics, ["T"]);
        assert_eq!(f("Max__isize").call.as_deref(), Some("Max[int]"));
        assert_eq!(f("Max__isize").ret, Some(Ty::Prim("isize")));
        assert!(m.types.iter().any(|t| t.name == "Stack" && t.generic));
        let st = m.types.iter().find(|t| t.name == "Stack__f64").expect("Stack<f64>");
        assert_eq!(st.rust_name.as_deref(), Some("m.Stack[float64]"));
        assert_eq!(m.methods["Stack__f64"].iter().find(|s| s.name == "Push").unwrap().params[0].1, Some(Ty::Prim("f64")));
        // channels: one handle type whichever way they go (chan<isize>, as a program names it); a
        // parameter's says its way
        assert_eq!(f("Range").ret, Some(named("chan__isize")));
        assert_eq!(f("Fill").params[0].1, Some(Ty::Ref(Box::new(named("chan__isize")), true)));
        assert!(m.methods["chan__isize"].iter().any(|s| s.name == "recv" && s.ret == Some(Ty::Opt(Box::new(Ty::Prim("isize"))))));
        // a named func type: a Volt fn, and an alias of it
        assert_eq!(f("Fill").params[1].1, Some(Ty::Fn(vec![Ty::Prim("isize"), Ty::Prim("isize")], Box::new(Ty::Prim("isize")), FnPass::Value, false)));
        // a func type with several results, an error last: go_error!(A, B)
        let spread = Ty::Res(Box::new(Ty::Tuple(vec![(String::new(), Ty::Prim("isize")), (String::new(), Ty::String)])));
        assert_eq!(f("Spread").params[0].1, Some(Ty::Fn(vec![Ty::Prim("isize")], Box::new(spread), FnPass::Value, false)));
        assert!(m.aliases.iter().any(|(_, n, _)| n == "Op"));
        // another package's named number: a struct { value } in its namespace; *int in and out
        assert_eq!(f("Wait").params[0].1, Some(named("Duration")));
        assert_eq!(m.types.iter().find(|t| t.name == "Duration").map(|t| t.module.clone()), Some(vec!["time".to_string()]));
        assert_eq!(f("Wait").params[1].1, Some(Ty::Ref(Box::new(Ty::Prim("isize")), true)));
        assert_eq!(f("Wait").ret, Some(named("ptr__isize")));
        // an interface: a trait, Go's values of it dyn_Figure, and the types with its methods attach it
        assert_eq!(f("Tell").params[0].1, Some(Ty::Dyn("Figure".into(), FnPass::Value)));
        assert_eq!(f("Tell").ret, Some(Ty::Dyn("Figure".into(), FnPass::Value)));
        assert_eq!(m.traits.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(), ["Figure"]);
        assert!(m.impls.contains(&("Point".into(), "Figure".into())) && m.impls.contains(&("dyn_Figure".into(), "Figure".into())));
        assert!(m.methods["Point"].iter().any(|s| s.name == "Norm"));
        // maps and sets: handles with their methods
        assert!(m.methods["Inventory"].iter().any(|s| s.name == "get" && s.ret == Some(Ty::Opt(Box::new(Ty::Prim("isize"))))));
        assert!(m.methods["set__std_string_std_mem_default_allocator"].iter().any(|s| s.name == "add"));
        // a generic func over a map of its type parameters: map<K, V>
        assert_eq!(f("Keys").params[0].1, Some(Ty::Ref(Box::new(Ty::Inst("map".into(), vec![Ty::Generic("K".into()), Ty::Generic("V".into())])), false)));
        // pointers and slices of slices of them: ptr<T>, slice<std::vec<T>>, an instance's named as voltc names it
        let tv = |t: Ty| Ty::Vec(Box::new(t));
        assert_eq!(f("PtrOf").ret, Some(Ty::Inst("ptr".into(), vec![Ty::Generic("T".into())])));
        assert_eq!(f("Chunk").ret, Some(Ty::Inst("slice".into(), vec![tv(Ty::Generic("T".into()))])));
        // an array of slices of them: array2<std::vec<T>> (the length is in the type's name)
        assert_eq!(f("Twice").ret, Some(Ty::Inst("array2".into(), vec![tv(Ty::Generic("T".into()))])));
        assert!(m.types.iter().any(|t| t.name == "array2" && t.generic));
        assert_eq!(f("Chunk__isize").ret, Some(named("slice__std_vec_isize_std_mem_default_allocator")));
        assert_eq!(m.consts, [(vec![], "Boiling".to_string(), "geom::Celsius".to_string(), "{ value: 100.0 }".to_string())]);
        assert!(m.fns.iter().any(|(_, s)| s.name == "Counter") && m.fns.iter().any(|(_, s)| s.name == "set_Counter"));
        // what's left out: Go's own rules
        assert_eq!(
            m.left_out,
            [
                "Sealed as a trait Volt's types attach (it has unexported methods, so in Go only its own package's types have it): Go's values of it are dyn_Sealed",
                "Big (an untyped constant no Go number can hold)",
                "Z (a constraint (in Go, only a type parameter has one))",
            ]
        );
    }

    #[test]
    fn import_go_rename_main() {
        assert_eq!(rename_main("// a tool\npackage main\n\nfunc main() {}\n"), "// a tool\npackage user\n\nfunc main() {}\n");
        assert_eq!(rename_main("package mainly\n"), "package mainly\n");
    }
}
