// bolt import: the other side of `use LANG { "..." } as NAME;` in Volt source. voltc runs
//
//     bolt import LANG --as NAME --from DIR --out OUT [--release] -- ARGS...
//
// (DIR: the importing file's directory, which relative ARGS start from) and reads what it writes:
// OUT/import.volt, the Volt declarations of namespace NAME, whose bodies call the glue, and
// OUT/import.flags, what a program using them links, one flag a line. The glue is generated from
// the other language's own declarations, so nothing there needs marking up for Volt. Nothing is
// redone while the sources are as they were.
use std::collections::BTreeMap;
use std::fmt::Write;
use std::path::{Path, PathBuf};

mod dotnet;
mod glue;
mod go;
mod java;
mod js;
mod python;
mod rust;
mod swift;
mod zig;

/// one import, as voltc asked for it
pub struct Req {
    pub lang: String,
    pub alias: String,
    pub from: PathBuf,
    pub out: PathBuf,
    pub release: bool,
    pub args: Vec<String>,
}

/// what an import gives voltc
pub struct Made {
    pub volt: String,
    pub flags: Vec<String>,
    /// the files it was made from: what voltc's output is rebuilt for (OUT/import.deps)
    pub deps: Vec<PathBuf>,
}

/// bolt import's entry: the exit code
pub fn main(argv: &[String]) -> i32 {
    match parse(argv).and_then(|r| run(&r)) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("{e}");
            1
        }
    }
}

fn parse(argv: &[String]) -> Result<Req, String> {
    let usage = "usage: bolt import LANG --as NAME --from DIR --out DIR [--release] -- ARGS...";
    let mut it = argv.iter();
    let lang = it.next().ok_or(usage)?.clone();
    let (mut alias, mut from, mut out, mut release, mut args) = (None, None, None, false, Vec::new());
    while let Some(a) = it.next() {
        match a.as_str() {
            "--as" => alias = it.next().cloned(),
            "--from" => from = it.next().map(PathBuf::from),
            "--out" => out = it.next().map(PathBuf::from),
            "--release" => release = true,
            "--" => {
                args.extend(it.by_ref().cloned());
            }
            _ => return Err(usage.into()),
        }
    }
    Ok(Req { lang, alias: alias.ok_or(usage)?, from: from.unwrap_or_else(|| ".".into()), out: out.ok_or(usage)?, release, args })
}

fn run(r: &Req) -> Result<(), String> {
    std::fs::create_dir_all(&r.out).map_err(|e| format!("can't make {}: {e}", r.out.display()))?;
    match r.lang.as_str() {
        "rust" => rust::import(r),
        "zig" => zig::import(r),
        "swift" => swift::import(r),
        "go" => go::import(r),
        "go-link" => go::link(r),
        "java" => java::import(r),
        "dotnet" => dotnet::import(r),
        "python" => python::import(r),
        "js" => js::import(r),
        other => Err(format!("there's no `use {other}`: the languages Volt imports are c (use {{ \"x.h\" }}), cpp, rust, zig, swift, go, java, dotnet, python and js")),
    }
}

/// an argument's path: as it is when absolute, else from the importing file's directory
pub fn arg_path(r: &Req, a: &str) -> PathBuf {
    let p = Path::new(a);
    let p = if p.is_absolute() { p.to_path_buf() } else { r.from.join(p) };
    std::fs::canonicalize(&p).unwrap_or(p)
}

/// what the sources are now (each file's path, size and modification time, plus `extra`): an import
/// is redone when this changes
pub fn stamp(files: &[PathBuf], extra: &str) -> String {
    let mut s = format!("bolt {} {extra}\n", env!("CARGO_PKG_VERSION"));
    // bolt itself: a new bolt may write the glue differently
    let me = std::env::current_exe().ok();
    for f in me.iter().chain(files) {
        let m = std::fs::metadata(f).ok();
        let t = m.as_ref().and_then(|m| m.modified().ok()).and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_nanos());
        s.push_str(&format!("{} {} {t}\n", f.display(), m.map_or(0, |m| m.len())));
    }
    s
}

/// whether OUT has this import's results for sources stamped `st`
pub fn fresh(r: &Req, st: &str) -> bool {
    std::fs::read_to_string(r.out.join("stamp")).is_ok_and(|s| s == st)
        && ["import.volt", "import.flags", "import.deps"].iter().all(|f| r.out.join(f).is_file())
        // the library the flags start with: gone when its target directory was cleaned
        && std::fs::read_to_string(r.out.join("import.flags")).is_ok_and(|f| f.lines().next().is_some_and(|l| !l.starts_with('/') || Path::new(l).is_file()))
}

/// writes the results, then the stamp that says they're current
pub fn save(r: &Req, m: &Made, st: &str) -> Result<(), String> {
    crate::build::write_if_changed(&r.out.join("import.volt"), &m.volt)?;
    crate::build::write_if_changed(&r.out.join("import.flags"), &(m.flags.join("\n") + "\n"))?;
    let deps: Vec<String> = m.deps.iter().filter(|d| d.exists()).map(|d| d.display().to_string()).collect();
    crate::build::write_if_changed(&r.out.join("import.deps"), &(deps.join("\n") + "\n"))?;
    crate::build::write_if_changed(&r.out.join("stamp"), st)
}

