// use { "geom.go" } as NAME; — an ordinary Go package, called from Volt. bolt asks Go itself what
// the package exports (DESCRIBE: go/types, run with `go run`), writes a cgo shim (a package that
// imports it and //exports a C function for each) and the Volt side (glue.rs). A program has one Go
// runtime, so the shims are linked as one: each import's flags name its shim (`go-package DIR`),
// and voltc has `bolt import go-link` build them all with go build -buildmode=c-archive. Nothing in
// the Go code changes.
//
//   int, uint -> isize, usize; int8..uint64, float32, float64, bool, byte, rune -> the same sizes
//   string -> str in, std::string out; []T -> T[..] in (the call sees Volt's memory), std::vec<T> out
//   (T, error) -> go_error!T (the error's text); error -> go_error!void; (T, bool) -> T?
//   a struct whose fields are all exported numbers, bools, enums or such structs -> a Volt struct,
//   by value; any other struct -> an owned handle (a runtime/cgo.Handle: Go's collector keeps the
//   value while Volt holds it); *T -> T& in, a handle to that same value out
//   type T int with constants of type T -> a Volt enum with the same values
//   exported constants of numbers, bools and strings -> vals
use super::glue::{Gen, Kind, Lang, Model, Recv, ShimOut, ShimParam, Sig, Ty, TypeDef, TypeInfo};
use super::{arg_path, fresh, save, stamp, Made, Req};
use std::collections::BTreeSet;
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
    let st = stamp(&files, &format!("go {} {} release={}", r.alias, dir.display(), r.release));
    if fresh(r, &st) {
        return Ok(());
    }

    let go = std::env::var("GO").unwrap_or_else(|_| "go".into());
    let desc = describe(r, &go, &dir)?;
    let (model, pkg) = read(&desc);

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

    let lang = Go { path, pkg: shim_pkg };
    let (mut shim, volt) = Gen::new(&model, &r.alias, &lang).write("the package");
    // nothing of the package is called (m.X): imported for its init alone
    let uses = shim.lines().skip(1).any(|l| l.match_indices("m.").any(|(i, _)| i == 0 || !(l.as_bytes()[i - 1].is_ascii_alphanumeric() || l.as_bytes()[i - 1] == b'_')));
    if !uses {
        shim = shim.replacen("\tm \"", "\t_ \"", 1);
    }
    crate::build::write_if_changed(&shim_dir.join("shim.go"), &shim)?;
    // built now, so an error in the Go code shows at the use line; go-link's build reuses the work
    build(&go, &shim_dir, &["build", "."], &dir)?;
    save(r, &Made { volt, flags: vec![format!("go-package {}", out.join("shim").display())], deps: files }, &st)
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

/// a Go program printing a package's exported API, a declaration a line (tab-separated):
///   package NAME
///   func NAME RECV_TYPE|- none|val|ptr, then param NAME TYPE, result TYPE, variadic; end
///   struct NAME, then field NAME exported TYPE; end (its methods follow, as funcs)
///   enum NAME, then value NAME N (in order); end
///   const NAME TYPE LITERAL
///   other NAME WHY (what Volt can't use)
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
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

var pkg *types.Package

func ts(t types.Type) string {
	return types.TypeString(t, func(p *types.Package) string {
		if p == pkg {
			return ""
		}
		return p.Path()
	})
}

func sig(name, recv string, s *types.Signature) {
	if s.TypeParams().Len() > 0 {
		fmt.Printf("other\t%s\tit's generic\n", name)
		return
	}
	fmt.Printf("func\t%s\t%s\n", name, recv)
	if s.Variadic() {
		fmt.Println("variadic")
	}
	for i := 0; i < s.Params().Len(); i++ {
		p := s.Params().At(i)
		fmt.Printf("param\t%s\t%s\n", p.Name(), ts(p.Type()))
	}
	for i := 0; i < s.Results().Len(); i++ {
		fmt.Printf("result\t%s\n", ts(s.Results().At(i).Type()))
	}
	fmt.Println("end")
}

