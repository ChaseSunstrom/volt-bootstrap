// voltc-bootstrap: the stage0 compiler's command line. It loads the sources and packages (std,
// --pkg, --link), runs the lexer, parser and checker, and hands the generated C to $CC. Its job is
// to build the self-hosted compiler in voltc/, whose main.volt mirrors this file.
mod ast;
mod check;
mod cimport;
mod diag;
mod lexer;
mod parser;
mod sexp;
mod types;

use diag::SourceMap;
use std::path::{Path, PathBuf};
use std::process::{Command, exit};

fn usage() -> ! {
    eprintln!(
        "usage: voltc <command> FILES... [options]\n\
         commands:\n  parse FILE [--dump|--sexp] parse only\n  check FILES            type check\n  \
         emit-c FILES           print the generated C\n  build FILES [-o OUT]   compile to an executable\n  \
         run FILES [-- ARGS]    build and run\n  \
         lib NAME [-o OUT.a]    precompile package NAME's non-generic code into a static library\n  \
         std-dir                print where the std package is\n\
         options:\n  --release              optimize, wrap on overflow instead of trapping\n  \
         --leak-check           debug: exit 102 if runtime allocations were never freed\n  \
         --std DIR | --no-std   where the std package is (default: $VOLT_STD, then next to voltc)\n  \
         --pkg NAME=PATH        a package: PATH's .volt files, wrapped in namespace NAME\n  \
         --cfg [PKG:]KEY[=VAL]  set KEY (to VAL) for @cfg in the program's files, or in package PKG's\n  \
         --lib NAME             check: package NAME alone, as a library (no program files, no main)\n  \
         --link NAME=LIB.a      take package NAME's non-generic code from a library built by voltc lib\n  \
         --cc ARG               pass ARG to the C compiler when linking (a .c file, -lNAME, ...)\n  \
         --message-format F     how errors are printed: human (default), short (one line each) or json\n  \
         --color WHEN           colour errors: auto (default: on a terminal, unless NO_COLOR is set), always, never\n  \
         --error-limit N        show at most N errors (default 20; 0: all of them)"
    );
    exit(2);
}

/// print diagnostics (errors and warnings) the way the command line asked
fn report(cli: &Cli, sm: &SourceMap, diags: &[diag::Diag]) {
    use std::io::IsTerminal;
    let color = match cli.color.as_str() {
        "always" => true,
        "never" => false,
        _ => std::io::stderr().is_terminal() && std::env::var_os("NO_COLOR").is_none() && std::env::var("TERM").map_or(true, |t| t != "dumb"),
    };
    eprint!("{}", sm.report(diags, cli.format, color, cli.error_limit));
}

/// print the diagnostics and stop
fn die(cli: &Cli, sm: &SourceMap, diags: &[diag::Diag]) -> ! {
    report(cli, sm, diags);
    exit(1);
}

/// print a plain error and stop
fn fail(msg: String) -> ! {
    eprintln!("voltc: {msg}");
    exit(1);
}

/// the parsed command line
#[derive(Default)]
struct Cli {
    cmd: String,
    /// the positional arguments: source files (for `lib`, the package name)
    files: Vec<String>,
    out: Option<PathBuf>,
    std_dir: Option<PathBuf>,
    no_std: bool,
    pkgs: Vec<(String, PathBuf)>,
    links: Vec<(String, PathBuf)>,
    cc_args: Vec<String>,
    /// --cfg: the package it's for (None: the program's own files) and KEY or KEY=VALUE
    cfg: Vec<(Option<String>, String)>,
    /// check --lib NAME
    lib: Option<String>,
    release: bool,
    leak_check: bool,
    dump: bool,
    sexp: bool,
    format: diag::Format,
    /// auto, always or never
    color: String,
    /// errors shown (and collected by the checker) before stopping; 0: no limit
    error_limit: usize,
    /// everything after `--`: the arguments for `run`'s program
    prog_args: Vec<String>,
}