/// a Volt keyword can't be a name: `match` becomes `match_` (and so do the hooks delete and copy,
/// for a method)
pub fn volt_name(n: &str) -> String {
    const KEYWORDS: &[&str] = &[
        "var", "val", "static", "public", "internal", "attach", "struct", "enum", "fn", "error", "trait", "comptime", "async", "await", "suspend", "resume", "extern", "export",
        "namespace", "use", "as", "this", "move", "copy", "if", "else", "for", "in", "while", "loop", "break", "continue", "return", "match", "default", "try", "catch", "defer",
        "errdefer", "true", "false", "null", "delete", "type",
    ];
    if KEYWORDS.contains(&n) {
        format!("{n}_")
    } else {
        n.to_string()
    }
}

/// builds an import with the instances of its generics programs asked for (OUT/instances: voltc
/// appends a line per instance it needs). Those the compiler rejected (OUT/instances.failed: a
/// line, or a line and ::method for one method of a type's instance, then the compiler's reason)
/// stay out until the import's own inputs change (own_st); then they're tried again. `build` builds
/// with these lines, leaving out these methods, giving the Volt side and the build's messages;
/// `methods` names the methods of a line's type instance; `fail` words a failed build
pub fn with_instances(r: &Req, own_st: &str, build: impl Fn(&[String], &BTreeMap<String, String>) -> Result<(String, String), String>, methods: impl Fn(&str, &BTreeMap<String, String>) -> Vec<String>, fail: impl Fn(String) -> String) -> Result<(String, String), String> {
    let mut wanted: Vec<String> = std::fs::read_to_string(r.out.join("instances")).unwrap_or_default().lines().filter(|l| !l.trim().is_empty()).map(String::from).collect();
    let failed_file = r.out.join("instances.failed");
    let old_failed = std::fs::read_to_string(&failed_file).unwrap_or_default();
    let mut failed = format!("# {}\n", own_st.replace('\n', " "));
    let mut skip: BTreeMap<String, String> = BTreeMap::new();
    if old_failed.lines().next() == failed.lines().next() {
        for l in old_failed.lines().skip(1) {
            // line\twhy, or line\t::method\twhy (the line's own fields are tab-separated too)
            match l.split_once("\t::") {
                Some((line, rest)) => {
                    let (method, why) = rest.split_once('\t').unwrap_or((rest, ""));
                    skip.insert(format!("{line}::{method}"), why.to_string());
                }
                None => {
                    let line = l.rsplit_once('\t').map_or(l, |x| x.0);
                    wanted.retain(|w| w != line);
                }
            }
            if !failed.lines().any(|x| x == l) {
                let _ = writeln!(failed, "{l}");
            }
        }
    } else {
        for l in old_failed.lines().skip(1) {
            let line = l.split_once("\t::").map_or_else(|| l.rsplit_once('\t').map_or(l, |x| x.0), |x| x.0).to_string();
            if !line.is_empty() && !wanted.contains(&line) {
                wanted.push(line);
            }
        }
    }
    match build(&wanted, &skip) {
        Ok(x) => {
            crate::build::write_if_changed(&failed_file, &failed)?;
            Ok(x)
        }
        Err(e) if wanted.is_empty() => Err(fail(e)),
        Err(_) => {
            // an instance the compiler rejects (types that don't meet a bound) is left out, with its
            // reason (voltc reports it at the call); of a type's instance, only the methods it
            // rejects (each impl block has its own bounds)
            // (rustc's error[..]: line, or zig's file:line:col: error: line, past its place); a
            // failure without one (the compiler didn't run) is no instance's, and stops the build
            let why = |e: &str| e.lines().find(|x| x.starts_with("error") || x.contains(": error: ")).map(|x| x.split_once(": error: ").map_or(x, |p| p.1).trim().to_string());
            let mut good: Vec<String> = Vec::new();
            for l in &wanted {
                let mut with = good.clone();
                with.push(l.clone());
                let Err(e) = build(&with, &skip) else {
                    good = with;
                    continue;
                };
                let Some(w) = why(&e) else { return Err(fail(e)) };
                let methods = methods(l, &skip);
                let mut bare = skip.clone();
                for m in &methods {
                    bare.entry(format!("{l}::{m}")).or_insert_with(|| "left out while its type was tried".into());
                }
                if methods.is_empty() || build(&with, &bare).is_err() {
                    let _ = writeln!(failed, "{l}\t{w}");
                    continue;
                }
                good = with;
                for m in &methods {
                    let key = format!("{l}::{m}");
                    if skip.contains_key(&key) {
                        continue;
                    }
                    bare.remove(&key);
                    if let Err(e) = build(&good, &bare) {
                        let Some(w) = why(&e) else { return Err(fail(e)) };
                        let entry = format!("{l}\t::{m}\t{w}");
                        if !failed.lines().any(|x| x == entry) {
                            let _ = writeln!(failed, "{entry}");
                        }
                        bare.insert(key.clone(), w.clone());
                        skip.insert(key, w);
                    }
                }
            }
            crate::build::write_if_changed(&r.out.join("instances"), &good.iter().map(|l| format!("{l}\n")).collect::<String>())?;
            crate::build::write_if_changed(&failed_file, &failed)?;
            build(&good, &skip).map_err(fail)
        }
    }
}