func konst(c *types.Const) {
	b, ok := c.Type().(*types.Basic)
	if !ok {
		fmt.Printf("other\t%s\ta constant of type %s\n", c.Name(), ts(c.Type()))
		return
	}
	v := c.Val()
	t := b.Name()
	switch b.Kind() {
	case types.UntypedInt:
		t = "int"
	case types.UntypedRune:
		t = "int32"
	case types.UntypedFloat:
		t = "float64"
	case types.UntypedBool:
		t = "bool"
	case types.UntypedString:
		t = "string"
	}
	switch {
	case b.Info()&types.IsBoolean != 0:
		fmt.Printf("const\t%s\t%s\t%v\n", c.Name(), t, constant.BoolVal(v))
	case b.Info()&types.IsString != 0:
		fmt.Printf("const\t%s\t%s\t%s\n", c.Name(), t, strconv.Quote(constant.StringVal(v)))
	case b.Info()&types.IsInteger != 0:
		fmt.Printf("const\t%s\t%s\t%s\n", c.Name(), t, v.ExactString())
	case b.Info()&types.IsFloat != 0:
		f, _ := constant.Float64Val(v)
		s := strconv.FormatFloat(f, 'f', -1, 64)
		if !strings.Contains(s, ".") {
			s += ".0"
		}
		fmt.Printf("const\t%s\t%s\t%s\n", c.Name(), t, s)
	default:
		fmt.Printf("other\t%s\ta %s constant\n", c.Name(), t)
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
		f, err := parser.ParseFile(fset, filepath.Join(dir, n), nil, 0)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		files = append(files, f)
	}
	// a package that doesn't check (an import go can't find) still says what it can
	conf := types.Config{Importer: importer.ForCompiler(fset, "source", nil), FakeImportC: true, Error: func(error) {}}
	pkg, _ = conf.Check(bp.Name, fset, files, nil)
	fmt.Printf("package\t%s\n", bp.Name)
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
			sig(n, "-\tnone", o.Type().(*types.Signature))
		case *types.Const:
			if nt, ok := o.Type().(*types.Named); ok && enums[nt.Obj()] != nil {
				continue
			}
			konst(o)
		case *types.Var:
			fmt.Printf("other\t%s\ta package variable\n", n)
		case *types.TypeName:
			nt, ok := o.Type().(*types.Named)
			if !ok || o.IsAlias() {
				fmt.Printf("other\t%s\ta type alias\n", n)
				continue
			}
			if nt.TypeParams().Len() > 0 {
				fmt.Printf("other\t%s\tit's generic\n", n)
				continue
			}
			switch u := nt.Underlying().(type) {
			case *types.Struct:
				fmt.Printf("struct\t%s\n", n)
				for i := 0; i < u.NumFields(); i++ {
					f := u.Field(i)
					fmt.Printf("field\t%s\t%v\t%s\n", f.Name(), f.Exported() && !f.Embedded(), ts(f.Type()))
				}
				fmt.Println("end")
			case *types.Basic:
				cs := enums[o]
				if cs == nil {
					fmt.Printf("other\t%s\ta named %s\n", n, u.Name())
					continue
				}
				sort.Slice(cs, func(i, j int) bool { return cs[i].Pos() < cs[j].Pos() })
				fmt.Printf("enum\t%s\n", n)
				for _, c := range cs {
					if v, exact := constant.Int64Val(c.Val()); exact {
						fmt.Printf("value\t%s\t%d\n", c.Name(), v)
					}
				}
				fmt.Println("end")
			default:
				kind := map[string]string{"*types.Interface": "an interface", "*types.Signature": "a func type", "*types.Map": "a map type", "*types.Slice": "a slice type", "*types.Array": "an array type", "*types.Chan": "a channel type", "*types.Pointer": "a pointer type"}[fmt.Sprintf("%T", u)]
				if kind == "" {
					kind = "a type Volt can't hold"
				}
				fmt.Printf("other\t%s\t%s\n", n, kind)
				continue
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
				sig(m.Name(), n+"\t"+recv, s)
			}
		}
	}
}
"#;