/// the command, then files and options in any order; a malformed line prints the usage and exits
fn parse_cli() -> Cli {
    let mut args = std::env::args().skip(1);
    let mut cli = Cli { cmd: args.next().unwrap_or_else(|| usage()), error_limit: 20, ..Default::default() };
    while let Some(a) = args.next() {
        match a.as_str() {
            "--release" => cli.release = true,
            "--leak-check" => cli.leak_check = true,
            "--dump" => cli.dump = true,
            "--sexp" => cli.sexp = true,
            "--no-std" => cli.no_std = true,
            "-o" => cli.out = Some(args.next().unwrap_or_else(|| usage()).into()),
            "--std" => cli.std_dir = Some(args.next().unwrap_or_else(|| usage()).into()),
            "--cc" => cli.cc_args.push(args.next().unwrap_or_else(|| usage())),
            "--lib" => cli.lib = Some(args.next().unwrap_or_else(|| usage())),
            "--cfg" => {
                let spec = args.next().unwrap_or_else(|| usage());
                // PKG: scopes it, when the part before ':' is a name (a value may hold ':' too)
                cli.cfg.push(match spec.split_once(':') {
                    Some((p, rest)) if !p.contains('=') && !p.is_empty() => (Some(p.to_string()), rest.to_string()),
                    _ => (None, spec),
                });
            }
            "--message-format" => {
                cli.format = match args.next().as_deref() {
                    Some("human") => diag::Format::Human,
                    Some("short") => diag::Format::Short,
                    Some("json") => diag::Format::Json,
                    _ => fail("--message-format takes human, short or json".into()),
                }
            }
            "--error-limit" => {
                let n = args.next().unwrap_or_else(|| usage());
                cli.error_limit = n.parse().unwrap_or_else(|_| fail("--error-limit takes a number (0: no limit)".into()));
            }
            "--color" => {
                cli.color = args.next().unwrap_or_default();
                if !["auto", "always", "never"].contains(&cli.color.as_str()) {
                    fail("--color takes auto, always or never".into());
                }
            }
            "--pkg" | "--link" => {
                let spec = args.next().unwrap_or_else(|| usage());
                let Some((name, path)) = spec.split_once('=') else { fail(format!("{a} wants NAME=PATH, got '{spec}'")) };
                let list = if a == "--pkg" { &mut cli.pkgs } else { &mut cli.links };
                list.push((name.to_string(), path.into()));
            }
            "--" => cli.prog_args.extend(args.by_ref()),
            f if f.starts_with('-') => fail(format!("unknown option '{f}'")),
            f => cli.files.push(f.to_string()),
        }
    }
    if cli.files.is_empty() && cli.cmd != "std-dir" && !(cli.cmd == "check" && cli.lib.is_some()) {
        usage();
    }
    cli
}

/// every .volt file under `path` (sorted, so builds are reproducible), or `path` itself
fn volt_files(path: &Path) -> Vec<PathBuf> {
    if path.is_file() {
        return vec![path.to_path_buf()];
    }
    let mut out = Vec::new();
    let mut dirs = vec![path.to_path_buf()];
    while let Some(d) = dirs.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else { fail(format!("can't read package directory {}", d.display())) };
        for e in entries.flatten() {
            let p = e.path();
            if p.is_dir() {
                dirs.push(p);
            } else if p.extension().is_some_and(|x| x == "volt") {
                out.push(p);
            }
        }
    }
    out.sort();
    out
}

/// the std package: --std, $VOLT_STD, or a std/ directory next to (or above) voltc: installed
/// (prefix/lib/volt/std), in cargo's target/<profile>/, or in bolt's voltc/target/<profile>/
fn find_std(cli: &Cli) -> Option<PathBuf> {
    if cli.no_std {
        return None;
    }
    if let Some(d) = &cli.std_dir {
        return Some(d.clone());
    }
    if let Some(d) = std::env::var_os("VOLT_STD") {
        let d = PathBuf::from(d);
        if !d.is_dir() {
            fail(format!("$VOLT_STD is {}, which isn't a directory: point it at std, or unset it", d.display()));
        }
        return Some(d);
    }
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    for cand in [dir.join("std"), dir.join("../std"), dir.join("../../std"), dir.join("../lib/volt/std"), dir.join("../../../std")] {
        if cand.is_dir() {
            // without the ../ steps: file names in messages and panics read plainly
            return Some(cand.canonicalize().unwrap_or(cand));
        }
    }
    fail("can't find the std package; pass --std DIR (or --no-std)".into())
}

/// parse the program, std and packages, then check; returns the C program
fn compile(cli: &Cli) -> String {
    let mut sm = SourceMap::default();
    let mut units: Vec<(u32, Option<String>)> = Vec::new();
    let mut add = |sm: &mut SourceMap, path: &Path, pkg: Option<&str>| {
        let text = std::fs::read_to_string(path).unwrap_or_else(|e| fail(format!("can't read {}: {e}", path.display())));
        units.push((sm.add(&path.to_string_lossy(), text), pkg.map(String::from)));
    };
    let mut pkgs: Vec<(String, PathBuf)> = find_std(cli).map(|d| ("std".to_string(), d)).into_iter().collect();
    for (name, dir) in &cli.pkgs {
        // the name becomes a namespace and part of C symbol names
        let ident = name.chars().next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_') && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
        if !ident {
            fail(format!("package name '{name}' has to be a Volt name (letters, digits, _): it becomes a namespace"));
        }
        if pkgs.iter().any(|p| &p.0 == name) {
            let hint = if name == "std" { " (pick another std with --std DIR)" } else { "" };
            fail(format!("package '{name}' is given twice{hint}"));
        }
        pkgs.push((name.clone(), dir.clone()));
    }
    // a package's guard symbol names its exact sources and build flavor: linking a library built
    // from other sources (or debug vs release) fails at link time instead of misbehaving
    let mut guards = Vec::new();
    for (name, dir) in &pkgs {
        let mut all = String::new();
        for f in volt_files(dir) {
            add(&mut sm, &f, Some(name));
            all.push_str(&sm.files.last().unwrap().1);
            all.push('\0');
        }
        // and its --cfg settings: a library built with other features doesn't link either
        let mut cfg: Vec<&str> = cli.cfg.iter().filter(|c| c.0.as_ref() == Some(name)).map(|c| c.1.as_str()).collect();
        cfg.sort();
        for c in cfg {
            all.push_str(c);
            all.push('\0');
        }
        let flavor = if cli.release { 'r' } else { 'd' };
        guards.push((name.clone(), format!("volt_pkg_{name}_{:08x}_{flavor}", check::fnv32(&all))));
    }
    // `lib NAME` (and `check --lib NAME`) builds package NAME alone: there are no program files
    let lib = if cli.cmd == "lib" { Some(cli.files[0].clone()) } else { cli.lib.clone() };
    if let Some(l) = &lib {
        if !pkgs.iter().any(|p| &p.0 == l) {
            fail(format!("no package '{l}' to build (std, or one given with --pkg)"));
        }
    } else {
        for f in &cli.files {
            add(&mut sm, Path::new(f), None);
        }
    }
    // a linked package's sources are still read: its generic code and declarations come from them
    for (name, _) in &cli.links {
        if !pkgs.iter().any(|p| &p.0 == name) {
            fail(format!("--link {name}=...: the package's sources are needed too (std, or --pkg {name}=DIR)"));
        }
    }
    // parse all units together (generic names are shared between files)
    let srcs: Vec<(u32, String)> = units.iter().map(|(id, _)| (*id, sm.files[*id as usize].1.clone())).collect();
    let refs: Vec<(u32, &str)> = srcs.iter().map(|(i, s)| (*i, s.as_str())).collect();
    let parsed = parser::parse_files(&refs).unwrap_or_else(|ds| die(cli, &sm, &ds));
    // a package's files live in namespace <package>
    let files = parsed
        .into_iter()
        .zip(&units)
        .map(|(items, (id, pkg))| match pkg {
            Some(p) => vec![ast::Item {
                kind: ast::ItemKind::Namespace(vec![p.clone()], items),
                span: diag::Span { file: *id, lo: 0, hi: 0 },
                attrs: Vec::new(),
                vis: ast::Vis::Public,
                generics: Vec::new(),
            }],
            None => items,
        })
        .collect();
    let pkg_files = units.iter().filter_map(|(id, p)| Some((*id, p.clone()?))).collect();
    let opts = check::Opts {
        release: cli.release,
        leak_check: cli.leak_check,
        runtime: lib.is_none(), // the runtime lives in the program's own C unit, never in a library
        pkg_files,
        lib,
        linked: cli.links.iter().map(|l| l.0.clone()).collect(),
        guards,
        cfg: cli.cfg.clone(),
        pp_flags: cimport::preprocessor_flags(&cli.cc_args),
    };
    let (sm, diags, c) = check::compile(sm, files, opts);
    match c {
        Some(c) => {
            report(cli, &sm, &diags); // warnings
            c
        }
        None => die(cli, &sm, &diags),
    }
}