/// a Go type as the glue maps it (None: one Volt can't name); names: the package's structs and enums
fn go_ty(s: &str, names: &BTreeSet<String>) -> Option<Ty> {
    Some(match s {
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
        _ => {
            if let Some(e) = s.strip_prefix("[]") {
                Ty::Slice(Box::new(go_ty(e, names)?), true)
            } else if let Some(e) = s.strip_prefix('*') {
                if !names.contains(e) {
                    return None;
                }
                Ty::Ref(Box::new(Ty::Named(e.to_string())), true)
            } else if names.contains(s) {
                Ty::Named(s.to_string())
            } else {
                return None;
            }
        }
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

/// the Volt type of a constant of Go type t
fn const_ty(t: &str) -> Option<&'static str> {
    match go_ty(t, &BTreeSet::new())? {
        Ty::Prim(p) => Some(p),
        Ty::Str => Some("str"),
        _ => None,
    }
}

/// DESCRIBE's output as the glue's model, and the package's name
fn read(desc: &str) -> (Model, String) {
    let mut m = Model::default();
    let mut pkg = String::new();
    let rows: Vec<Vec<&str>> = desc.lines().map(|l| l.split('\t').collect()).collect();
    let names: BTreeSet<String> = rows.iter().filter(|f| f.len() > 1 && (f[0] == "struct" || f[0] == "enum")).map(|f| f[1].to_string()).collect();
    let mut i = 0;
    while i < rows.len() {
        let f = &rows[i];
        i += 1;
        let field = |k: usize| f.get(k).copied().unwrap_or("");
        match field(0) {
            "package" => pkg = field(1).to_string(),
            "struct" => {
                let mut fields = Vec::new();
                while i < rows.len() && rows[i][0] != "end" {
                    let r = &rows[i];
                    if r.len() == 4 {
                        fields.push((r[1].to_string(), r[2] == "true", go_ty(r[3], &names)));
                    }
                    i += 1;
                }
                i += 1;
                m.types.push(TypeDef { module: vec![], name: field(1).to_string(), generic: false, fields: Some(fields), variants: None, is_enum: false, clone: false, opaque: false, params: Vec::new(), rust_name: None });
            }
            "enum" => {
                let mut vs = Vec::new();
                while i < rows.len() && rows[i][0] != "end" {
                    let r = &rows[i];
                    if let (3, Ok(n)) = (r.len(), r.get(2).unwrap_or(&"").parse::<i128>()) {
                        vs.push((r[1].to_string(), n));
                    }
                    i += 1;
                }
                i += 1;
                m.types.push(TypeDef { module: vec![], name: field(1).to_string(), generic: false, fields: None, variants: Some(vs), is_enum: true, clone: false, opaque: false, params: Vec::new(), rust_name: None });
            }
            "func" => {
                let (name, recv_ty, recv) = (field(1).to_string(), field(2).to_string(), field(3));
                let (mut params, mut results, mut variadic) = (Vec::new(), Vec::new(), false);
                let mut go_params: Vec<String> = Vec::new();
                while i < rows.len() && rows[i][0] != "end" {
                    let r = &rows[i];
                    match (r[0], r.len()) {
                        ("param", 3) => {
                            let n = if r[1].is_empty() || r[1] == "_" { format!("p{}", params.len()) } else { r[1].to_string() };
                            go_params.push(format!("{n} {}", r[2]));
                            params.push((n, go_ty(r[2], &names)));
                        }
                        ("result", 2) => results.push(r[1]),
                        ("variadic", _) => variadic = true,
                        _ => {}
                    }
                    i += 1;
                }
                i += 1;
                // (T, error) is a result, (T, bool) an optional
                let (ret, skip) = match results.as_slice() {
                    [] => (Some(Ty::Unit), None),
                    ["error"] => (Some(Ty::Res(Box::new(Ty::Unit))), None),
                    [t] => (go_ty(t, &names), None),
                    [t, "error"] => (go_ty(t, &names).map(|t| Ty::Res(Box::new(t))), None),
                    [t, "bool"] => (go_ty(t, &names).map(|t| Ty::Opt(Box::new(t))), None),
                    _ => (None, Some("it returns several values")),
                };
                let skip = if variadic { Some("it takes a variable number of arguments") } else { skip };
                let recv = match recv {
                    "val" => Recv::Value,
                    "ptr" => Recv::Mut,
                    _ => Recv::None,
                };
                let rs = match results.as_slice() {
                    [] => String::new(),
                    [t] => format!(" {t}"),
                    ts => format!(" ({})", ts.join(", ")),
                };
                let src = if recv_ty.is_empty() { format!("func {name}({}){rs}", go_params.join(", ")) } else { format!("func ({}) {name}({}){rs}", recv_ty, go_params.join(", ")) };
                let s = Sig { name, recv, params, ret, skip, src, generics: Vec::new(), call: None };
                if recv == Recv::None {
                    m.fns.push((vec![], s));
                } else {
                    m.methods.entry(recv_ty).or_default().push(s);
                }
            }
            "const" if f.len() == 4 => match const_ty(f[2]) {
                // a string Volt writes the same way: no escapes but \" \\ \n \t
                Some("str") if f[3].replace("\\\\", "").replace("\\\"", "").replace("\\n", "").replace("\\t", "").contains('\\') => m.left_out.push(format!("{} (a string Volt can't write)", f[1])),
                Some(t) => m.consts.push((vec![], f[1].to_string(), t.to_string(), f[3].to_string())),
                None => m.left_out.push(format!("{} (a constant of type {})", f[1], f[2])),
            },
            "other" if f.len() >= 3 => m.left_out.push(format!("{} ({})", f[1], f[2])),
            _ => {}
        }
    }
    (m, pkg)
}

struct Go {
    /// the import path of the package the shim calls
    path: String,
    /// the shim's package name
    pkg: String,
}

impl Go {
    fn path(def: &TypeDef) -> String {
        format!("m.{}", def.name)
    }
}

impl Lang for Go {
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
            Ty::Str => {
                p.params.extend([format!("{a} unsafe.Pointer"), format!("{a}_n uintptr")]);
                p.arg = format!("str({a}, {a}_n)");
            }
            Ty::Slice(e, _) => {
                p.params.extend([format!("{a} unsafe.Pointer"), format!("{a}_n uintptr")]);
                p.arg = match &**e {
                    Ty::Prim(x) => format!("sl[{}]({a}, {a}_n)", go_prim(x)),
                    Ty::Str => format!("strs({a}, {a}_n)"),
                    _ => return None,
                };
            }
            Ty::Named(_) | Ty::Ref(..) => {
                let (named, by_ref) = match t {
                    Ty::Ref(x, _) => (&**x, true),
                    x => (x, false),
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
                        p.arg = if by_ref { format!("hv[{gp}]({a})") } else { format!("*hv[{gp}]({a})") };
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
                p.arg = format!("hv[{gp}](this)");
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
            Ty::Str => ShimOut { params: ptrs(&[o, &format!("{o}_n")]), store: format!("putStr($v, {o}, {o}_n)") },
            Ty::Slice(e, _) => match &**e {
                Ty::Prim(x) => ShimOut { params: ptrs(&[o, &format!("{o}_n")]), store: format!("putSl[{}]($v, {o}, {o}_n)", go_prim(x)) },
                Ty::Str => ShimOut { params: ptrs(&[o, &format!("{o}_n")]), store: format!("putStrs($v, {o}, {o}_n)") },
                _ => return None,
            },
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
            Ty::Opt(inner) => {
                let x = self.out(g, inner, o, false)?;
                let mut params = ptrs(&[&format!("{o}_has")]);
                params.extend(x.params);
                let inner = x.store.replace("$v", "$v.v").replace("\n\t", "\n\t\t");
                ShimOut { params, store: format!("if $v.ok {{\n\t\t*(*bool)({o}_has) = true\n\t\t{inner}\n\t}}") }
            }
            _ => return None,
        })
    }

    fn call(&self, _g: &Gen, _module: &[String], s: &Sig, _self_ty: Option<&TypeInfo>, recv: Option<&str>, args: &[String]) -> String {
        let args = args.join(", ");
        let call = match recv {
            Some(r) => format!("{r}.{}({args})", s.name),
            None => format!("m.{}({args})", s.name),
        };
        // (T, bool) as one value
        if matches!(s.ret, Some(Ty::Opt(_))) {
            format!("mkopt({call})")
        } else {
            call
        }
    }

    fn function(&self, sym: &str, params: &[String], pre: &[String], call: &str, post: &[String], store: Option<&str>, res: bool) -> String {
        let mut ps = params.to_vec();
        if res {
            ps.extend(["e unsafe.Pointer".to_string(), "e_n unsafe.Pointer".to_string()]);
        }
        let mut body = String::new();
        for l in pre {
            let _ = writeln!(body, "\t{l}");
        }
        // a *T parameter's changes come back even when the call fails
        let post = |body: &mut String| {
            for l in post {
                let _ = writeln!(body, "\t{l}");
            }
        };
        let fail = "\tif err != nil {\n\t\tputStr(err.Error(), e, e_n)\n\t\treturn false\n\t}\n";
        match (store, res) {
            (Some(st), true) => {
                let _ = writeln!(body, "\tv, err := {call}");
                post(&mut body);
                body.push_str(fail);
                let _ = writeln!(body, "\t{}\n\treturn true", st.replace("$v", "v"));
            }
            (None, true) => {
                let _ = writeln!(body, "\terr := {call}");
                post(&mut body);
                body.push_str(fail);
                body.push_str("\treturn true\n");
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
        format!("//export {sym}\nfunc {sym}({}){} {{\n{body}}}\n\n", ps.join(", "), if res { " bool" } else { "" })
    }

    fn type_glue(&self, g: &Gen, ti: &TypeInfo) -> String {
        let (gp, mg) = (Self::path(&ti.def), Gen::mangle(&ti.def));
        let mut out = String::new();
        match ti.kind {
            Kind::Plain => {
                let (mut fields, mut from, mut to) = (String::new(), String::new(), String::new());
                for (f, _, t) in ti.def.fields.clone().unwrap_or_default() {
                    match t {
                        Some(Ty::Prim(x)) => {
                            let _ = writeln!(fields, "\t{f} {}", go_prim(x));
                            let _ = write!(from, "{f}: v.{f}, ");
                            let _ = write!(to, "{f}: v.{f}, ");
                        }
                        Some(Ty::Named(n)) => {
                            let o = &g.types[&n];
                            let (op, omg) = (Self::path(&o.def), Gen::mangle(&o.def));
                            if o.kind == Kind::Enum {
                                let _ = writeln!(fields, "\t{f} int64");
                                let _ = write!(from, "{f}: {op}(v.{f}), ");
                                let _ = write!(to, "{f}: int64(v.{f}), ");
                            } else {
                                let _ = writeln!(fields, "\t{f} V_{omg}");
                                let _ = write!(from, "{f}: from_{omg}(v.{f}), ");
                                let _ = write!(to, "{f}: to_{omg}(v.{f}), ");
                            }
                        }
                        _ => {}
                    }
                }
                // the Volt struct's layout, field for field
                let _ = write!(out, "type V_{mg} struct {{\n{fields}}}\n\nfunc from_{mg}(v V_{mg}) {gp} {{\n\treturn {gp}{{{from}}}\n}}\n\nfunc to_{mg}(v {gp}) V_{mg} {{\n\treturn V_{mg}{{{to}}}\n}}\n\n");
            }
            Kind::Handle => {
                let drop = g.sym(&[&mg, "drop"]);
                let _ = write!(out, "//export {drop}\nfunc {drop}(h uintptr) {{\n\tcgo.Handle(h).Delete()\n}}\n\n");
            }
            Kind::Enum => {}
        }
        out
    }

    fn prelude(&self, g: &Gen) -> String {
        let free = |what: &str| format!("volt_go_{}_free_{what}", g.alias);
        let mut s = format!(
            "// the glue between a Volt program and package {}, written by bolt import (use go)\npackage {}\n\n// #include <stdlib.h>\nimport \"C\"\n\nimport (\n\t\"runtime/cgo\"\n\t\"unsafe\"\n\n\tm \"{}\"\n)\n\n",
            self.path, self.pkg, self.path
        );
        s.push_str(PRELUDE);
        let _ = write!(s, "//export {}\nfunc {}(p unsafe.Pointer, n uintptr) {{\n\tC.free(p)\n}}\n\n", free("bytes"), free("bytes"));
        for x in &g.vec_elems {
            let f = free(&format!("{x}s"));
            let _ = write!(s, "//export {f}\nfunc {f}(p unsafe.Pointer, n uintptr) {{\n\tC.free(p)\n}}\n\n");
        }
        if g.strs {
            let f = free("strs");
            let _ = write!(s, "//export {f}\nfunc {f}(p unsafe.Pointer, n uintptr) {{\n\tfor _, x := range unsafe.Slice((*voltStr)(p), n) {{\n\t\tC.free(x.p)\n\t}}\n\tC.free(p)\n}}\n\n");
        }
        s
    }
}

/// the shim's helpers: Volt's memory as Go values, Go's values copied to the C heap for Volt, handles
const PRELUDE: &str = r#"// a str as Volt passes it in a list
type voltStr struct {
	p unsafe.Pointer
	n uintptr
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

func hv[T any](h uintptr) *T {
	return cgo.Handle(h).Value().(*T)
}

func newH[T any](p *T) uintptr {
	if p == nil {
		return 0
	}
	return uintptr(cgo.NewHandle(p))
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

// (T, bool) as one value
type opt[T any] struct {
	v  T
	ok bool
}

func mkopt[T any](v T, ok bool) opt[T] {
	return opt[T]{v, ok}
}

"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn import_go_types() {
        let names: BTreeSet<String> = ["Point".to_string()].into();
        let ty = |s: &str| go_ty(s, &names);
        assert_eq!(ty("int"), Some(Ty::Prim("isize")));
        assert_eq!(ty("byte"), Some(Ty::Prim("u8")));
        assert_eq!(ty("rune"), Some(Ty::Prim("i32")));
        assert_eq!(ty("string"), Some(Ty::Str));
        assert_eq!(ty("[]float64"), Some(Ty::Slice(Box::new(Ty::Prim("f64")), true)));
        assert_eq!(ty("[]string"), Some(Ty::Slice(Box::new(Ty::Str), true)));
        assert_eq!(ty("*Point"), Some(Ty::Ref(Box::new(Ty::Named("Point".into())), true)));
        assert_eq!(ty("Point"), Some(Ty::Named("Point".into())));
        assert_eq!(ty("uintptr"), None);
        assert_eq!(ty("map[string]int"), None);
        assert_eq!(ty("time.Duration"), None);
        assert_eq!(ty("*int"), None);
    }

    #[test]
    fn import_go_read() {
        let desc = "package\tgeom\nstruct\tPoint\nfield\tX\ttrue\tfloat64\nfield\tY\ttrue\tfloat64\nend\nfunc\tNorm\tPoint\tval\nresult\tfloat64\nend\nfunc\tScale\tPoint\tptr\nparam\tk\tfloat64\nend\nenum\tColor\nvalue\tRed\t0\nvalue\tGreen\t1\nend\nfunc\tParse\t-\tnone\nparam\ts\tstring\nresult\tint\nresult\terror\nend\nfunc\tFind\t-\tnone\nparam\t_\t[]int\nparam\tx\tint\nresult\tint\nresult\tbool\nend\nfunc\tPair\t-\tnone\nresult\tint\nresult\tint\nend\nfunc\tSum\t-\tnone\nvariadic\nparam\txs\t[]int\nresult\tint\nend\nconst\tLimit\tint\t10\nconst\tName\tstring\t\"geo\"\nconst\tOdd\tstring\t\"a\\x00\"\nother\tApply\ta func type\n";
        let (m, pkg) = read(desc);
        assert_eq!(pkg, "geom");
        assert_eq!(m.types.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(), ["Point", "Color"]);
        assert_eq!(m.types[1].variants, Some(vec![("Red".into(), 0), ("Green".into(), 1)]));
        assert_eq!(m.methods["Point"].iter().map(|s| (s.name.as_str(), s.recv)).collect::<Vec<_>>(), [("Norm", Recv::Value), ("Scale", Recv::Mut)]);
        let f = |n: &str| m.fns.iter().map(|x| &x.1).find(|s| s.name == n).unwrap();
        assert_eq!(f("Parse").ret, Some(Ty::Res(Box::new(Ty::Prim("isize")))));
        assert_eq!(f("Find").ret, Some(Ty::Opt(Box::new(Ty::Prim("isize")))));
        assert_eq!(f("Find").params[0].0, "p0");
        assert_eq!(f("Pair").skip, Some("it returns several values"));
        assert_eq!(f("Sum").skip, Some("it takes a variable number of arguments"));
        assert_eq!(m.consts, [(vec![], "Limit".to_string(), "isize".to_string(), "10".to_string()), (vec![], "Name".to_string(), "str".to_string(), "\"geo\"".to_string())]);
        assert_eq!(m.left_out, ["Odd (a string Volt can't write)", "Apply (a func type)"]);
    }

    #[test]
    fn import_go_rename_main() {
        assert_eq!(rename_main("// a tool\npackage main\n\nfunc main() {}\n"), "// a tool\npackage user\n\nfunc main() {}\n");
        assert_eq!(rename_main("package mainly\n"), "package mainly\n");
    }
}