/// compile C (written next to `out` as a .c file): to an executable (linked with `libs` and `extra`), or
/// with `object` to a .o
fn cc(c_src: &str, out: &PathBuf, release: bool, libs: &[(String, PathBuf)], extra: &[String], object: bool) {
    let c_path = out.with_extension("c");
    let target = out.display().to_string();
    std::fs::write(&c_path, c_src).unwrap_or_else(|e| fail(format!("can't write {}: {e}", c_path.display())));
    let (mut cmd, cc) = cimport::c_compiler();
    // imported headers' prototypes are C's own: a Volt void*/cstr for their const void*/char* is fine
    cmd.args(["-std=gnu11", "-w", "-Wno-error=incompatible-pointer-types", "-Wno-error=int-conversion", "-o"]).arg(out).arg(&c_path);
    if object {
        // a library's C still includes the headers its code imports: -I, -D, -U from --cc
        cmd.arg("-c").args(cimport::preprocessor_flags(extra));
    } else {
        cmd.args(extra).args(libs.iter().map(|l| &l.1)).args(["-lm", "-lpthread"]); // the runtime has threads (libpthread before glibc 2.34)
    }
    if release {
        cmd.args(["-O2", "-fwrapv"]);
    } else {
        cmd.args(["-O0", "-g"]);
    }
    let out = cmd.output().unwrap_or_else(|e| fail(format!("can't run {cc}: {e}")));
    // a volt_pkg_ guard symbol that doesn't resolve means a --link library doesn't match its package
    if !out.status.success() {
        let msg = String::from_utf8_lossy(&out.stderr);
        if let Some(i) = msg.find("volt_pkg_") {
            let pkg = msg[i + 9..].split('_').next().unwrap_or("?");
            fail(format!("the library linked for package '{pkg}' was built from other sources or in the other mode (debug/release); rebuild it with voltc lib {pkg}"));
        }
        eprint!("{msg}");
        // the linker's errors aren't the generated C's: a library it can't find, or an undefined name
        if msg.contains("cannot find -l") || msg.contains("unable to find library") {
            fail(format!("linking {target} failed: a library above wasn't found (install it, or pass --cc -L/DIR where it is)"));
        }
        if msg.contains("ld returned") || msg.contains("linker command failed") {
            fail(format!("linking {target} failed (the linker's errors are above): a C library or extern function may be missing; if not, this is a voltc bug"));
        }
        fail(format!("the C compiler failed on {} (this is a voltc bug)", c_path.display()));
    }
}

/// a new private build directory. create_dir fails on an existing path, so a directory another
/// user made first (to swap the program before it runs) is never used
fn fresh_dir() -> PathBuf {
    for n in 0.. {
        let d = std::env::temp_dir().join(format!("voltc-{}-{n}", std::process::id()));
        match std::fs::create_dir(&d) {
            Ok(()) => return d,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists && n < 100 => continue,
            Err(e) => fail(format!("can't make a build directory {}: {e}", d.display())),
        }
    }
    unreachable!()
}

fn main() {
    let cli = parse_cli();
    match cli.cmd.as_str() {
        "parse" => {
            let file = &cli.files[0];
            let text = std::fs::read_to_string(file).unwrap_or_else(|e| fail(format!("can't read {file}: {e}")));
            let mut sm = SourceMap::default();
            let id = sm.add(file, text);
            let src = sm.files[id as usize].1.clone();
            let parsed = parser::parse_files(&[(id, &src)]);
            if cli.sexp {
                // the canonical form the self-hosted parser is checked against
                let mut w = sexp::W { out: String::new() };
                match &parsed {
                    Ok(files) => w.items(&files[0]),
                    Err(ds) => {
                        for d in ds {
                            w.out.push_str(&format!("(error @{}:{} \"{}\")\n", d.span.lo, d.span.hi, d.msg.replace('"', "'")));
                        }
                    }
                }
                print!("{}", w.out);
                exit(if parsed.is_ok() { 0 } else { 1 });
            }
            let files = parsed.unwrap_or_else(|ds| die(&cli, &sm, &ds));
            if cli.dump {
                println!("{:#?}", files[0]);
            } else {
                println!("ok: {} items", files[0].len());
            }
        }
        "std-dir" => match find_std(&cli) {
            Some(d) => println!("{}", d.canonicalize().unwrap_or(d).display()),
            None => exit(1),
        },
        "check" => {
            compile(&cli);
        }
        "emit-c" => print!("{}", compile(&cli)),
        "build" => {
            let c = compile(&cli);
            let out = cli.out.clone().unwrap_or_else(|| PathBuf::from(&cli.files[0]).with_extension(""));
            cc(&c, &out, cli.release, &cli.links, &cli.cc_args, false);
        }
        "lib" => {
            let c = compile(&cli);
            let out = cli.out.clone().unwrap_or_else(|| PathBuf::from(format!("lib{}.a", cli.files[0])));
            let dir = fresh_dir();
            let obj = dir.join(format!("{}.o", cli.files[0]));
            cc(&c, &obj, cli.release, &[], &cli.cc_args, true);
            let _ = std::fs::remove_file(&out); // ar would add to an old archive
            let status = Command::new("ar").arg("rcs").arg(&out).arg(&obj).status();
            let _ = std::fs::remove_dir_all(&dir);
            if !status.is_ok_and(|s| s.success()) {
                fail(format!("ar couldn't write {}", out.display()));
            }
        }
        "run" => {
            let c = compile(&cli);
            let dir = fresh_dir();
            let exe = dir.join("prog");
            cc(&c, &exe, cli.release, &cli.links, &cli.cc_args, false);
            let status = Command::new(&exe).args(&cli.prog_args).status().unwrap();
            let _ = std::fs::remove_dir_all(&dir);
            exit(status.code().unwrap_or(1));
        }
        _ => usage(),
    }
}
